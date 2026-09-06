# donsetch_noavx_362 — 修改說明（給下次修改的人/AI 看）

> **閱讀時機**：任何要修改本目錄、或要把 noavx 修改移植到新版 donsetch 時，先讀完這份文件再動手。

## 1. 這個目錄是什麼

`donsetch_noavx_362/` 是 **donsetch-3.6.2 的 noavx 建置變體**，由 `donsetch_noavx_351/`（3.5.1 版）移植而來（「換 .so + 繞 gate」新設計源自 _351；更早的前身是 `donsetch_noavx_320/` 3.2.0、`donsetch_noavx_250/` 2.5.0、`donsetch_noavx/` 2.3.4）。

> **用戶原則**：發佈/打包方式以**驗證過的 _250/_320 套件為準**，_351 僅為參考（_351 本身未經生產驗證）。實務上 _351 的 workflow 結構（Linux-only + noavx job + `_sync` 容忍 + publish needs）本就繼承自 _320 的驗證模式，可沿用；_351 特有的未驗證項（QEMU smoke best-effort、`.so` size floor TODO）**原樣保留其保守形態**，不可放寬。移植時若發現 _351 有疑似錯誤之處，優先以 _320 的做法為準並記錄。

**為什麼存在**：donsetch 的 OCR / 語意 rerank 功能依賴 ONNX Runtime。3.6.2 的 Linux 標準建置在編譯期下載微軟官方 `onnxruntime-linux-x64-1.24.2.tgz` 的 `.so` 隨 binary 出貨，runtime 經 `src/onnx.rs::ensure_loaded()` 先過 AVX gate 再 dlopen。在沒有 AVX 的老 CPU 上（Intel Bay Trail Atom/Celeron N3540、J1900 等，只有 SSE4.2）標準版的 OCR/rerank 被 gate 擋下（程式本身正常跑，不再 SIGILL——SIGILL 時代已隨 load-dynamic 結束）。本目錄的所有修改都是為了讓 OCR/rerank 在無 AVX CPU 上真正可用：出貨自編的無 AVX `.so`，並把 AVX gate 編譯掉。

**目錄定位**：本目錄只攜帶 noavx 建置設定、CI workflow、文件，以及 **`src/` 中「有修改」的檔案**（共 5 個：`src/cli/{update,version,status}.rs`、`src/cli/doctor.rs`、`src/onnx.rs`，見第 3 節）。未修改的原始碼一律不同步進來，以免與基礎版產生干擾——建置時把本目錄疊在 `donsetch-3.6.2` 原始碼樹上使用。升級版本時需重新套用這些檔案修改（見第 5 節）。

**鏡像目錄**：2.x 時代上游同時維護 `.github/workflows/` 與 `github/workflows/` 兩處（歷史因素）；3.2.0 起上游已移除 `github/` 鏡像。**3.5.1 起上游連 `.github/` 都沒有（3.6.2 相同，已確認無 `.github/` 目錄），workflows 只剩頂層 `github/workflows/`，故本目錄僅保留 `github/workflows/`，不做任何鏡像。**

## 2. 各檔案修改內容與原因

> 新設計是「**換 .so + 繞 gate**」（3.5.1 架構劇變時確立，3.6.2 沿用不變；3.5.1 以前的舊方法「砍 `download-binaries` + `ORT_LIB_PATH` 靜態連結」已失效）：自編無 AVX 的 `libonnxruntime.so`，用 `noavx` feature 把 AVX gate 編譯掉。OCR 與 rerank 都經 `ensure_loaded()` 單一門控（`src/pdf/ocr.rs`、`src/search/rerank.rs` 只呼叫它），改 gate 即全覆蓋。

### Cargo.toml
- **只新增一個 feature**（其餘一字不動）：
  ```toml
  # Build/link a locally-compiled ONNX Runtime shared library that does NOT
  # require AVX (see scripts/build-onnxruntime-noavx.sh), and compile out the
  # AVX gate in src/onnx.rs so OCR/rerank run on any x86-64 CPU. Linux only.
  noavx = []
  ```
- `oar-ocr` / `ort` 依賴**刻意不動**，原因有二：
  1. Linux 走 `load-dynamic` 時 `ort-sys` 遇到 `disable-linking` 會提前返回，靜態 AVX 機器碼根本不會被連結進 binary——沒有舊時代「靜態連結把 AVX 帶進來」的問題。
  2. `oar-ocr` 的 `simd` 是 Rust 執行期 dispatch（runtime feature detection），不是編譯期 AVX，不會 SIGILL——絕對不要砍。

### build.rs
- 在 `has_onnx` 分支開頭加 `CARGO_FEATURE_NOAVX` 分支：
  - `noavx`：**絕不下載微軟官方 .so**；要求 `scripts/build-onnxruntime-noavx.sh` 已產出 `vendor/onnx/libonnxruntime.so`（與 `fetch_onnx_prebuilt` 共用同一路徑，其「已存在則早退」邏輯順勢可用），缺失則 panic 並指引腳本；存在則直接 `copy_onnx_shared_lib`。
  - 非 Linux 平台 warn 後忽略（macOS/Windows 走靜態腿，`noavx` 無意義）。
  - 非 `noavx` 路徑保持現狀（照常下載官方 `.so`）。
- 在 `DONSHEET_FEATURES` 段順手 push `noavx`，讓 `donsetch -v` 可區分兩版（release 的 noavx leg 會驗 `noavx` 字串）。

### src/onnx.rs
- 只把 AVX gate 用 `#[cfg(not(feature = "noavx"))]` 包起來，`find_shared_lib()` 的缺失錯誤原樣保留：
  ```rust
  #[cfg(not(feature = "noavx"))]
  if !crate::cpu::has_avx() {
      return Err(NO_AVX_MSG.to_string());
  }
  ```
  並加註解說明 noavx 版出貨自編 `.so` 故 gate 編譯掉。
- **`src/cpu.rs` 絕對不要動**（`has_avx()` 是標準版 gate 與 payload probe 共用的真相來源）。

### src/cli/doctor.rs（3.5.1 新增的修改點，舊版沒有；3.6.2 沿用）
- 只動 `check_onnx()` 的 Linux 分支：`noavx` 時跳過 `has_avx`，直接走 `ensure_loaded()` 真探（dlopen + commit）後 Pass（"noavx build, shared library loaded"）/Fail；非 `noavx` 保持現狀（AVX 檢查 + `.so` 存在性檢查）。
- 原因：noavx 版沒有 AVX 概念可檢查，沿用舊邏輯會在無 AVX 機器上永遠 Warn；真探與 `src/onnx.rs` 的編譯掉 gate 前後呼應。
- **移植注意（3.6.2 教訓）**：3.6.2 上游 `doctor.rs` 在 `check_onnx` 之外新增了 `check_auth_sessions()`、`check_plugins()` 及對應 `report!` 行，但 `check_onnx()` 本體逐位元組相同。因此**只能對 3.6.2 版做等價編輯，不可整檔複製 _351 版**（否則會丟失上游新檢查）。驗證：`diff` 本目錄版與 _351 版應只剩上游新增部分。

### scripts/build-onnxruntime-noavx.sh
- 3.5.1 起產出靜態 `libonnxruntime.a` 的舊腳本改為產出 **shared lib**（3.6.2 沿用 _351 腳本，一字不改）：
  - `-Donnxruntime_BUILD_SHARED_LIB=ON`（舊版 OFF）。
  - 輸出固定為 `vendor/onnx/libonnxruntime.so`（與 build.rs 同一路徑；CMake 產物可能是 `libonnxruntime.so.1.24.2`，腳本負責定位並拷貝/規範化為該檔名）。
  - `-Donnxruntime_USE_AVX=OFF`、`USE_AVX2=OFF`、`USE_AVX512=OFF`、`ENABLE_CPU_FP16_OPS=OFF`、`CMAKE_POSITION_INDEPENDENT_CODE=ON` 保留。
  - `LIB=...libonnxruntime.a` 及 `ar -M` consolidation 段已刪除（靜態時代的死碼，shared 建置不需要；连带 re2 手動編譯 workaround 一併移除——那是 `BUILD_SHARED_LIB=OFF` 時 INTERFACE target 不編 re2 的 workaround）。
  - 永不傳 `-march=native`（可攜 baseline 的意義就在此），檔尾保留 binutils/AVX-VNNI 註記。
  - 建置工作區仍預設 `vendor/onnxruntime-noavx/`（CI 快取路徑不變），成品 `.so` 落在 `vendor/onnx/`。

### github/workflows/ci.yml（上游即此路徑，無 `.github/` 鏡像）
- 移除 matrix，只留 Linux x86_64（noavx 只需要 Linux）。
- build-test 用 3.6.2 的標準 feature 組 `--features ocr,rerank,http`（已無 `download-binaries` feature），跑 nextest + `ci` profile。
- **沿用 _351 內容**（port 3.5.1 的改進：`dtolnay/rust-toolchain@1.98`、nextest + `ci` cargo profile、version-insensitive DEP_HASH 快取、clippy `--all-targets` + `--profile ci`、job 名稱 `build-test (linux-x86_64)` 格式；已驗證 3.6.2 上游 ci.yml 與 3.5.1 逐位元組相同，故 _351 版一字不改直接沿用）。
- **刻意保留**平台無關 jobs：`supply-chain`（cargo-deny）與 `fuzz`（5 個 target 的 90s smoke），原樣照搬（含 `actions/upload-artifact@v7`）。
- `noavx-check` job 升級（舊 stub + `cargo check` 已不足）：
  - stub 改放 `vendor/onnx/libonnxruntime.so`（配合 build.rs 新路徑），`cargo check --features ocr,rerank,noavx` 保留作編譯門（check 不連結，stub 內容無所謂；**release 建置絕不可用 stub**）。
  - 新增 QEMU 驗證：`qemu-x86_64 -cpu qemu64 ./donsetch doctor`（先清 avx 快取，斷言 "shared library loaded"）；rustflags `-C target-cpu=x86-64`（不可用 native）。
  - **CI 不做 OCR smoke（用戶決策）**：樣張 `ocr-sample-scan.pdf` 留在 repo 供用戶自測；`fetch` 只接受公網 http(s)（本地路徑拒收、`127.0.0.1` 被 SSRF 攔截），CI 內無合適調用方式，故 release/ci 的 QEMU 段只保留 doctor 探針（dlopen + commit 即放行門）。
  - QEMU 段是 best-effort：runner 若無 QEMU 則跳過 run gate，CI 仍保證編譯門；權威的非 AVX 證明在 release.yml。

### github/workflows/release.yml
- build job（標準版）：Linux x86_64 only，`--features ocr,rerank,http`，沿用 _351（port 上游的全部 gates——version 檢查、payload gates（binary size floor + `.so` 10MB floor + doctor probe）、glibc 2.35 baseline、`QEMU qemu64 --version` 無 SIGILL 驗證、tarball 內含 `.so`；另加 `workflow_dispatch`；已驗證 3.6.2 上游 release.yml 與 3.5.1 逐位元組相同，僅註解中的 `v3.5.1_sync` 例示改為 `v3.6.2_sync`）。
- 附加 `build-noavx-linux` job：
  - 先跑腳本產出 `vendor/onnx/libonnxruntime.so`（快取 `vendor/onnxruntime-noavx` + `vendor/onnx`），再 `cargo build --release --features ocr,rerank,noavx`（`RUSTFLAGS="-C target-cpu=x86-64 -C link-arg=-fuse-ld=lld"`）；tarball 把 `libonnxruntime.so` 包進去，檔名 `donsetch-linux-x64-noavx.tar.gz`。
  - payload gate：binary size floor 保留；`.so` 的 floor **不可硬套標準版的 10MB**（自編體積不同）——改為存在性 + >1MB sanity + ELF 檢查，並加 TODO 註解要求首次發版後按實際體積校準。
  - doctor 探針期望字串為 noavx 版的 "shared library loaded"；另有 glibc gate。QEMU 段只跑 doctor 探針，不做 OCR smoke（同上：樣張供用戶自測，CI 不用）。
  - 此二進位同時相容有 AVX 與無 AVX 的 CPU——不確定時用 noavx 版就對了。
- publish job：`needs: [build, build-noavx-linux]`。
- **保留 _sync tag 容忍修復**（照抄 _320 版：版本驗證剝 `${TAGVER%%_*}` 後綴；release notes 三級降級不中斷——先找完整 tag，再退回基礎版號，再寫最小內容）。3.6.2 原版這兩處是硬失敗（`sys.exit`），必須改掉。

### README.md / CONTRIBUTING.md / TESTING.md
- TESTING.md、`ocr-sample-scan.pdf` 版本無關，直接沿用 _351 版（與 _320 版逐位元組相同）。
- README 開頭加 AVX 警告區塊（照抄 _320/_351 文字）。
- 下載表格改 Linux-only（含 noavx 列）；Homebrew 安裝選項移除（macOS 導向且指向上游 tap，本 fork 不出 macOS 二進位）。
- 建置說明加入 noavx 路線（腳本 + `--features ocr,rerank,noavx`），並寫清楚差異：3.6.2 標準版編譯期自動下載微軟官方 `.so`，noavx 版永不下載、缺 `.so` 直接編譯失敗。
- 加入 `<details>` 的「Build for CPUs without AVX」章節（按 3.6.2 語境重寫：換 .so + 繞 gate；3.6.2 的插入錨點是 Build-from-source 的 Feature matrix 段落，Gotchas/頁尾錨點行號位移但文字不變）。
- Gotchas 表 OCR 列補 noavx 說明。
- **clone 網址、badge、footer 已指向 `axwfae/donsetch_noavx`**（見第 3 節）。注意：WRB benchmark 段的 `dondai44423/wrb` 指的是另一個獨立 repo（benchmark harness），刻意不改；同理 3.6.2 新增的 DeepSeek Harness 段 `dondai44423/donsetch-dsh`（獨立 plugin repo）也刻意不改；CONTRIBUTING.md 新增的 Reviewers 表格內 `@dondai44423` 維持上游原樣（見下「未解決疑點」）。
- CONTRIBUTING.md：clone 網址改 fork、CI 平台改 Linux only、加 noavx 建置指引；其餘（Rust 1.98、637 tests 口徑，3.6.2 未變）沿用 3.6.2。

## 3. 更新來源（update 指令）指向 fork

**修改位置：`src/cli/{update.rs,version.rs,status.rs}` 三個檔案的 `REPO` 常數**（本目錄的 `src/` 另有 `cli/doctor.rs` 與 `src/onnx.rs`，見第 2 節）

```rust
// 原：const REPO: &str = "dondai44423/donsetch";
const REPO: &str = "axwfae/donsetch_noavx";
```

**原因**：`update` 指令會從 GitHub Releases 下載新二進位檔。若指向上游 `dondai44423/donsetch`，無 AVX 使用者會抓到**有 AVX 需求的官方版**（OCR/rerank 被 gate 停用，舊時代更會直接 SIGILL）。因此更新來源必須指向發布 noavx 版本的 fork `axwfae/donsetch_noavx`。

**為什麼三個檔案都要改**：`version.rs` 與 `status.rs` 用同一個 `releases.atom` feed 判斷「最新版」。若只改 `update.rs`，會出現 version/status 以上游為準說有新版、update 卻去 fork 抓不到的矛盾。

**注意**：升級版本移植時**不要遺漏**此修改（新版這三個檔案的 `REPO` 會是上游值，必須重改後再同步進來）。另外 `src/pdf/ocr.rs` 的 user-agent 字串仍寫上游網址，僅為標識用途，刻意不改（也因此不同步）。

**fork Release 格式需求**：tag 為 `v3.x.x`（`_sync` 後綴允許，如 `v3.6.2_sync`），資產名稱 `donsetch-linux-x64.tar.gz`（+ `.sha256`）與 `donsetch-linux-x64-noavx.tar.gz`——本目錄的 release workflow 產出的正是這些名稱。

## 4. 對照基準與驗證方式

- 對照組：`donsetch_noavx_351/`（3.5.1 的 noavx 變體）、`donsetch-3.6.2/`（乾淨的上游版）。事前驗證：3.6.2 與 3.5.1 在 noavx 相關程式碼上幾乎完全相同——`build.rs`、`src/onnx.rs`、`src/cli/{update,version,status}.rs`、`src/cpu.rs`、`github/workflows/ci.yml`、`github/workflows/release.yml` 逐位元組相同；`check_onnx()` 函數本體逐位元組相同（僅行號位移）；`Cargo.toml` 僅差版本號 + axum/tower-http/base64 bump；`README.md`、`CONTRIBUTING.md` 有內容漂移（dsh 新段落、Reviewers 段、doctor 新檢查函數、Gotchas/login 新列）。
- 驗證指令：
  ```bash
  diff -r donsetch_noavx_362 donsetch_noavx_351   # 預期差異只有：版本號引用、3.6.2 README/CONTRIBUTING 漂移（含 dsh/Reviewers 新段、doctor 新函數）、release.yml 註解版本、說明文件；其餘應無差異
  python3 -c "import tomllib; tomllib.load(open('donsetch_noavx_362/Cargo.toml','rb'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_362/github/workflows/ci.yml'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_362/github/workflows/release.yml'))"
  grep -rn "dondai44423" donsetch_noavx_362/   # 應只剩 README 的 wrb 段與 dsh 段、CONTRIBUTING 的 Reviewers 表格（見未解決疑點）與本文件記錄原始值處
  find donsetch_noavx_362/src -type f          # 必須恰好 5 個檔案
  diff donsetch_noavx_362/src/onnx.rs donsetch-3.6.2/src/onnx.rs   # 唯一差異為 gate 的 cfg 包裝+註解
  grep -n "download-binaries\|simd" donsetch_noavx_362/Cargo.toml  # oar-ocr 保持原樣（含 simd）
  ```
- 本目錄的 `src/` 只含修改過的檔案（`src/cli/{update,version,status,doctor}.rs` + `src/onnx.rs`）。可用 `diff donsetch_noavx_362/src/cli/<file>.rs donsetch-3.6.2/src/cli/<file>.rs` 驗證：前三者唯一差異是 `REPO` 常數，doctor 唯一差異是 `check_onnx` 的 cfg 分支；除此之外本目錄不得出現其他 `src/` 檔案。
- 本機若有 Rust toolchain，加跑 `cargo check --features ocr,rerank,noavx`（以 stub `.so` 滿足 build.rs）；若無，註明未跑。（注意：本機無 AVX 時 `cargo test` 的 payload probe 會自動 skip，不要誤判。）

## 5. 升級到新版 donsetch 時的移植步驟

1. 建立新目錄 `donsetch_noavx_<新版號>/`。
2. 版本無關檔案直接複製：`TESTING.md`、`ocr-sample-scan.pdf`、`scripts/build-onnxruntime-noavx.sh`（若新版仍是 load-dynamic 架構；若上游改回靜態連結，需重新評估整套設計）。
3. 其餘檔案從新版原始目錄複製後，按第 2 節逐項套用修改（**不可盲目 patch**，README/build.rs 各版有內容漂移，要找對應段落做等價編輯；先確認新版 `github/` vs `.github/` 佈局；`doctor.rs` 若上游在 `check_onnx` 之外加了新函數，必須等價編輯、不可整檔複製舊版——見第 2 節移植注意）。
4. workflows 以本目錄版本為範本，但 port 新版的 action 版本升級與 apt 改進；上游平台無關的新 jobs（如 supply-chain/fuzz）原樣保留。
5. **重改新版 `src/cli/{update,version,status}.rs` 的 `REPO` 常數、重包 `src/onnx.rs` 的 gate、新版 `check_onnx` 重加 cfg 分支後，只同步這 5 個修改過的檔案**至新目錄的 `src/`（保持相對路徑；新版原始檔帶上游值；未修改的 src 檔案一律不同步，見第 1 節）。
6. 跑第 4 節的驗證指令。

## 6. 已定案事項

- **CONTRIBUTING.md Reviewers 表格**（3.6.2 上游新增）：內含 `| Maintainer | @dondai44423 | everything |` 及四位上游 reviewer。**定案（用戶決定）：維持上游原樣**——該表描述的是上游專案的人事結構，擅改身份資訊風險更高；且取代範圍是 `dondai44423/donsetch` 路徑（badge/clone/footer），`@dondai44423` 不在其列。
