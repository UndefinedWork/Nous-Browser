# 1.0.9 验证记录

版本：1.0.9（Build 38），Apple Silicon，macOS 26.0 及以上。本轮实测为 macOS 26.7.2（25G320）。

本轮修复选中文字后，右键“Search with Google”启动 Safari 的问题。WebKit 的原生动作通过系统搜索服务执行，并不经过网页导航代理；现在由 Nous 使用当前配置的搜索引擎创建并选中来源标签下方的新标签。[WebKit 上游实现](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebPageProxyMac.mm)。

## 改动与排查

- 搜索标题跟随 Nous 的默认搜索引擎；Google、Bing、DuckDuckGo、百度使用现有搜索 URL 生成器，保留中文、加号等查询内容的编码。移动标签后采用目标窗口的设置。
- 隔离的网页桥接在真实右键事件中读取实际 frame 的选区；检查来源、端口、页面、位置、时效与长度。缺少有效选区时禁用自身搜索，不保留原生系统搜索 action。
- macOS 会独立追加和复用 Services 菜单。通过公开的菜单通知移除其中重复的系统网页搜索、Open URL 和 Safari 阅读列表入口；单个全局观察器处理菜单变化，原生标题只解析一次。
- 移除明确的 Open in Safari / Open with Safari 菜单项；保留查词、翻译、复制、分享、朗读、文件服务及用户明确选择的第三方应用服务。
- 对已确认格式的 `x-safari-https://` 网站链接转换为普通 HTTPS，在 Nous 内部导航；不猜测未知应用协议的载荷。邮件、Zoom 等其他应用协议仍采用原有的明确确认流程。
- 地址栏、快捷访问、历史推荐、Command 点击、target=_blank、window.open、右键新标签/新窗口均通过 Nous 的模型或弹窗代理处理。源码没有向 NSWorkspace 发送普通 HTTP/HTTPS 的路径；Passwords.app 和 Chrome 密码导出是用户明确选择的导入工具。
- 本轮没有更改 macOS 默认浏览器。普通网页访问与明确的外部文件查看、分享或第三方服务分别遵循各自操作含义，不宣称拦截任意第三方服务的内部行为。

## 原生界面验收

独立调试会话与最终 `/Applications/Nous Browser.app` 安装版均完成检查。没有使用网页脚本点击菜单，也没有通过修改系统默认浏览器掩盖问题。

| 检查 | 结果 |
| --- | --- |
| Google 选中文字搜索 | 调试版与正式安装版均通过；结果留在 Nous，位于来源标签下一项且选中 |
| 更改默认搜索引擎为 Bing | 调试版真实设置与菜单点击通过；标题及结果使用 Bing |
| 跨来源 iframe 的选区搜索 | 调试版通过；实际 frame 内选区用于 Bing 查询 |
| 普通链接、target=_blank、window.open | 调试版通过；保持内部导航，window.open 的 opener 关系保留 |
| 右键链接新标签与新窗口 | 调试版通过；分别创建相邻标签和独立窗口 |
| 图片的原生打开入口 | 调试版通过；图片在 Nous 内显示 |
| 重复打开 Services 菜单 | 调试版与安装版均确认：系统网页搜索、Open URL、Safari 阅读列表入口消失；其余文件及第三方服务保留 |
| Safari HTTPS 包装链接 | 安装版真实点击通过；Apple 页面在 Nous 内以 HTTPS 打开，没有外部应用确认，也没有启动 Safari |
| 安装与会话 | 已安装并运行 1.0.9 Build 38，程序与签名后的发布包逐字节一致；原有一个窗口、20 个标签 ID 及相对顺序保留；独立验收窗口已关闭 |

安装前等待当前页面显示保存完成，再正常退出并备份应用与会话。验收只使用本机固定测试网页；自动生成的测试标签已清理，未在业务文档中写入数据。运行进程确认来自 `/Applications/Nous Browser.app`，Safari 未启动。

本机证据：`.build/context-routing-fixture/`、`.build/context-routing-qa38-*/`、`.build/context-routing-installed-menu.png`、`.build/context-routing-installed-search.png`。这些测试会话、请求记录、用户会话和截图不随仓库发布。

## 自动化与发布包

- 完整 `swift test`：212 项、33 个套件，207 项通过、5 项原生密码事件循环场景按预期跳过，0 失败，耗时 16.009 秒。跳过项目不计为通过；密码功能未改动。
- 新增测试覆盖实际 frame 来源及端口、无效或过长选区、菜单时效与位置、原生搜索动作替换及失效、多语言占位格式、Services 网页动作过滤、搜索引擎设置、相邻插入、跨窗口移动后的归属，以及 Safari URL 包装的精确转换和拒绝条件。
- Release 构建通过（13.19 秒）。应用、DMG、ZIP 内应用通过严格签名和版本核验；DMG 校验并以只读方式挂载检查，ZIP 解包核对。最低 macOS 26.0，arm64，仍是未公证 ad-hoc 签名试用构建。
- 日志：`.build/context-routing-tests.log`、`.build/context-routing-release.log`、`.build/context-routing-package.log`。

| 资产 | 大小（字节） | SHA256 |
| --- | ---: | --- |
| Nous-Browser-1.0.9-macOS-arm64.dmg | 4,415,852 | `49775beb6d6b15eec7d46c53f9f3d6242a1967b809576d24222cd14b73b6a8ad` |
| Nous-Browser-1.0.9-macOS-arm64.zip | 4,393,347 | `f82b99f186d8f76cef0a64613233ba6603b072f8157ad131596917c1b973a266` |
| SHA256SUMS.txt | 202 | `16e13fa83a315339bee623b79eee47e2696f95d0f340c298774d9e39ef0e579e` |
