# 1.0.8 验证记录

版本：1.0.8（Build 37），Apple Silicon，macOS 26.0 及以上。本轮实测机器为 macOS 26.7.2。

本轮修复 Google Sheets 在清晰显示与浏览器支持提示之间的兼容问题。1.0.7 改用原生 WebKit 身份后，画布恢复 Retina 密度，但 Google 会显示浏览器不受支持提示。本轮保留原生身份作为默认值，仅在 macOS 26.4 及以上的 Google Search 和 Sheets 指定地址使用 Safari 26.4 兼容身份；平台及 WebKit 标识仍保留独立空白、非持久化 WKWebView 返回的原生值。UA 中的 WebKit 标识是兼容标识，不代表系统 WebKit 的实际版本号；也不使用已安装 Safari 应用的版本推断 WKWebView 版本。

## 根因与范围

Google Sheets 对 Safari 26.4 之前的身份应用 `outerWidth / innerWidth` 旧缩放修正。原生 WKWebView 的 `outerWidth` 可为 0，该路径将修正限制在 0.25，Retina 的 `devicePixelRatio=2` 因而变成 `2 × 0.25 = 0.5` 的表格画布密度。Safari 26.4 身份绕过该旧修正，使表格使用包含页面缩放的实际 DPR。该修复调整站点身份选择，未更换 WebKit 引擎或修改渲染 layer。

- Google Search 兼容身份仍严格限于 `google.com` / `www.google.com` 的 `/`、`/webhp`、`/search`。
- Google Sheets 兼容身份仅用于 `docs.google.com/spreadsheets` 及其子路径、`sheets.google.com`，并检查协议、精确主机、默认端口及 URL 路径边界。
- macOS 26.0–26.3 继续保留 Search 的 Safari 26.0 兼容身份；Sheets 使用原生 WebKit 身份。本轮不宣称消除这些旧系统上的浏览器支持提示。
- 其他网站保持原生 WebKit + NousBrowser 标识。没有注入脚本或样式来隐藏 Google 提示。

相关上游依据：[Safari 26.4 的页面缩放与 DPR 修复说明](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)、[WKWebView 窗口尺寸为零的问题记录](https://bugs.webkit.org/show_bug.cgi?id=324366)。本轮没有使用私有窗口尺寸代理接口。

## 对照与验收

独立原生 WKWebView 的六种身份对照矩阵已完成。在同一 Google Sheets 页面、`devicePixelRatio=2` 下，Safari 26.0 身份的画布像素密度为 0.5；Safari 26.4 身份（包括附加 NousBrowser 标识）恢复为 2，且没有浏览器不受支持提示。原生 WK 身份仍显示该提示。该结果验证了身份分流与低密度画布的关系。

| 浏览器页面缩放 | 实测 DPR | Safari 26.0 画布横向密度 | Safari 26.4 + NousBrowser 画布横向密度 | 后者的版本提示 |
| --- | ---: | ---: | ---: | --- |
| 80% | 约 1.6 | 0.4 | 1.6 | 无 |
| 100% | 2 | 0.5 | 2 | 无 |
| 125% | 2.5 | 0.625 | 2.5 | 无 |

密度取 `canvas.width / canvas.getBoundingClientRect().width`；纵向存在整数像素取整误差。诊断程序的 NousBrowser 后缀为 1.0.7，最终 1.0.8 身份另在真实 Nous 窗口完成以下界面验收。表格工具栏自身的 100% 缩放与上述浏览器页面缩放分别验证。

| 检查 | 状态 |
| --- | --- |
| 独立 WKWebView 六种身份矩阵 | 已完成；现代 Safari 兼容身份清晰且无不支持提示 |
| 最终 Safari 26.4 + NousBrowser/1.0.8 身份 | 真实 Nous 窗口无浏览器版本提示，表格文字清晰 |
| 真实 Nous 窗口 80% / 100% / 125% 缩放 | 已逐档目视验证清晰度和提示状态；画布密度另由上方原生诊断矩阵验证 |
| 真实可编辑表格的输入与保存 | 已在独立测试副本中验证中文、多单元格粘贴、公式、保存到云端及重新加载 |
| Search → Sheets、前进、后退与刷新 | 已通过；Search 保持现代页面，返回 Sheets 后仍清晰且无版本提示 |
| 用户原有 Google Sheets 页面 | 安装版中只读打开核验：版本提示消失；未修改原表格 |
| `/Applications/Nous Browser.app` 安装与会话保留 | 已安装并启动 1.0.8 Build 37；程序与 `build/Nous Browser.app` 中签名打包后的发布程序逐字节一致，原有标签 ID 及相对顺序保留 |

编辑验收使用公开样例的独立副本，未在用户业务表格中写入测试数据。通过 Nous 界面向空白的 H1:I2 粘贴 `Nous QA`、`中文输入`、公式 `=1+2` 和数字 `3`；Google Sheets 显示保存完成后，通过云端接口读回确认字符串、公式、公式有效值 `3` 及数字 `3` 一致。重新加载页面后数据仍在，并显示已保存到云端。本轮验证覆盖这些实际编辑操作，不代表穷尽 Sheets 的全部功能。

更新前正常退出并备份了应用及会话。最终读回核验：仍为原有两个窗口，原有标签 ID 和相对顺序均保留，独立验收窗口已关闭。用户在验收期间新增了标签，因此不以标签总数、选中项或侧边栏状态完全不变作为结论。

本机证据保存在 `.build/sheets-profile-diagnostic/zoom-80/`、`zoom-100/`、`zoom-125/`，以及 `nous-supported-80.png`、`nous-supported-100.png`、`nous-supported-125.png`、`nous-supported-after-navigation.png`、`nous-edit-saved.png`。含用户原表格内容的截图只保留在本机，不随仓库或安装包发布。

## 自动化与构建

- 完整 `swift test`：203 项测试、31 个套件，198 项通过、5 项需要原生事件循环的密码填写场景按预期跳过，0 失败；耗时 21.306 秒。13 项身份策略测试覆盖 Search/Sheets URL 边界、系统能力门槛、缓存、原生回退及异步结果取消。
- Release 构建通过，编译耗时 11.96 秒。旧构建保存在本机 `.build/app-package.2yjHGU/Nous Browser.previous.app`。
- DMG、ZIP 与 SHA256 已生成。应用及 DMG、ZIP 内应用均通过严格签名验证，包内程序及版本元数据与 Release 构建一致；实际架构为 arm64，最低 macOS 26.0，仍为未公证 ad-hoc 签名。DMG 已校验并以只读方式挂载检查，安装载荷仅含应用与 `/Applications` 快捷方式。
- 本轮未改动密码填写和页面桥接，也未重建原生密码填写测试宿主。

日志：`.build/sheets-supported-tests.log`、`.build/sheets-supported-release.log`、`.build/sheets-supported-package.log`。

| 资产 | 大小 | SHA256 |
| --- | ---: | --- |
| `Nous-Browser-1.0.8-macOS-arm64.dmg` | 4,416,353 字节 | `3de972a3ff7bd7e1a323abfa644ced33d22a978b3b175f964041fef2068670f1` |
| `Nous-Browser-1.0.8-macOS-arm64.zip` | 4,380,856 字节 | `99763b1a71c70359fa712d085763b203e5bfef8aa4e51c3384c2e3a2932a260b` |
| `SHA256SUMS.txt` | 202 字节 | `5b15e2adf81e7543f370931229ac78a3366063a90ba5a9ab3167b0014e4487b7` |
