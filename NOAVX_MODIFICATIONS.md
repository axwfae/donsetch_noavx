# donsetch_noavx_320 — 修改說明（給下次修改的人/AI 看）

> **閱讀時機**：任何要修改本目錄、或要把 noavx 修改移植到新版 donsetch 時，先讀完這份文件再動手。

## 1. 這個目錄是什麼

`donsetch_noavx_320/` 是 **donsetch-3.2.0 的 noavx 建置變體**，仿照 `donsetch_noavx_250/`（2.5.0 版）的結構移植而來（更早的前身是 `donsetch_noavx/`，2.3.4 版）。

**為什麼存在**：donsetch 的 OCR / 語意 rerank 功能依賴 ONNX Runtime。上游預設用 pyke.io 的預編譯二進位檔，其 x86-64 baseline 是 **x86-64-v3（AVX2+FMA）**。在沒有 AVX 的老 CPU 上（Intel Bay Trail Atom/Celeron N3540、J1900 等，只有 SSE4.2）會直接 `SIGILL` 當掉，沒有任何錯誤訊息。本目錄的所有修改都是為了讓 donsetch 能改連結「從原始碼編譯、關閉 AVX」的 ONNX Runtime。

**目錄定位**：本目錄只攜帶 noavx 建置設定、CI workflow、文件，以及 **`src/` 中「有修改」的檔案**（目前僅 `src/cli/{update,version,status}.rs` 三個，見第 3 節）。未修改的原始碼一律不同步進來，以免與基礎版產生干擾——建置時把本目錄疊在 `donsetch-3.2.0` 原始碼樹上使用。升級版本時需重新套用這些檔案修改（見第 5 節）。

**鏡像目錄**：2.x 時代上游同時維護 `.github/workflows/` 與 `github/workflows/` 兩處（歷史因素），舊變體目錄需同步兩份；**3.2.0 起上游已移除 `github/` 鏡像，本目錄僅保留 `.github/workflows/`**。

## 2. 各檔案修改內容與原因

### Cargo.toml
- `oar-ocr` features 改為 `["simd"]`、`ort` features 改為 `["std", "ndarray", "copy-dylibs"]`
  → **移除預設的 `download-binaries` / `tls-native`**：不能再用 pyke.io 的 AVX 二進位檔。
- 新增頂層 features：
  - `download-binaries = [...]`：AVX 機器想用預編譯 ONNX Runtime 時才手動開。
  - `noavx = []`：無 AVX CPU 用。搭配 `--features ocr,rerank,noavx` + `ORT_LIB_PATH` 指向本地編譯的無 AVX ONNX Runtime。
- 兩者效果互斥，不可同時啟用。
- 保留 3.2.0 自己的變化：`version = "3.2.0"`、`license = "AGPL-3.0-only"`、新增 `regex = "1"` 依賴、windows-sys 加 `Win32_System_Registry` feature。

### build.rs
- 在 aarch64+ONNX 警告區塊之後插入「noavx + ONNX linking guidance」區塊：
  - 啟用 `noavx` 卻沒設 `ORT_LIB_PATH` → 直接 panic 並提示用 `scripts/build-onnxruntime-noavx.sh`。
  - 啟用 ocr/rerank 但兩種模式都沒選 → 發 cargo warning 提醒。
  → 目的：把「忘記提供無 AVX ONNX Runtime」從神秘的連結失敗變成明確的指引。
- 2.5.0 與 3.2.0 的 build.rs 完全相同，故本目錄 build.rs 除該區塊外與上游無差異。

### .github/workflows/ci.yml
- 移除 matrix，只留 Linux x86_64（macOS/Windows/arm64 移除以加速 CI；noavx 只需要 Linux）。
- test/clippy 加 `--features ocr,rerank,download-binaries`。
- 附加 `noavx-check` job：用 stub `libonnxruntime.a`（空檔案即可，`cargo check` 不真的連結）驗證 `--features ocr,rerank,noavx` 能編譯通過。
- **port 3.2.0 的改進**：
  - `dtolnay/rust-toolchain@1.98`（釘版本，取代 stable）。
  - clippy 加 `--all-targets`（連 `#[cfg(test)]` 模組與 tests/*.rs 一起 lint）。
  - job 名稱採上游格式 `build-test (linux-x86_64)`。
  - **刻意保留** 3.2.0 新增的平台無關 jobs：`supply-chain`（cargo-deny）與 `fuzz`（5 個 target 的 90s smoke），原樣照搬。

### .github/workflows/release.yml
- build job：Linux x86_64 only，`--features ocr,rerank,download-binaries`。
- 附加 `build-noavx-linux` job：
  - 用 `scripts/build-onnxruntime-noavx.sh` 從原始碼編譯 ONNX Runtime（CMake 關閉 AVX/AVX2/AVX512），快取在 `vendor/onnxruntime-noavx`（原始碼建置約 30 分鐘～2 小時，必須快取）。
  - `cargo build --release --features ocr,rerank,noavx`，產出 `donsetch-linux-x64-noavx.tar.gz`。
  - 此二進位同時相容有 AVX 與無 AVX 的 CPU——不確定時用 noavx 版就對了。
- publish job：`needs: [build, build-noavx-linux]`。
- **port 3.2.0 的改進**：
  - `rust-toolchain@1.98`、build 加 `--locked`。
  - Verify 步驟改為 `./donsetch --version` 並比對 `${GITHUB_REF_NAME#v}` 版本號（兩個 build job 都有）。**fork 修改**：tag 帶 `_sync` 後綴（如 `v3.2.0_sync`）時先剝除再比對（`${TAGVER%%_*}`），否則二進位檔回報的純版本號（3.2.0）永遠對不上。
  - 從 CHANGELOG.md 產生 RELEASE_BODY.md 的步驟 + `body_path: RELEASE_BODY.md`。**fork 修改**：上游版找不到對應章節會 `sys.exit` 使 release 失敗；fork 的 `_sync` tag 在上游 CHANGELOG 永遠沒有章節，故改為「先找完整 tag、再退回基礎版號（`[3.2.0]`）、都沒有則寫入最小內容並繼續」，不再中斷發佈。
  - `actions/download-artifact@v8`。

### scripts/build-onnxruntime-noavx.sh
- 版本無關，直接沿用 donsetch_noavx 的版本。ONNX Runtime tag 由 release.yml 的 `ORT_TAG=rel-1.24.2` 控制。

### README.md / CONTRIBUTING.md / TESTING.md
- README 開頭加 AVX 警告區塊（含 `grep -m1 -o 'avx[0-9]*' /proc/cpuinfo` 檢查法與對照表）。
- 下載表格、建置依賴表格改 Linux-only（保留 3.2.0 自己新增的內容，如 v3 章節、602 tests badge）；Homebrew 安裝選項移除（macOS 導向且指向上游 tap，本 fork 不出 macOS 二進位）。
- 所有 `--features ocr,rerank` 提及處改為 `--features ocr,rerank,download-binaries`。
- 加入 `<details>` 的「Build for CPUs without AVX」章節。
- **clone 網址與 badge 已指向 `axwfae/donsetch_noavx`**（見第 3 節）。
- CONTRIBUTING.md 3.2.0 與 2.5.0 完全相同，直接沿用 _250 的修改版。

## 3. 更新來源（update 指令）指向 fork

**修改位置：`src/cli/{update.rs,version.rs,status.rs}` 三個檔案的 `REPO` 常數**（本目錄的 `src/` 只同步這三個修改過的檔案）

```rust
// 原：const REPO: &str = "dondai44423/donsetch";
const REPO: &str = "axwfae/donsetch_noavx";
```

**原因**：`update` 指令會從 GitHub Releases 下載新二進位檔。若指向上游 `dondai44423/donsetch`，使用者會抓到**需要 AVX 的官方版**，覆蓋掉本機的 noavx 版後在無 AVX CPU 上直接 SIGILL。因此更新來源必須指向發布 noavx 版本的 fork `axwfae/donsetch_noavx`。

**為什麼三個檔案都要改**：`version.rs` 與 `status.rs` 用同一個 `releases.atom` feed 判斷「最新版」。若只改 `update.rs`，會出現 version/status 以上游為準說有新版、update 卻去 fork 抓不到的矛盾。

**注意**：升級版本移植時**不要遺漏**此修改（新版這三個檔案的 `REPO` 會是上游值，必須重改後再同步進來）。另外 `src/pdf/ocr.rs` 的 user-agent 字串仍寫上游網址，僅為標識用途，刻意不改（也因此不同步）。

**fork Release 格式需求**：tag 為 `v3.x.x`，資產名稱 `donsetch-linux-x64.tar.gz`（+ `.sha256`）與 `donsetch-linux-x64-noavx.tar.gz`——本目錄的 release workflow 產出的正是這些名稱。

## 4. 對照基準與驗證方式

- 對照組：`donsetch_noavx/`（2.3.4 的 noavx 變體）、`donsetch_noavx_250/`（2.5.0 的 noavx 變體）、`donsetch-3.2.0/`（乾淨的上游版）。
- 驗證指令：
  ```bash
  diff -r donsetch_noavx_320 donsetch_noavx_250   # 差異應只有：3.2.0 內容漂移、workflows 的 3.2.0 改進、版本號、github/ 鏡像不存在
  python3 -c "import tomllib; tomllib.load(open('donsetch_noavx_320/Cargo.toml','rb'))"
  python3 -c "import yaml; yaml.safe_load(open('donsetch_noavx_320/.github/workflows/ci.yml'))"
  grep -rn "dondai44423" donsetch_noavx_320/   # 應無殘留（README/CONTRIBUTING 已全數改為 axwfae/donsetch_noavx）
  ```
- 本目錄的 `src/` 只含修改過的檔案（`src/cli/{update,version,status}.rs`）。可用 `diff donsetch_noavx_320/src/cli/<file>.rs donsetch-3.2.0/src/cli/<file>.rs` 驗證唯一差異是 `REPO` 常數；除此之外本目錄不得出現其他 `src/` 檔案。

## 5. 升級到新版 donsetch 時的移植步驟

1. 建立新目錄 `donsetch_noavx_<新版號>/`。
2. 版本無關檔案直接複製：`scripts/build-onnxruntime-noavx.sh`、`TESTING.md`、`ocr-sample-scan.pdf`。
3. 其餘檔案從新版原始目錄複製後，按第 2 節逐項套用修改（**不可盲目 patch**，README/build.rs 各版有內容漂移，要找對應段落做等價編輯）。
4. workflows 以本目錄版本為範本，但 port 新版的 action 版本升級與 apt 改進；上游平台無關的新 jobs（如 supply-chain/fuzz）原樣保留。
5. **重改新版 `src/cli/{update,version,status}.rs` 的 `REPO` 常數後，只同步這三個修改過的檔案**至新目錄的 `src/cli/`（新版原始檔帶上游值 `dondai44423/donsetch`；未修改的 src 檔案一律不同步，見第 1 節）。
6. 跑第 4 節的驗證指令。
