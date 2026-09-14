# donsetch_noavx_400 — 修改說明（給下次修改的人/AI 看）

> **閱讀時機**：任何要修改本目錄、或要把 noavx 修改移植到新版 donsetch 時，先讀完這份文件再動手。

## 1. 這個目錄是什麼

`donsetch_noavx_400/` 是 **donsetch-4.0.0 的 noavx 建置變體**，由 `donsetch_noavx_362/`（3.6.2 版）移植而來（「換 .so + 繞 gate」設計源自 _351，經 _362 驗證；另有 `donsetch_noavx_320/` 3.2.0 可作早期對照）。

> **用戶原則**：發佈/打包方式以**驗證過的 _250/_320 套件為準**（Linux-only + noavx job + `_sync` 容忍 + publish needs）。實務上本目錄的 workflow 結構直接繼承 _362（即 _320 驗證模式），QEMU smoke best-effort、`.so` size floor TODO **原樣保留其保守形態**，不可放寬。移植時若發現 _362 有疑似錯誤之處，優先以 _320 的做法為準並記錄。
> **CI 不做 OCR smoke（用戶決策）**：樣張 `ocr-sample-scan.pdf` 留在 repo 供用戶自測；release/ci 的 QEMU 段只保留 doctor 探針。

**為什麼存在**：donsetch 的 OCR / 語意 rerank 功能依賴 ONNX Runtime。4.0.0 的 Linux 標準建置在編譯期下載微軟官方 `onnxruntime-linux-x64-1.24.2.tgz` 的 `.so` 隨 binary 出貨，runtime 經 `src/onnx.rs::ensure_loaded()` 先過 AVX gate 再 dlopen。在沒有 AVX 的老 CPU 上（Intel Bay Trail Atom/Celeron N3540、J1900 等，只有 SSE4.2）標準版的 OCR/rerank 被 gate 擋下。本目錄的所有修改都是為了讓 OCR/rerank 在無 AVX CPU 上真正可用：出貨自編的無 AVX `.so`，並把 AVX gate 編譯掉。

**目錄定位**：本目錄只攜帶 noavx 建置設定、CI workflow、文件、`src/` 中「有修改」的檔案（共 5 個，見第 3 節），以及**根目錄的 `Cargo.lock`**（唯一例外：與基底逐位元組相同，原樣攜帶只為防呆——見下）。未修改的原始碼一律不同步進來——建置時把本目錄疊在 `donsetch-4.0.0` 原始碼樹上使用。升級版本時需重新套用這些檔案修改（見第 5 節）。

> **Cargo.lock 例外的原因（4.0.0 實測教訓）**：4.0.0 新增 git 依賴 `quiche`（tag pin）。fork 端若沿用舊版（如 3.6.2 時代）的 `Cargo.lock`，內無 quiche 條目，CI 的 `cargo build --locked` 會因「需改 lock」而失敗（`cannot update the lock file ... --locked was passed`）。已用 `git ls-remote` 驗證 tag 指向與 lock pin 一致（fb579bcf），排除 tag 移位——純粹是 fork 端 lock 過期。此後每次升版**必須同步基底的 `Cargo.lock`**（見第 5 節），本目錄直接攜帶一份即鎖定正確版本，免除人肉同步漏掉的風險。`noavx = []` 是空 feature，不影響依賴解析，故基底 lock 可直接沿用。

**佈局跟隨基底**：4.0.0 上游 workflows 位於 `.github/workflows/`（3.6.2 與 4.0.0 一致），故本目錄僅保留 `.github/workflows/`，**不要建 `github/` 鏡像**。

## 2. 頭號大事：上游 4.0.0 自己修了 update/`.so` 問題

_362 時代我們被迫維護的兩塊 patch（`update.rs` 的 Unix `.so` 安裝邏輯、`rollback.rs` 的 `.so` 交換邏輯），**上游 4.0.0 已經用自己的設計修掉了，本目錄的對應 patch 全部退役**。

**上游修了什麼**（`donsetch-4.0.0/src/cli/update.rs`，`rollback.rs` 配合）：

- `pub(crate) const SIBLING_LIBS: &[&str] = &["libonnxruntime.so"]`（`#[cfg(unix)]`）：Unix tarball 隨 binary 出貨的 runtime lib 清單。
- `replace_binary()` 的 Unix 分支：先把 tarball 內的 sibling libs 拷貝到 staging tmp（`sibling_tmp()`），binary 原子 rename 成功後再逐個 swap 進去（先清 stale `.bak`、舊檔 copy 備份、rename 換入；失敗只警告）。
- `pub(crate) fn swap_sibling_lib()`：rollback 的對應操作（hard link stash + rename 換回）。
- `rollback.rs` Unix 分支在 binary 交換成功後，對 `SIBLING_LIBS` 逐個調用 `swap_sibling_lib`。
- 單元測試 5 個（`replace_binary_refreshes_sibling_runtime_lib`、`_installs_lib_that_was_not_there_before`、`_replaces_a_stale_lib_backup`、`_leaves_lib_alone_when_tarball_has_none`、`swap_sibling_lib_round_trips`）。
- 上游註解明寫的就是我們踩過的坑：「只換 binary 導致 OCR/rerank 對自更新用戶失效」「`.so` that needed GLIBC_2.38 stayed put through `-u`」「`doctor` (a presence check) reported it fine」。

**Unix 覆蓋驗證結論（本地已核實，可退役）**：

- SIBLING 邏輯全程 `#[cfg(unix)]`：`SIBLING_LIBS`、`sibling_tmp`、`swap_sibling_lib` 定義與 Unix 分支調用（`replace_binary` 內 staging/swap、`cleanup_previous` 清 staging tmp、`rollback.rs` 的 swap 迴圈）皆有 Unix gate；Windows 走既有的 pdfium.dll 分支，不受影響。
- 行為是 _362 patch 的超集：上游多做了 staging（磁碟滿時不安裝）、stale `.bak` 清除（防止 binary N 配 lib N-1）、原子性保證；_362 的「裝入新檔、失敗警告」語意被完整覆蓋。
- 因此 `rollback.rs` **不再同步進本目錄**（上游已處理 sibling libs），`update.rs` 只保留 REPO + 資產選擇兩處，SIBLING 段一字不動。

## 3. 各檔案修改內容與原因

> 設計仍是「**換 .so + 繞 gate**」：自編無 AVX 的 `libonnxruntime.so`，用 `noavx` feature 把 AVX gate 編譯掉。OCR 與 rerank 都經 `ensure_loaded()` 單一門控，改 gate 即全覆蓋。

### Cargo.toml

- **只新增一個 feature**（其餘一字不動，4.0.0 的依賴 bump——quiche git、brotli 9、memchr、zstd 0.14、config、psl、windows-sys pipes、rcgen、rustls*、winresource、profile.ci opt-level——全部沿用上游）：
  ```toml
  # Build/link a locally-compiled ONNX Runtime shared library that does NOT
  # require AVX (see scripts/build-onnxruntime-noavx.sh), and compile out the
  # AVX gate in src/onnx.rs so OCR/rerank run on any x86-64 CPU. Linux only.
  noavx = []
  ```
- `oar-ocr` / `ort` 依賴**刻意不動**（4.0.0 該區與 3.6.2 未變）：Linux `load-dynamic` 時靜態 AVX 機器碼不會被連結進 binary；`oar-ocr` 的 `simd` 是 Rust 執行期 dispatch，不會 SIGILL。

### build.rs

- 4.0.0 新增的只有 Windows version-resource（`rerun-if-changed`、`stamp_version_resource`、`display_name.rs` include）與 noavx 無關；ONNX 段（`fetch_onnx_prebuilt`/`copy_onnx_shared_lib`/`vendor/onnx` 路徑）逐字未變，故 NOAVX 插入錨點（`if has_onnx { if let Some(info) ...`）仍在，插入內容與 _362 一字相同：
  - `noavx`：**絕不下載微軟官方 .so**；要求 `scripts/build-onnxruntime-noavx.sh` 已產出 `vendor/onnx/libonnxruntime.so`，缺失則 panic 並指引腳本；存在則直接 `copy_onnx_shared_lib`。
  - 非 Linux 平台 warn 後忽略；非 `noavx` 路徑保持現狀。
- `DONSHEET_FEATURES` 段 push `noavx` 保留（`donsetch -v` 可區分兩版）。
- 與 _362 版 `diff` 應只剩上游 4.0.0 新增（version-resource 相關三處，見驗證節）。

### src/onnx.rs

- 與 _362 版**逐位元組相同**（已驗證 4.0.0 `src/onnx.rs`、`src/cpu.rs` 與 3.6.2 完全相同）：gate 用 `#[cfg(not(feature = "noavx"))]` 包裝 + noavx 專用可執行缺件報錯（指明兩個查找位 + 重解 tarball 取雙檔 + 清 avx.json + 跑 doctor）。
- **`src/cpu.rs` 絕對不要動**（`has_avx()` 是標準版 gate 與 payload probe 共用的真相來源）。

### src/cli/doctor.rs（必須等價編輯，不可整檔複製）

- 4.0.0 基底（2421 行；`check_onnx` 本體逐位元組同 3.6.2，但檔內新增 `--improve`/`--stealth`/`--parity`、`DISPLAY_NAME` 化妝等 1352 行差異）上，對 `check_onnx` 的 Linux 分支做與 _362 等價的 cfg 編輯：`noavx` 時跳過 `has_avx`，直接 `ensure_loaded()` 真探後 Pass（"noavx build, shared library loaded"）/Fail；非 `noavx` 保持現狀。
- 驗證：與 _362 版 `diff` 應只剩上游 4.0.0 新增部分。

### src/cli/{update,version,status}.rs

- 三檔 `REPO` 常數改 fork：`const REPO: &str = "axwfae/donsetch_noavx";`（4.0.0 另有 `DISPLAY_NAME` 化妝，原樣保留，只改 REPO 單行）。
- `update.rs` 另加 `platform_asset_name()` 的 noavx 資產選擇（上游無 noavx 概念，`("linux","x86_64")` 仍寫死 `linux-x64`，照抄 _362 的 `cfg!(feature="noavx")` 分支回傳 `linux-x64-noavx`）。其餘上游 SIBLING_LIBS 邏輯一字不動（見第 2 節）。
- `src/pdf/ocr.rs` 的 user-agent 字串僅為標識用途，刻意不改（也因此不同步）。
- status.rs 注意：4.0.0 的 proxy 段改用 `load_config_verbose`、新增 route-memory/improve 行——皆為上游內容，原樣保留。

### scripts/build-onnxruntime-noavx.sh / ocr-sample-scan.pdf

- 版本無關，直接沿用 _362（4.0.0 build.rs ONNX 段未變：同為官方 v1.24.2、`vendor/onnx/libonnxruntime.so` 路徑、已存在則早退；腳本 `ORT_TAG=rel-1.24.2` 與之對應）。

### .github/workflows/ci.yml（上游即此路徑）

- _362 結構（Linux-only + `noavx-check` job + supply-chain/fuzz 原樣保留）+ port 上游 4.0.0 兩處：`concurrency` group（整段照抄上游）與 Test timeout 15→30（附註記說明由上游 port）。
- build-test 用 `--features ocr,rerank,http` + nextest + `ci` profile；QEMU 段只跑 doctor 探針（`RUSTFLAGS="-C target-cpu=x86-64"`，斷言 "shared library loaded"），best-effort。

### .github/workflows/release.yml

- _362 結構原樣（Linux-only build job + `build-noavx-linux` + payload gates + `.so` floor TODO + QEMU doctor probe + `_sync` 容忍 + publish `needs: [build, build-noavx-linux]`），僅版本引用 `v3.6.2_sync`→`v4.0.0_sync`、`[3.6.2]`→`[4.0.0]`。
- 版本驗證剝 `${TAGVER%%_*}` 後綴；release notes 三級降級不中斷（上游 4.0.0 原版此處仍是硬失敗 `sys.exit`，必須保留容忍修復）。

### README.md / CONTRIBUTING.md / TESTING.md

- README：等價編輯——開頭 AVX 警告區塊（照抄 _362 文字）、npm 段後 CPU 選擇表、Homebrew 選項移除、clone 改 fork、Build-from-source 內嵌 noavx `<details>`（TAG 範例改 `v4.0.0_sync`）、Gotchas OCR 列補 noavx 說明、footer badge/links 改 fork；WRB（`dondai44423/wrb`）、DeepSeek Harness（`dondai44423/donsetch-dsh`）段維持上游。
- CONTRIBUTING：clone 網址改 fork、full build 行加 AVX 註記、CI 平台改 Linux only + noavx 建置指引、PR 第 5 步改 Linux；Reviewers 表格维持上游原樣（用户定案：該表描述上游人事結構，`@dondai44423` 不在取代範圍內）。
- TESTING.md：沿用 _362（§1 防呆安裝步驟已是修正版），僅三處版本相關更新：TAG 範例 `v3.6.2_sync`→`v4.0.0_sync`；`donsetch tools` 預期由 3 個改 4 個（4.0.0 新增 `web_screenshot`）；MCP 預期 `serverInfo: donsetch 2.3.4`→`4.0.0`。§7 實測記錄表（2026-08-20，2.3.4）為歷史記錄，原樣保留。

## 4. 對照基準與驗證方式

- 對照組：`donsetch_noavx_362/`（3.6.2 的 noavx 變體）、`donsetch-4.0.0/`（乾淨的上游版）。
- 驗證指令：
  ```bash
  diff -r donsetch_noavx_400 donsetch_noavx_362   # 預期差異只有：第 2 節退役的 update/rollback patch、4.0.0 上游漂移（README/CONTRIBUTING/doctor/DISPLAY_NAME/status proxy/依賴）、版本号引用、TESTING 三處更新、workflows 回到 .github/；其餘應無差異
  python3 -c "import tomllib; tomllib.load(open('donsetch_noavx_400/Cargo.toml','rb'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_400/.github/workflows/ci.yml'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_400/.github/workflows/release.yml'))"
  grep -rn "dondai44423" donsetch_noavx_400/   # 應只剩 README 的 wrb 段與 dsh 段、CONTRIBUTING 的 Reviewers 表格與本文件記錄原始值處
  find donsetch_noavx_400/src -type f          # 必須恰好 5 個檔案（rollback.rs 必須不在內）
  diff donsetch_noavx_400/Cargo.lock donsetch-4.0.0/Cargo.lock  # 必須無差異（防 --locked 失敗；含 quiche 條目）
  diff donsetch_noavx_400/src/cli/update.rs donsetch-4.0.0/src/cli/update.rs   # 僅 REPO + 資產選擇兩處
  diff donsetch_noavx_362/build.rs donsetch_noavx_400/build.rs   # 僅上游 4.0.0 新增（version-resource 三處）
  grep -n "download-binaries\|simd" donsetch_noavx_400/Cargo.toml  # oar-ocr 保持原樣（含 simd）
  ```
- 本目錄的 `src/` 只含修改過的檔案（`src/cli/{update,version,status,doctor}.rs` + `src/onnx.rs`）。
- 本機若有 Rust toolchain，加跑 `cargo check --features ocr,rerank,noavx`（以 stub `.so` 滿足 build.rs）；若無，註明未跑。

## 5. 升級到新版 donsetch 時的移植步驟

1. 建立新目錄 `donsetch_noavx_<新版號>/`。
2. 版本無關檔案直接複製：`TESTING.md`、`ocr-sample-scan.pdf`、`scripts/build-onnxruntime-noavx.sh`（若新版仍是 load-dynamic 架構；若上游改回靜態連結，需重新評估整套設計；另先確認 build.rs ONNX 段——`fetch_onnx_prebuilt`/`copy_onnx_shared_lib`/`vendor/onnx` 路徑——未變）。**另從新版基底複製 `Cargo.lock`（不是從舊 overlay 沿用！舊 lock 缺新依賴會導致 CI `--locked` 失敗；複製後 `diff` 確認與基底一致）。**
3. 其餘檔案從新版原始目錄複製後，按第 3 節逐項套用修改（**不可盲目 patch**；先確認新版 `github/` vs `.github/` 佈局——跟隨基底，不要建鏡像；`doctor.rs` 若上游在 `check_onnx` 之外加了新函數，必須等價編輯、不可整檔複製舊版）。
4. 先檢查上游是否修了我們 patch 過的 bug（如本次的 SIBLING_LIBS）：若修了且本地驗證覆蓋完整，退役我們的對應 patch 並在本文件記錄驗證過程；若只覆蓋部分路徑，保留我們的對應部分並回報。
5. **重改新版 `src/cli/{update,version,status}.rs` 的 `REPO` 常數、新版 `check_onnx` 重加 cfg 分支、重包 `src/onnx.rs` 的 gate、新版 `platform_asset_name` 重加 noavx 分支**後，只同步修改過的檔案至新目錄的 `src/`（保持相對路徑；未修改的 src 檔案一律不同步）。
6. 跑第 4 節的驗證指令。

## 6. 已定案事項

- **CONTRIBUTING.md Reviewers 表格**：維持上游原樣（見第 3 節；用戶決定）。
- **CI 不做 OCR smoke**：樣張供用戶自測（用戶決策，沿用）。
- **退役的 patch 不刪除歷史記錄**：_362 目錄保留原樣（含其 `rollback.rs` 與舊式 update patch），本目錄不再攜帶；來龍去脈見第 2 節與 _362 的 NOAVX_MODIFICATIONS.md 第 3 節。

## 7. 已定案事項

- README 開頭 AVX 警告用詞：**定案（用戶決定）：改為 gate 停用表述**——原沿用 _320/_362 的「instant `SIGILL` crash」屬舊時代描述，load-dynamic 下實際行為是 gate 停用 OCR/rerank、主程式正常運行。已改為「standard binary 仍可運行，但 OCR/rerank 被 gate 停用」及「silently disabled」 bullet。
