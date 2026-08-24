# TESTING — 安装后测试指引

> 本文件是 **DonSeTch（donsetch_noavx）安装后的第一份必读文档**。
> 安装完成后请先按本文件逐项测试，了解每个功能及其预期结果，
> **不要重新摸索**，避免重复排障和无用的动作。

本指引基于在 **无 AVX CPU（Intel Celeron J1900，仅 SSE4.2）** 上的实际安装与测试整理。
若你的 CPU 支持 AVX/AVX2，安装与测试命令完全一致，只是可下载标准版（见 README）。

---

## 1. 安装（无 AVX CPU 推荐路径）

```bash
# 确认 CPU 是否支持 AVX
grep -m1 -o 'avx[0-9]*' /proc/cpuinfo   # 无输出 = 无 AVX，必须用 noavx 版

# 下载 noavx 预编译二进制（以 v2.3.4_sync 为例）
curl -sL -o donsetch-linux-x64-noavx.tar.gz \
  "https://github.com/axwfae/donsetch_noavx/releases/download/v2.3.4_sync/donsetch-linux-x64-noavx.tar.gz"

# 校验 SHA256（与 .sha256 文件比对）
sha256sum donsetch-linux-x64-noavx.tar.gz

# 解压并安装到 PATH
tar -xzf donsetch-linux-x64-noavx.tar.gz
chmod +x donsetch
sudo cp donsetch /usr/local/bin/donsetch

# 验证
donsetch version
```

> ⚠️ **禁止** `sudo donsetch update`：自更新会拉取标准 ABX 版二进制，
> 在无 AVX CPU 上会立即 `SIGILL` 崩溃，破坏当前可用的 noavx 版本。

---

## 2. 安装后快速验证

```bash
donsetch version   # 应显示版本/features: ocr, rerank
donsetch doctor    # 健康检查；缺 Chrome/Xvfb 属环境限制，不影响核心功能
donsetch status    # 版本/key/proxy/cache/health 概览
donsetch tools     # 应输出 3 个工具 schema: web_fetch / web_search / web_crawl
```

预期：`doctor` 中 "Chrome/Chromium not found" 两项失败为预期现象（见第 6 节限制），
其余核心检查应全部通过。

---

## 3. 核心功能测试（可全部直接照抄执行）

以下每一项均给出**命令 + 预期结果**。全部实测通过。

### 3.1 fetch（抓取网页 → Markdown）

```bash
donsetch fetch https://example.com
# 预期: 返回 Example Domain 的 markdown，末尾 "[fetch] ok · 142 chars · tier 1 · ContentOk"

# 目录/focus 选项
donsetch fetch https://example.com --toc
donsetch fetch https://example.com --focus "domain"

# PDF 解析（自动识别 Content-Type / magic bytes）
donsetch fetch "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
# 预期: 提取出 "Dummy PDF file" 文本
```

### 3.2 search（免密钥多引擎搜索 + 语义重排）

```bash
donsetch search "rust async tokio" --max-results 5
# 首次运行会自动下载 rerank 模型(ms-marco-MiniLM, ~23MB)到 ~/.cache/donsetch/
# 预期: 返回结果列表，末尾 "provider local"，耗时约 3-30s
```

### 3.3 crawl（站点爬取 → Markdown）

```bash
# content 模式（绕过 sitemap，从种子 BFS）
donsetch crawl https://example.com --mode content --max-pages 3
# 预期: 1 页，stop=FrontierEmpty

# map 模式（仅 URL 清单，最省资源）
donsetch crawl https://tokio.rs/tokio/tutorial --mode map
# 预期: 无 sitemap 时诚实提示改用 content 模式，而非报错

# full 模式（sitemap 发现 + 内容，多页面）
donsetch crawl https://www.python.org/about/ --mode full --max-pages 3 --topic "python getting started"
# 预期: 返回多页 markdown + 每页 quality 评分
```

### 3.4 crawl resume（预算中断 → 令牌续爬）

```bash
# 1) 用很小的字符预算触发 CharBudget 停止
donsetch crawl https://www.python.org/about/ --mode content --max-chars 4000 --json
#    从输出的 meta.resume 拿到续爬令牌，例如 c65972fc92204d0

# 2) 用令牌继续爬取
donsetch crawl https://www.python.org/about/ --mode content --resume <令牌> --max-chars 8000
# 预期: 继续爬取并输出新页面
```

### 3.5 PDF OCR（扫描版 PDF，无文本层）

> 测试样张 **`ocr-sample-scan.pdf`** 已随仓库保存（21KB，单页 200dpi 扫描，
> 无文本层），无需再上网找寻。

```bash
# 首次使用自动下载 PP-OCR 模型到 ~/.cache/donsetch/ocr/
donsetch fetch "http://solutions.weblite.ca/pdfocrx/scansmpl.pdf"
# 预期: 日志注明 "1 page(s) were OCR'd ... confidence 97%"，
#       并输出恢复出的文字（200dpi 老扫描，个别词有噪声属正常）
```

**本地样本的用法说明（重要）：**
- `donsetch fetch` 仅支持 `http(s)` URL，`file://` 会被拒绝；
- 内置 **SSRF 防护**会拦截 `127.0.0.1` / 内网私有地址，
  故 `http://127.0.0.1:<port>/ocr-sample-scan.pdf` 这类本地直连会报
  `blocked ... private/loopback address`，属预期安全行为，
  环境变量 `DONSETCH_ALLOW_PRIVATE_EGRESS` 不会解除该拦截；
- 因此本地图测试用**原始公网 URL**（上表命令）即可，
  或把该 PDF 上传到任意公网可访问的托管后使用；
- 若在**可信内网/离线环境**部署且确需本地样本直连，需使用未启用
  SSRF 拦截的部署方式（如直接对接内部网关），此处不展开。

---

## 4. MCP 服务器测试

```bash
# 冒烟测试：initialize + tools/list + tools/call 一次管道验证
printf '%s\n%s\n%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cli-test","version":"1.0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | donsetch mcp

# 实际调用 web_fetch
printf '%s\n%s\n%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cli-test","version":"1.0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"web_fetch","arguments":{"url":"https://example.com"}}}' | donsetch mcp
```

预期：返回 `serverInfo: donsetch 2.3.4`、3 个工具、调用返回结构化内容。

在 opencode 配置中接入 MCP：

```json
{ "mcp": { "donsetch": { "type": "local", "command": ["donsetch", "mcp"] } } }
```

---

## 5. 配置管理命令

```bash
# BYOK 密钥（本地无密钥时全部返回 "no keys configured" 属正常）
donsetch keys add tinyfish sk-test-...      # 添加(可用假 key 测试流程)
donsetch keys list                          # 列出(掩码显示)
donsetch keys remove tinyfish               # 移除
donsetch keys reset                          # 清空

# 代理
donsetch proxy add "http://127.0.0.1:8080"  # 语法是完整 URL，不是散列参数
donsetch proxy list
donsetch proxy check                          # 无服务时如实显示 dead，属预期
donsetch proxy clear
```

> 注意：`fetch` 默认带 SSRF 防护，会拦截 `127.0.0.1` 等私有地址（预期行为）。

---

## 6. 已知限制（实测确认，非缺陷）

| 项目 | 现状 |
|---|---|
| tier 2 浏览器功能 | `doctor` 显示缺 Chrome/Xvfb。无 AVX CPU 无法运行现代 Chrome；Ubuntu 24.04 的 `chromium-browser` 仅 snap 过渡包（容器无 snapd）。`fetch --tier 2` 会如实报错而非挂死。bot-wall 绕过、`actions` 页面交互功能暂无法在本机验证 |
| `update` | 可在无 AVX 机器上下载/校验/提取成功，替换因权限失败时提示 `sudo donsetch -u`；但**切勿**在无 AVX CPU 上完成更新（会拉到 AVX 标准版导致 SIGILL） |
| `rollback` | 无历史备份时如实提示 "No backup found" |
| 搜索 | 依赖公网搜索引擎，个别引擎被限流（如 mojeek blocked）会诚实标注 `weak`/`degraded` |
| 交互验证码 | hCaptcha / reCAPTCHA / Turnstile 刻意不解（设计如此） |

---

## 7. 完整实测记录（2026-08-20）

| 功能 | 命令 | 结果 |
|---|---|---|
| version | `donsetch version` | ✓ 2.3.4, chrome-150 |
| doctor | `donsetch doctor` | ✓ 8/13 项通过（Chrome/Xvfb 缺失属预期） |
| status | `donsetch status` | ✓ 正常 |
| tools | `donsetch tools` | ✓ 3 个工具 schema |
| fetch | `fetch example.com / toc / focus` | ✓ tier 1, ContentOk |
| fetch PDF | W3C dummy.pdf | ✓ 提取文本 |
| fetch OCR | weblite 扫描样张 | ✓ 97% 置信度 |
| search | `rust async tokio` | ✓ 5 结果, 27.6s |
| crawl | content/map/full | ✓ 均正常 |
| crawl resume | CharBudget → token 续爬 | ✓ 成功 |
| mcp | initialize/tools/list/call | ✓ 全部正常 |
| keys | add/list/remove/reset | ✓ 正常 |
| proxy | add/list/check/clear | ✓ 正常（死连接如实报告） |
| update | `donsetch update` | ✓ 下载/校验/提取成功,替换因权限失败(预期) |
| rollback | `donsetch rollback` | ✓ 无备份如实提示(预期) |
| SSRF | 抓取 127.0.0.1 | ✓ 诚实拦截 |