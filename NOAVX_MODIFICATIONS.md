# donsetch_noavx_425 — 修改說明（給下次修改的人/AI 看）

> **閱讀時機**：任何要修改本目錄、或要把 noavx 修改移植到新版 donsetch 時，先讀完這份文件再動手。

## 1. 這個目錄是什麼

`donsetch_noavx_425/` 是 **donsetch-4.2.5 的 noavx 建置變體**，由 `donsetch_noavx_400/`（4.0.0 版）移植而來（「換 .so + 繞 gate」設計源自 _351，經 _362/_400 驗證）。

> **用戶原則**：發佈/打包方式以**驗證過的 _250/_320 套件為準**（Linux-only + noavx job + `_sync` 容忍 + publish needs）。實務上本目錄的 workflow 結構直接繼承 _400，QEMU smoke best-effort、`.so` size floor TODO **原樣保留其保守形態**，不可放寬。移植時若發現 _400 有疑似錯誤之處，優先以 _320 的做法為準並記錄。
> **CI 不做 OCR smoke（用戶決策）**：樣張 `ocr-sample-scan.pdf` 留在 repo 供用戶自測；release/ci 的 QEMU 段只保留 doctor 探針。

**為什麼存在**：donsetch 的 OCR / 語意 rerank 功能依賴 ONNX Runtime。4.2.5 的 Linux 標準建置在編譯期下載微軟官方 `onnxruntime-linux-x64-1.24.2.tgz` 的 `.so` 隨 binary 出貨，runtime 經 `src/onnx.rs::ensure_loaded()` 先過 AVX gate 再 dlopen。在沒有 AVX 的老 CPU 上（Intel Bay Trail Atom/Celeron N3540、J1900 等，只有 SSE4.2）標準版的 OCR/rerank 被 gate 擋下。本目錄的所有修改都是為了讓 OCR/rerank 在無 AVX CPU 上真正可用：出貨自編的無 AVX `.so`，並把 AVX gate 編譯掉。

**目錄定位**：本目錄只攜帶 noavx 建置設定、CI workflow、文件、`src/` 中「有修改」的檔案（共 5 個，見第 3 節），以及**根目錄的 `Cargo.lock`**（唯一例外：與基底逐位元組相同，原樣攜帶只為防呆——見下）。未修改的原始碼一律不同步進來——建置時把本目錄疊在 `donsetch-4.2.5` 原始碼樹上使用。升級版本時需重新套用這些檔案修改（見第 5 節）。

> **Cargo.lock 例外的原因（4.0.0 實測教訓，4.2.5 沿用）**：4.0.0 新增 git 依賴 `quiche`（tag pin）。fork 端若沿用舊版的 `Cargo.lock`，內無 quiche 條目，CI 的 `cargo build --locked` 會因「需改 lock」而失敗。此後每次升版**必須同步基底的 `Cargo.lock`**（見第 5 節），本目錄直接攜帶一份即鎖定正確版本。`noavx = []` 是空 feature，不影響依賴解析，故基底 lock 可直接沿用。本目錄的 `Cargo.lock` 與 `donsetch-4.2.5/Cargo.lock` 逐位元組相同（見第 4 節驗證）。

**佈局跟隨基底**：4.2.5 上游 workflows 位於 `.github/workflows/`（另新增 `npm-publish.yml`、`stealth.yml`，見第 3 節），故本目錄僅保留 `.github/workflows/`，**不要建 `github/` 鏡像**。

## 2. 上游 4.2.5 的變化（相對 4.0.0）與對應處理

### 2.1 編譯期 env 前綴更名（舊拼寫 → `DONSETCH_*`）

上游 4.2.5 把 `build.rs`、`src/cli/version.rs`、`src/cli/doctor.rs` 內編譯期 env 變數前綴的舊拼寫（少一個 T 的版本）統一更名為 `DONSETCH_*`（`build.rs` 6 處：`GIT_HASH`×3、`PDFIUM`、`TARGET`、`FEATURES`；`version.rs` 4 處；`doctor.rs` 2 處 `PDFIUM`）。本目錄**全部跟隨新名**：

- `build.rs` NOAVX 插入塊內的 `feats.push("noavx")` 對應的是新名 `DONSETCH_FEATURES`（舊 overlay 的舊名前綴寫法不可照抄）。
- `release.yml` 第 350 行附近 `grep "noavx"` 失敗時的 NOTE 行亦同步改為新名前綴。
- 全 overlay `grep -rn` 舊拼寫必須零殘留（本文件用「舊拼寫」代稱，刻意不寫出字面以維持該保證）。

### 2.2 `version.rs` 新增 live update check → release 需抑止

4.2.5 的 `donsetch --version` 會做一次 live update check（3s timeout，`DONSETCH_NO_UPDATE_CHECK` 或 `CI` 環境變數可跳過）。`update.rs`/`status.rs` 的 `REPO` 改 fork 後，該 check 打的是 fork 的 releases.atom——功能正確，但 release.yml 的版本驗證 gate 不應依賴網路。故本目錄的 `release.yml` 在**兩個** Verify-binary 步驟（標準 leg + noavx leg，上游只有一个 matrix leg，fork 有兩個）都加了 `DONSETCH_NO_UPDATE_CHECK: "1"`（port 自上游 release.yml 的同名 env）。`--version` 的其餘邏輯（DISPLAY 化妝、profile 標籤）一字不動。

### 2.3 Release 的「Wait for CI on this commit」gate → fork 不跟進（已移除）

上游 4.2.5 在 `release` job（publish 前）新增 CI 結論轮询 gate（~40min 上限），並把 `ci.yml` 的 concurrency 改為 push 按 SHA 分組。本 fork 的用法是同步版本快照、不保證 tag 前有 master push 的 CI run——gate 會空轉 ~30 分鐘後以「CI missing」擋掉每一次發版（4.2.5 實測確認），故**移除該 gate**（`release.yml` 僅留 fork 決策註解）。驗證責任由各 build job 自帶的 gates（payload、doctor、QEMU）承擔，與 4.0.0 之前的做法一致（那時刪 ci.yml 也能正常 release）。

（本節原記載 per-SHA concurrency 的 port；ci.yml 已刪除，該項作廢，見第 2.4 節。）

### 2.4 CI（ci.yml）→ fork 不攜帶（已刪除）

本 fork 只同步版本快照、推送不跑 CI（4.0.0 之前即刪 ci.yml 照常 release），且 release 已移除 Wait-for-CI gate（見第 2.3 節），故 `ci.yml` **直接刪除不攜帶**（用戶決策）。上游 4.2.5 的 ci 新增（nightly schedule、per-SHA concurrency、tests lanes、timeout、fuzz 動態矩陣）一併不跟進。驗證責任由 release 各 build job 自帶 gates 承擔。若日後想恢復 CI，把基底原樣取回即可（noavx 無需修改 ci 內容）。

### 2.5 其餘上游漂移（本目錄跟隨，不改 noavx 語義）

- `Cargo.toml`：version=4.2.5、`psl` 2.1.231→2.1.232、features 註解改寫、`[profile.fast]` 新增。`oar-ocr`/`ort` 依賴區未變。只加 `noavx = []`。
- `src/cli/update.rs`：win-arm64 資產映射由 `win32-arm64` 改為 `win32-x64`（無 Windows ARM64 資產，跑 x64 模擬）。SIBLING_LIBS/`.so` 邏輯未變。
- `src/cli/status.rs`：與 4.0.0 完全相同。
- `src/onnx.rs`、`src/cpu.rs`：與 4.0.0 完全相同。
- `src/cli/doctor.rs`：`check_onnx()` 本體逐位元組相同（檔內其他漂移：tool-lane 探針、`DONSETCH_PDFIUM` 更名、npm 安裝判斷、`json_escape`）。
- 上游 SIBLING_LIBS 自修仍在（第 4.0.0 節記錄的退役繼續有效；`rollback.rs` 不同步）。
- 上游新增 `npm-publish.yml`、`stealth.yml`：**overlay 不攜帶**（見第 3 節）。
- `README.md` 大改寫（1061→700 行：WRB 章節被上游移除，`just` 工作流、stealth/browser 後端等新增；Homebrew 段仍在）；`CONTRIBUTING.md` 改為 `just` 階梯（但 PR 第 5 步「all 3 platforms」原文仍在，正好是等價編輯錨點）。

## 3. 各檔案修改內容與原因

> 設計仍是「**換 .so + 繞 gate**」：自編無 AVX 的 `libonnxruntime.so`，用 `noavx` feature 把 AVX gate 編譯掉。OCR 與 rerank 都經 `ensure_loaded()` 單一門控，改 gate 即全覆蓋。

### Cargo.toml

- **只新增一個 feature**（其餘一字不動，4.2.5 的依賴與 profile 漂移——psl 2.1.232、features 註解、`[profile.fast]`——全部沿用上游）：
  ```toml
  # Build/link a locally-compiled ONNX Runtime shared library that does NOT
  # require AVX (see scripts/build-onnxruntime-noavx.sh), and compile out the
  # AVX gate in src/onnx.rs so OCR/rerank run on any x86-64 CPU. Linux only.
  noavx = []
  ```
- `oar-ocr` / `ort` 依賴**刻意不動**：Linux `load-dynamic` 時靜態 AVX 機器碼不會被連結進 binary；`oar-ocr` 的 `simd` 是 Rust 執行期 dispatch，不會 SIGILL。

### build.rs

- 4.0.0→4.2.5 的差異全是第 2.1 節的更名；ONNX 段（`fetch_onnx_prebuilt`/`copy_onnx_shared_lib`/`vendor/onnx` 路徑、官方 v1.24.2）逐字未變，故 NOAVX 插入錨點（`if has_onnx { if let Some(info) ...`）仍在，插入內容與 _400 一字相同（唯 `DONSETCH_FEATURES` 用新名，見第 2.1 節）：
  - `noavx`：**絕不下載微軟官方 .so**；要求 `scripts/build-onnxruntime-noavx.sh` 已產出 `vendor/onnx/libonnxruntime.so`，缺失則 panic 並指引腳本；存在則直接 `copy_onnx_shared_lib`。
  - 非 Linux 平台 warn 後忽略；非 `noavx` 路徑保持現狀。
- `DONSETCH_FEATURES` 段 push `noavx` 保留（`donsetch -v` 可區分兩版）。
- 與 _400 版 `diff` 應只剩上游更名 6 處（見驗證節）。

### src/onnx.rs

- 與 _400 版**逐位元組相同**（已驗證 4.2.5 `src/onnx.rs`、`src/cpu.rs` 與 4.0.0 完全相同）：gate 用 `#[cfg(not(feature = "noavx"))]` 包裝 + noavx 專用可執行缺件報錯（指明兩個查找位 + 重解 tarball 取雙檔 + 清 avx.json + 跑 doctor）。
- **`src/cpu.rs` 絕對不要動**（`has_avx()` 是標準版 gate 與 payload probe 共用的真相來源）。

### src/cli/doctor.rs（必須等價編輯，不可整檔複製）

- 4.2.5 基底上，對 `check_onnx` 的 Linux 分支做與 _400 等價的 cfg 編輯：`noavx` 時跳過 `has_avx`，直接 `ensure_loaded()` 真探後 Pass（"noavx build, shared library loaded"）/Fail；非 `noavx` 保持現狀。
- 驗證：與 _400 版 `diff` 應只剩上游 4.2.5 新增部分（含更名）。

### src/cli/{update,version,status}.rs

- 三檔 `REPO` 常數改 fork：`const REPO: &str = "axwfae/donsetch_noavx";`（`version.rs` 的 DISPLAY 化妝與 update-check 抑止邏輯原樣保留，只改 REPO 單行；`status.rs` 與 4.0.0 相同，只改 REPO 單行）。
- `update.rs` 另加 `platform_asset_name()` 的 noavx 資產選擇（上游無 noavx 概念，`("linux","x86_64")` 仍寫死 `linux-x64`，照抄 _400 的 `cfg!(feature="noavx")` 分支回傳 `linux-x64-noavx`）。其餘上游 SIBLING_LIBS 邏輯一字不動。
- `src/pdf/ocr.rs` 的 user-agent 字串僅為標識用途，刻意不改（也因此不同步）。

### scripts/build-onnxruntime-noavx.sh / ocr-sample-scan.pdf

- 版本無關，直接沿用 _400（4.2.5 build.rs ONNX 段未變：同為官方 v1.24.2、`vendor/onnx/libonnxruntime.so` 路徑、已存在則早退；腳本 `ORT_TAG=rel-1.24.2` 與之對應）。

### .github/workflows/ci.yml → 已刪除不攜帶（見第 2.4 節）

### .github/workflows/release.yml

- _400 結構原樣（Linux-only build job + `build-noavx-linux` + payload gates + `.so` floor TODO + QEMU doctor probe + `_sync` 容忍 + publish `needs: [build, build-noavx-linux]`），僅版本引用 `v4.0.0_sync`→`v4.2.5_sync`、`[4.0.0]`→`[4.2.5]`，另加第 2.2 節的 NO_UPDATE_CHECK env（兩個 Verify 步驟）；第 2.3 節的 Wait-for-CI gate **已移除不跟進**（見該節）。
- 版本驗證剝 `${TAGVER%%_*}` 後綴；release notes 三級降級不中斷（上游 4.2.5 原版此處仍是硬失敗 `sys.exit`，必須保留容忍修復）。

### 上游新增但 overlay 不攜帶：npm-publish.yml、stealth.yml

- 兩檔皆為上游 4.2.5 新增，noavx 無需修改。fork 端沿用基底原樣即可：疊加本目錄時不要刪除 fork 內已有的這兩檔；若 fork 之前沒有，從基底複製原樣放入，不要改。

### README.md / CONTRIBUTING.md / TESTING.md

- README：等價編輯——開頭 AVX 警告區塊（照抄 _400 文字，gate 停用表述）、npm 段後 CPU 選擇表、Homebrew 選項移除、clone 改 fork、Build-from-source 內嵌 noavx `<details>`（TAG 範例改 `v4.2.5_sync`）、Gotchas OCR 列補 noavx 說明、footer badge/links 改 fork；Bladebro、DeepSeek Harness（`dondai44423/donsetch-dsh`）段維持上游（上游已移除 WRB 章節，故本版無 WRB 段可維持——非刪除，是跟隨上游）。
- CONTRIBUTING：clone 網址改 fork（`cd donsetch_noavx`）、full build 行加 AVX 註記、CI 平台改 Linux only + noavx 建置指引（錨點改為 `just` 段的 "full gate (5 platforms…)" 句）、PR 第 5 步改 Linux；Reviewers 表格维持上游原樣（用户定案：該表描述上游人事結構，`@dondai44423` 不在取代範圍內）。
- TESTING.md：沿用 _400（§1 防呆安裝步驟已是修正版），僅兩處版本相關更新：TAG 範例 `v4.0.0_sync`→`v4.2.5_sync`；MCP 預期 `serverInfo: donsetch 4.0.0`→`4.2.5`（4 個工具數維持——4.2.5 仍是 4 工具）。§7 實測記錄表（2026-08-20，2.3.4）為歷史記錄，原樣保留。

## 4. 對照基準與驗證方式

- 對照組：`donsetch_noavx_400/`（4.0.0 的 noavx 變體）、`donsetch-4.2.5/`（乾淨的上游版）。只引用工作區現存路徑。
- 驗證指令：
  ```bash
  diff -r donsetch_noavx_425 donsetch_noavx_400   # 預期差異只有：第 2 節的上游漂移（更名/version.rs update-check/concurrency+gate/ci lanes+timeout+features 註解+profile.fast/README 重寫/CONTRIBUTING just 化/doctor 其他段）、版本号引用、TESTING 兩處更新、workflows 回到 .github/（沿用）；其餘應無差異
  python3 -c "import tomllib; tomllib.load(open('donsetch_noavx_425/Cargo.toml','rb'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_425/.github/workflows/release.yml'))"
  test ! -e donsetch_noavx_425/.github/workflows/ci.yml   # ci.yml 已刪除（見第 2.4 節）
  grep -rn "dondai44423" donsetch_noavx_425/   # 應只剩 README 的 bladebro 段與 dsh 段、CONTRIBUTING 的 Reviewers 表格與本文件記錄原始值處
  # 另以 grep 確認全 overlay 無舊拼寫前綴殘留（少一個 T 的版本；本文件以代稱敘述，刻意不寫字面，以免自我匹配）
  find donsetch_noavx_425/src -type f          # 必須恰好 5 個檔案（rollback.rs 必須不在內）
  diff donsetch_noavx_425/Cargo.lock donsetch-4.2.5/Cargo.lock  # 必須無差異（防 --locked 失敗）
  diff donsetch_noavx_425/src/cli/update.rs donsetch-4.2.5/src/cli/update.rs   # 僅 REPO + 資產選擇兩處
  diff donsetch_noavx_400/build.rs donsetch_noavx_425/build.rs   # 僅上游更名 6 處
  grep -n "download-binaries\|simd" donsetch_noavx_425/Cargo.toml  # oar-ocr 保持原樣（含 simd）
  ```
- 本目錄的 `src/` 只含修改過的檔案（`src/cli/{update,version,status,doctor}.rs` + `src/onnx.rs`）。
- 本機若有 Rust toolchain，加跑 `cargo check --features ocr,rerank,noavx`（以 stub `.so` 滿足 build.rs）；若無，註明未跑。

## 5. 升級到新版 donsetch 時的移植步驟

1. 建立新目錄 `donsetch_noavx_<新版號>/`。
2. 版本無關檔案直接複製：`TESTING.md`、`ocr-sample-scan.pdf`、`scripts/build-onnxruntime-noavx.sh`（若新版仍是 load-dynamic 架構；若上游改回靜態連結，需重新評估整套設計；另先確認 build.rs ONNX 段——`fetch_onnx_prebuilt`/`copy_onnx_shared_lib`/`vendor/onnx` 路徑——未變）。**另從新版基底複製 `Cargo.lock`（不是從舊 overlay 沿用！舊 lock 缺新依賴會導致 CI `--locked` 失敗；複製後 `diff` 確認與基底一致）。**
3. 其餘檔案從新版原始目錄複製後，按第 3 節逐項套用修改（**不可盲目 patch**；先確認新版 `github/` vs `.github/` 佈局——跟隨基底，不要建鏡像；`doctor.rs` 若上游在 `check_onnx` 之外加了新函數，必須等價編輯、不可整檔複製舊版；上游新增的不相關 workflow 檔（如本次的 npm-publish/stealth）不攜帶）。
4. 先檢查上游是否修了我們 patch 過的 bug（如 4.0.0 的 SIBLING_LIBS）：若修了且本地驗證覆蓋完整，退役我們的對應 patch 並在本文件記錄驗證過程；若只覆蓋部分路徑，保留我們的對應部分並回報。另檢查上游有無更名/新 env（如本次的前綴更名、NO_UPDATE_CHECK），overlay 必須跟隨新名。
5. **重改新版 `src/cli/{update,version,status}.rs` 的 `REPO` 常數、新版 `check_onnx` 重加 cfg 分支、重包 `src/onnx.rs` 的 gate、新版 `platform_asset_name` 重加 noavx 分支**後，只同步修改過的檔案至新目錄的 `src/`（保持相對路徑；未修改的 src 檔案一律不同步）。
6. 跑第 4 節的驗證指令。

## 6. 已定案事項

- **CONTRIBUTING.md Reviewers 表格**：維持上游原樣（見第 3 節；用戶決定）。
- **CI 不做 OCR smoke**：樣張供用戶自測（用戶決策，沿用）。
- **退役的 patch 不刪除歷史記錄**：_400 目錄保留原樣，本目錄不再攜帶上游已修的 SIBLING 段；來龍去脈見 _400 的 NOAVX_MODIFICATIONS.md 第 2 節。
- **README 開頭 AVX 警告用詞**：**定案（用戶決定）：gate 停用表述**——load-dynamic 下實際行為是 gate 停用 OCR/rerank、主程式正常運行（「standard binary 仍可運行，但 OCR/rerank 被 gate 停用」及「silently disabled」bullet）。
- **npm-publish.yml / stealth.yml 不攜帶**：fork 沿用基底原樣（用戶決策，見第 3 節）。
- **Wait-for-CI gate 已移除不跟進**：fork 只同步版本快照，不保證 tag 前有 master push 的 CI run，gate 會空轉 ~30 分鐘後擋掉每次發版（實測確認）。驗證責任由各 build job 自帶 gates 承擔（用戶決策，見第 2.3 節）。
- **README 的 CI 平台描述句改為 Linux-only**：4.2.5 README 兩處 "full matrix on Linux, macOS and Windows / three platforms" 已改為 Linux x86_64 描述（**定案，用戶決定**）——fork 只建 Linux，維持上游原文屬事實不符。
- **上游 `heavy` CI job 不 port**：多平台矩陣範疇，fork 保持 Linux-only；nightly 重跑同一 Linux suite（見第 2.4 節）。

## 7. 已定案事項（本節原為「未解決疑點」，已全數定案）

- README CI 平台描述句：見上（已改為 Linux-only，用戶決定）。
