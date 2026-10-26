# 1.0.10 菜单栏检查记录

版本：1.0.10（Build 39），Apple Silicon，macOS 26.0 及以上。实测系统为 macOS 26.7.2。

## 发现和修复

- Window 菜单原先同时存在系统 Minimize / Zoom 与额外的 Minimize Window / Zoom Window，且重复设置 ⌘M。删除额外命令，使用系统窗口菜单与当前窗口的响应链。
- 空白标签原先仍启用 Reload；没有加载任务时仍启用 Stop Loading。现在分别按页面内容与实际加载状态控制。
- 原生 Help 入口原先只显示“Help isn’t available”。替换为 Nous 内的快捷键说明窗口，不启动系统浏览器；新增标题覆盖现有 11 种界面语言，其余动作名复用现有翻译。
- 顶部 Services 的通用 Open 来自 Finder，其服务声明接受网址、文字及文件名，可以绕过 Nous 交给系统处理。现在与系统网页搜索、Open URL、Safari 阅读列表一同移除。只过滤 Services 内的通用打开，普通 File 菜单不受影响；Finder 显示文件、词典等服务保留。
- 服务过滤器初始化时也清理已经存在的应用菜单和 Services 菜单，后续继续处理系统动态追加的项。

## 界面验收

检查了应用菜单、File、Edit、View、Navigate、Passwords、Window 和 Help；以独立调试会话验证交互，再检查最终安装的正式构建。

| 场景 | 实测结果 |
| --- | --- |
| 顶部 Services：网页文字选区 | 系统网页搜索、Open URL、Safari 阅读列表入口未出现 |
| 顶部 Services：地址框选中网址 | 最终调试版及安装版均无通用 Open、网页搜索、Open URL、Safari 阅读列表；其他服务仍在 |
| Window 菜单 | 调试版、安装版均只保留原生窗口命令；窗口列表显示选中标签标题 |
| 新标签、新窗口及窗口切换 | 新标签留在当前窗口；新窗口独立创建；Window 菜单正确切换目标窗口 |
| ⌘W | 先关闭选中标签；最后一个标签关闭时仅关闭所在窗口，另一窗口保留 |
| 页面查找、侧边栏 | Edit 的查找打开页内查找框，View 的侧边栏动作改变侧边栏状态 |
| 空白标签 | Navigate 的 Reload、Reload Without Cache、Stop Loading 均禁用 |
| 已加载页面 | 两种刷新可用，Stop Loading 禁用；菜单强制刷新仍在原 Nous 窗口内完成 |
| Settings、快捷键帮助激活 | 网页导航命令禁用，⌘W 关闭当前辅助窗口，不关闭后台标签 |
| Help | 调试版与安装版都打开可滚动的本地快捷键说明，关闭后回到原页面 |

Safari 应用进程没有启动。本轮没有调用真实账户的密码填写、分享、系统反馈或第三方 Services；不将这些动作列为已验证。所有浏览窗口关闭后，界面工具不能获取无窗口菜单，因此该状态依赖现有窗口管理自动化覆盖，未宣称完成无窗口菜单的全部实机验证。

## 安装和验证

- 完整 `swift test`：213 项、33 套件，208 项通过、5 项原生密码事件循环场景按预期跳过，0 失败，15.057 秒。新增测试覆盖顶层应用菜单内嵌 Services 的本地化 Open 过滤，以及普通 File 打开命令不受影响。
- Release 构建与应用严格签名校验通过。DMG 校验、只读挂载及 ZIP 解包后的版本、签名和二进制核对通过。仍为 ad-hoc 签名、未经公证的开发预览包。
- 已正常退出旧应用、备份当前会话并安装 `/Applications/Nous Browser.app`。安装版二进制与发布包一致；安装前现有 1 个窗口、18 个标签的 ID、顺序和选中项全部保留，测试辅助窗口已关闭。
- 本机日志及截图保存在 `.build/menubar-*`，不包含在发布包或源码提交中。

| 资产 | 字节 | SHA256 |
| --- | ---: | --- |
| Nous-Browser-1.0.10-macOS-arm64.dmg | 4,423,233 | `aa33fee215b8ce57500295bfac6138406aa469bd526bc1de8efbf2c3529e653b` |
| Nous-Browser-1.0.10-macOS-arm64.zip | 4,400,935 | `d9207929d84b1fc5aea303a89384b3d22f03311e8b5496e26eaf4b9dc72a18fb` |
