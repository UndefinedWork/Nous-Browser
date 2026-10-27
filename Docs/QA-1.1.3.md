# 1.1.3 Gmail 识别与快捷访问图标验证记录

版本：1.1.3（Build 43），Apple Silicon，macOS 26.0+。本次实测系统为 macOS 26.7.2。

## 根因与修复

### Gmail 浏览器版本提示

1.1.2 的 Google 站点兼容范围包含 Search、Docs、Slides、Sheets，遗漏了 Gmail；实际安装版邮箱加载完成后仍显示蓝色“不支持此浏览器版本”提示。

现在统一为 Google Workspace 策略，新增精确的 `mail.google.com` 根入口和 `/mail` 路由。保留 macOS 26.4 能力门槛、系统实际平台及 WebKit 字段、NousBrowser 标识。认证域名和其他网站继续使用原生身份。没有隐藏警告条或修改 Google 页面脚本。

Google 官方说明：[Gmail 支持的浏览器](https://support.google.com/mail/answer/6557?hl=en)。识别改善不代表穷尽 Gmail 的全部功能；macOS 26.0–26.3 不在本轮兼容身份适用范围内。

### Zoom Slides 快捷图标

`slides.zoom.com` 会跳转到 `slides.zoom.us`，页面在 HTML head 声明了 CDN 上的 PNG favicon；`/favicon.ico` 返回的是 HTML。原快捷入口只请求根图标，正确拒绝 HTML 后只能显示地球占位图，并非图片解码失败。

现在已配置的快捷入口会读取公开 HTML head 中的图标声明，跟随重定向并解析相对地址及 `<base>`，失败时使用原有根图标兜底。结果按快捷入口完整 URL 缓存，不提升为全站文档图标。网页已提供的动态或自定义文档图标，以及迟到请求的覆盖保护继续保留。

发现请求使用不带用户 Cookie 和认证信息的临时会话，限制 HTML 大小和超时，不执行网页脚本或载入外部 XML 实体。输入／历史建议不启用 HTML 发现，不提前请求尚未提交的完整页面地址。

## 自动化验证

- 浏览器身份专项 15 项通过，包含 Gmail 根入口和邮箱页的冷启动、业务间跳转、离开后恢复、异步取消，以及真实 WKWebView 的 `navigator.userAgent` 读回。
- 新增快捷图标 4 项本地 fixture 测试通过，覆盖重定向／直接入口、声明图标替换旧根缓存、相对路径与实体、仅解析 head、大 body、HTML 假图标拒绝、失败重试节流、文档隔离，以及 HTML／图片两阶段迟到请求保护。
- 完整 `swift test`：应用 250 项／38 套件，MCP 共享层与 SDK 8 项／3 套件；合计 258 项，253 项通过、5 项原有密码事件循环场景按预期跳过，0 失败。
- Release 构建无编译警告／错误；`git diff --check` 通过。

## 安装版核验

- 修复前的 1.1.2（42）实际复现 Gmail 蓝色版本警告和 Zoom Slides 快捷入口的地球占位图。
- 正常退出旧应用并备份会话／应用后，安装到 `/Applications/Nous Browser.app`。安装版为 1.1.3（43），主程序和 MCP helper 与 Release 构建逐字节一致。
- 原 Gmail 标签恢复、加载完成和普通刷新后，均可见邮箱搜索框且无版本警告。此次只检查页面加载与提示，没有发送邮件或声称穷尽邮件功能测试。
- 在原有 Cmd+L 快捷入口配置中，`https://slides.zoom.us` 已显示网站声明的蓝色图标。磁盘缓存对应网站 head 声明的 PNG，而非硬编码映射；没有清除旧缓存来获得结果。
- 原有 1 个窗口、8 个标签的 ID、顺序和 URL 均保留。文档动态 favicon 的既有自动化测试继续通过，本轮未改动该观察机制。
- 应用及 helper 严格签名验证、DMG 校验及只读挂载、ZIP 解包与包内二进制比对均通过。仍为 ad-hoc 签名、未经 Apple 公证的开发预览包。

本机证据位于 `.build/compat43-*.log`、`.build/compat43-gmail-loaded.txt` 和 `.build/quicklink43-*.png`；含用户邮箱内容的截图仅存本机，不进入仓库或安装包。

| 资产 | 字节 | SHA256 |
| --- | ---: | --- |
| Nous-Browser-1.1.3-macOS-arm64.dmg | 5,955,008 | `53bb1ee7c13f90de978fb084955f4193271180f46f0611fff1bd5c21c61296e9` |
| Nous-Browser-1.1.3-macOS-arm64.zip | 5,929,411 | `c29cafa3adad3c36b453836e29fcd10296b296f95e840e9f4f21f448a157554a` |
