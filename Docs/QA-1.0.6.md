# 1.0.6 验证记录

版本：1.0.6（Build 35），Apple Silicon，macOS 26.0 及以上。

- 按 [Figma 373:417](https://www.figma.com/design/ecisQPouXoxDJd9ZjOVLjH/Pico?node-id=373-417) 更新选中标签：胶囊内描边为 0.5 pt、黑色 8% 透明度；深色模式使用白色 8%。描边不接收点击，不进入辅助功能树。
- 窗口根背景使用 90% 的 backing fill，浅色底色为 `#FAFAFA`，深色使用对应底色；调整的是背景填充透明度，不是 `NSWindow.alphaValue`。
- 侧边栏外边距为 12 pt，顶部按钮 36 pt，列表起点 60 pt；底部按钮 32 pt、间距 8 pt，列表底部保留 56 pt。标签行高仍为 36 pt、行间距 1 pt。
- 拖动排序、跨窗口目标插槽和落位共用几何 helper。新增 5 项测试覆盖 Figma 行框、不同侧栏宽度、整数与分数滚动偏移、插槽切换阈值、按钮禁区及非有限坐标拒绝，避免布局调整后偏移一行。
- 完整测试正式结束：192 项、31 个测试套件，187 项通过、5 项需要真实 AppKit 事件循环的填写场景预期跳过、0 失败，耗时 19.389 秒。本轮未重复运行独立原生密码填写测试。
- Debug 与 Release 构建通过，Release 编译耗时 11.81 秒。

原生界面已验证浅色与深色的选中描边、底色和控件尺寸，以及 Control-Tab 切换选中标签、列表内排序和前进、后退。另已实测将 Alpha 标签拖出成为独立窗口，再拖回原窗口列表第 3 个位置：单标签来源窗口关闭，目标顺序为 Beta、Gamma、Alpha，选中 Alpha；未提交输入 `Layout draft retained` 与可用的前进状态均保留。这次确认的是该回移方向，不将其描述为双方向均已实测。

Release 应用以及 DMG 内、ZIP 解压后的应用均通过 `codesign --verify --deep --strict`。实际架构为 `arm64`，版本与最低系统要求均与源配置一致。仍为未公证的 ad-hoc 签名，没有 Developer ID 或 Team Identifier。

DMG 已只读挂载核对，内容仅包含 `Nous Browser.app` 和指向 `/Applications` 的快捷方式，校验完成后已卸载。ZIP 内容与应用包一致；`SHA256SUMS.txt` 的两项校验均为 OK。

| 资产 | 大小 | SHA256 |
| --- | ---: | --- |
| `dist/Nous-Browser-1.0.6-macOS-arm64.dmg` | 4,422,901 字节 | `9518fc401b73b1de9a7de769715bbca88b73257a233cdc44de8b246354dc79b7` |
| `dist/Nous-Browser-1.0.6-macOS-arm64.zip` | 4,371,468 字节 | `408bdd1f4c8dcfa444e4f1db5ea55abbb44fa81c8275200a70c9cee14af59d4a` |
| `dist/SHA256SUMS.txt` | 202 字节 | `78d93fd170636c885dae624f1f5a1b1bb3e7f155f516929510437988b67934cd` |

验证日志：`.build/sidebar-layout-tests.log`、`.build/sidebar-layout-release.log`、`.build/sidebar-layout-package.log`。

已正常退出旧版并安装至 `/Applications/Nous Browser.app`，启动的是该路径下的 1.0.6（Build 35）。安装应用通过严格签名验证，主程序与 Release 构建逐字节一致。升级前后窗口清单一致；2 个窗口（分别 18、1 个标签）的标签 ID、顺序、置顶状态、选中标签和侧边栏布局均保留。备份保存在本机 `.build/`，未加入源码或发布资产。
