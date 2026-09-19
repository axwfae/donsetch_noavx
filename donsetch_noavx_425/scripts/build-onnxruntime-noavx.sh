#!/usr/bin/env bash
#
# build-onnxruntime-noavx.sh — build ONNX Runtime from source for CPUs
# WITHOUT AVX support (Intel Bay Trail Atom/Celeron N3540, J1900, ...).
#
# Why: donsetch's `ocr` and `rerank` features use ONNX Runtime via
# `ort`/`oar-ocr`. Since 3.5.x Linux uses ort `load-dynamic`: build.rs
# downloads Microsoft's official onnxruntime-linux-x64-1.24.2.tgz .so and
# ships it beside the binary, and src/onnx.rs gates OCR/rerank behind an
# AVX check. The official .so needs AVX, so on non-AVX CPUs OCR/rerank
# stay disabled. This script compiles ONNX Runtime with all AVX/AVX2/AVX512
# off as a SHARED library, drops it at vendor/onnx/libonnxruntime.so (the
# exact path build.rs expects), and the `noavx` cargo feature compiles out
# the AVX gate so OCR/rerank run on any x86-64 CPU.
#
# Usage:
#   ./scripts/build-onnxruntime-noavx.sh [--jobs N] [--prefix DIR] [--force]
#
# The build workspace defaults to ./vendor/onnxruntime-noavx (git-ignored,
# safe to cache in CI); the shipped artifact is always
# ./vendor/onnx/libonnxruntime.so (also git-ignored, read by build.rs).
# The script is idempotent: it skips straight to the summary if the
# artifact already exists (useful for cached CI runs). Pass --force to
# rebuild from scratch.
#
# Tip: compiling ONNX Runtime is heavy (30min-2h+). It is faster to build
# it on any modern x86-64 machine and copy the resulting .so to the
# target host — the library is CPU-agnostic as long as AVX is disabled.
#
# Requirements: git, cmake (>= 3.20), a C/C++ toolchain, python3,
# and enough RAM/swap for the compiler (2-4GB is fine). ninja-build is
# used automatically when available for faster builds.
#
# NOTE: never pass -march=native (or leave the compiler default to one):
# the whole point is a portable baseline binary. The flags below only
# turn AVX-family extensions OFF.

set -euo pipefail

# Match the ORT version the standard build ships (microsoft/onnxruntime
# official release v1.24.2, api-24 for ort 2.0.0-rc.12).
ORT_TAG="${ORT_TAG:-rel-1.24.2}"
JOBS=""
PREFIX="${DONSETCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/vendor/onnxruntime-noavx"
FORCE=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        *)
            err "unknown argument: $1 (try --help)"
            ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null || err "git is required"
command -v cmake >/dev/null || err "cmake is required (apt install cmake)"
command -v python3 >/dev/null || err "python3 is required"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PREFIX/onnxruntime"
BUILD="$PREFIX/build"
# The artifact build.rs expects (shared lib for ort load-dynamic dlopen).
OUTDIR="$ROOT/vendor/onnx"
OUTLIB="$OUTDIR/libonnxruntime.so"

# Fast path: already built (cached). Nothing to do.
if [[ "$FORCE" -eq 0 && -f "$OUTLIB" ]]; then
    log "found existing non-AVX ONNX Runtime at $OUTLIB — skipping rebuild"
    cat <<EOF

ONNX Runtime is built without AVX. Now build donsetch with the \`noavx\`
feature (build.rs picks up $OUTLIB automatically, no ORT_LIB_PATH needed):

  cargo build --release --features ocr,rerank,noavx
EOF
    exit 0
fi

mkdir -p "$PREFIX" "$OUTDIR"
if [[ ! -d "$SRC/.git" ]]; then
    log "cloning microsoft/onnxruntime @ $ORT_TAG"
    git clone --depth 1 --branch "$ORT_TAG" https://github.com/microsoft/onnxruntime.git "$SRC"
else
    log "using existing checkout at $SRC"
fi

CMAKE_GEN=()
if command -v ninja >/dev/null; then
    CMAKE_GEN=(-G Ninja)
    log "using ninja generator"
fi

log "configuring CMake build (shared lib, AVX/AVX2/AVX512 disabled)"
cmake -S "$SRC/cmake" -B "$BUILD" "${CMAKE_GEN[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -Donnxruntime_USE_AVX=OFF \
    -Donnxruntime_USE_AVX2=OFF \
    -Donnxruntime_USE_AVX512=OFF \
    -Donnxruntime_ENABLE_CPU_FP16_OPS=OFF \
    -Donnxruntime_BUILD_SHARED_LIB=ON \
    -Donnxruntime_BUILD_UNIT_TESTS=OFF \
    -Donnxruntime_BUILD_BENCHMARKS=OFF \
    -Donnxruntime_ENABLE_PYTHON=OFF \
    -Donnxruntime_BUILD_NODEJS=OFF \
    -Donnxruntime_BUILD_CSHARP=OFF \
    -Donnxruntime_BUILD_JAVA=OFF \
    -Donnxruntime_BUILD_WEBASSEMBLY=OFF \
    -Donnxruntime_USE_CUDA=OFF \
    -Donnxruntime_USE_TENSORRT=OFF \
    -Donnxruntime_USE_ROCM=OFF \
    -Donnxruntime_USE_OPENVINO=OFF \
    -Donnxruntime_USE_DNNL=OFF \
    -Donnxruntime_USE_XNNPACK=OFF \
    -Donnxruntime_USE_WEBNN=OFF \
    -Donnxruntime_USE_MIMALLOC=OFF \
    -Donnxruntime_ENABLE_LTO=OFF

log "building (this is the slow step — be patient)"
cmake --build "$BUILD" --config Release --parallel "${JOBS:-$(nproc)}"

# Locate the built shared library. Depending on the ORT version the file
# may be libonnxruntime.so.1.24.2 (versioned) or plain libonnxruntime.so,
# under $BUILD or $BUILD/lib. Normalize to vendor/onnx/libonnxruntime.so.
BUILT=""
for cand in \
    "$BUILD/libonnxruntime.so.1.24.2" \
    "$BUILD/lib/libonnxruntime.so.1.24.2" \
    "$BUILD/libonnxruntime.so" \
    "$BUILD/lib/libonnxruntime.so" \
; do
    if [[ -f "$cand" ]]; then
        BUILT="$cand"
        break
    fi
done
if [[ -z "$BUILT" ]]; then
    # Fallback: newest versioned libonnxruntime.so.* under the build tree.
    BUILT="$(find "$BUILD" -maxdepth 3 -name 'libonnxruntime.so.*' -type f 2>/dev/null | sort | tail -n 1 || true)"
fi
[[ -n "$BUILT" && -f "$BUILT" ]] || err "build finished but no libonnxruntime.so* was found under $BUILD"

log "installing $BUILT -> $OUTLIB"
cp -f "$BUILT" "$OUTLIB"

# Sanity: must be a plausible ELF shared object, not an empty file.
SIZE="$(wc -c < "$OUTLIB")"
if [[ "$SIZE" -lt 1048576 ]]; then
    err "produced $OUTLIB is implausibly small ($SIZE bytes)"
fi
if ! head -c 4 "$OUTLIB" | grep -q $'\x7fELF'; then
    err "produced $OUTLIB is not an ELF shared library"
fi

log "done: $OUTLIB ($SIZE bytes)"
cat <<EOF

ONNX Runtime is built without AVX. Now build donsetch with the \`noavx\`
feature (build.rs picks up $OUTLIB automatically, no ORT_LIB_PATH needed):

  cargo build --release --features ocr,rerank,noavx

Run \`donsetch doctor\` afterwards to confirm OCR/rerank are healthy.

NOTE: if your toolchain is recent but its binutils/assembler predates
AVX-VNNI support, the MLAS AVX2 sources may fail to compile with an
"unknown mnemonics" error (microsoft/onnxruntime#27828). Either update
binutils, or patch cmake/onnxruntime_mlas.cmake to use "-mno-avxvnni"
instead of "-mavxvnni" (see the issue for the full diff).
EOF
