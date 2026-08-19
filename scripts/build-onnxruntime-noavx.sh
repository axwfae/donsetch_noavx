#!/usr/bin/env bash
#
# build-onnxruntime-noavx.sh — build ONNX Runtime from source for CPUs
# WITHOUT AVX support (Intel Bay Trail Atom/Celeron N3540, J1900, ...).
#
# Why: donsetch's `ocr` and `rerank` features use ONNX Runtime via
# `ort`/`oar-ocr`. Their `download-binaries` mode pulls pyke.io's
# prebuilt x86-64 binaries, which target x86-64-v3 (AVX2+FMA) and crash
# with SIGILL on these CPUs. This script compiles ONNX Runtime with all
# AVX/AVX2/AVX512 off so the resulting library runs on plain SSE2/SSE4.2
# silicon, then points donsetch at it with ORT_LIB_PATH.
#
# Usage:
#   ./scripts/build-onnxruntime-noavx.sh [--jobs N] [--prefix DIR] [--force]
#
# The default build dir is ./vendor/onnxruntime-noavx (git-ignored).
# When it finishes it prints the exact `cargo build` command to run.
# The script is idempotent: it skips straight to the summary if the
# library already exists (useful for cached CI runs). Pass --force to
# rebuild from scratch.
#
# Tip: compiling ONNX Runtime is heavy (30min-2h+). It is faster to build
# it on any modern x86-64 machine and copy the resulting directory to the
# target host — the library is CPU-agnostic as long as AVX is disabled.
#
# Requirements: git, cmake (>= 3.20), a C/C++ toolchain, python3,
# and enough RAM/swap for the compiler (2-4GB is fine). ninja-build is
# used automatically when available for faster builds.

set -euo pipefail

# Match the ORT version pyke.io ships for ort 2.0.0-rc.12 (api-24 / 1.24.2).
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

SRC="$PREFIX/onnxruntime"
BUILD="$PREFIX/build"
LIB="$BUILD/libonnxruntime.a"

# Fast path: already built (cached). Nothing to do.
if [[ "$FORCE" -eq 0 && -f "$LIB" ]]; then
    log "found existing non-AVX ONNX Runtime at $LIB — skipping rebuild"
    cat <<EOF

ONNX Runtime is built without AVX. Now build donsetch with the \`noavx\`
feature and point it at this library:

  export ORT_LIB_PATH="$BUILD"
  cargo build --release --features ocr,rerank,noavx
EOF
    exit 0
fi

mkdir -p "$PREFIX"
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

log "configuring CMake build (AVX/AVX2/AVX512 disabled)"
cmake -S "$SRC/cmake" -B "$BUILD" "${CMAKE_GEN[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -Donnxruntime_USE_AVX=OFF \
    -Donnxruntime_USE_AVX2=OFF \
    -Donnxruntime_USE_AVX512=OFF \
    -Donnxruntime_ENABLE_CPU_FP16_OPS=OFF \
    -Donnxruntime_BUILD_SHARED_LIB=OFF \
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

if [[ ! -f "$LIB" ]]; then
    # Fall back to whatever the build produced.
    LIB="$(find "$BUILD" -name 'libonnxruntime.a' | head -1)"
fi
[[ -n "$LIB" ]] || err "build finished but libonnxruntime.a was not found under $BUILD"

log "done: $LIB"
cat <<EOF

ONNX Runtime is built without AVX. Now build donsetch with the \`noavx\`
feature and point it at this library:

  export ORT_LIB_PATH="$BUILD"
  cargo build --release --features ocr,rerank,noavx

Run \`donsetch doctor\` afterwards to confirm OCR/rerank are healthy.

NOTE: if your toolchain is recent but its binutils/assembler predates
AVX-VNNI support, the MLAS AVX2 sources may fail to compile with an
"unknown mnemonics" error (microsoft/onnxruntime#27828). Either update
binutils, or patch cmake/onnxruntime_mlas.cmake to use "-mno-avxvnni"
instead of "-mavxvnni" (see the issue for the full diff).
EOF