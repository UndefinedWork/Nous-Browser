# 1.0.7 验证记录

版本：1.0.7（Build 36），Apple Silicon，macOS 26.0 及以上。

本轮修复 Google Sheets 页面模糊。原生 A/B 对照在同一公开示例表格、同一 WebKit 环境下，仅切换 User-Agent 身份；三个页面的 `devicePixelRatio` 均为 2，却获得不同的表格画布像素密度：

| User-Agent 身份 | 画布像素宽度 / CSS 显示宽度 | 实际密度 |
| --- | --- | --- |
| 原 Safari 兼容后缀 | 241 / 482 | 0.5 |
| 原生 WebKit + NousBrowser 标识 | 966 / 483 | 2 |
| 原生 WebKit | 964 / 482 | 2 |

该对照定位到原 Safari 兼容身份触发了 Sheets 的不同站点分流，使其选用过低的画布密度。现已默认使用原生 WebKit 身份并保留 NousBrowser 标识；仅为 `google.com` / `www.google.com` 的 `/`、`/webhp`、`/search` 保留兼容身份。系统与 WebKit 版本由独立空白、非持久化 WKWebView 通过公开 API 获取，不从网站脚本读取或硬编码。引擎仍是系统 WebKit，未修改渲染 layer。

原生身份下 Google 可能显示浏览器不受支持的提示；保留该提示，不注入样式或脚本隐藏。上述对照确认了公开示例的画布密度差异，不将其扩展为对所有 Google 功能的兼容承诺。

- 原生 A/B 根因定位已完成，使用 [Google 官方示例表格](https://developers.google.com/workspace/sheets/api/quickstart/apps-script)。尺寸数据和对照截图留在本机 `.build/sheets-render-diagnostic/`。
- 完整测试 200 项、31 个套件：195 项通过、5 项原生密码填写事件循环场景预期跳过、0 失败，耗时 20.825 秒。10 项身份策略测试覆盖精确 URL 边界、继承弹窗配置、缓存、原生回退及异步旧结果取消。首次运行发现路径尾斜杠与 Cocoa 空字符串规范化问题，已修正并重跑完整测试。
- 隔离的真实 Nous 窗口已验证示例表格文字清晰；Google 首页仍显示新版搜索框、语音和图片搜索，搜索提交正常；同一标签页从 Search 进入 Sheets，再后退、前进和刷新，表格保持清晰。公开表格为只读，未据此宣称验证编辑及所有 Google 功能。
- 主框架导航和主文档响应共用身份策略；重定向离开搜索时恢复原生身份，iframe 不修改整页身份。未对所有服务器重定向逐跳抓包，因此不宣称每一跳的网络请求头都已实测。
- Debug、Release 构建通过；Release 编译 15.14 秒。应用与 DMG、ZIP 内应用通过严格签名验证，实际架构为 arm64、最低 macOS 26.0，仍为未公证 ad-hoc 签名。
- 已正常退出两个旧运行实例，并安装、启动 `/Applications/Nous Browser.app` 1.0.7（Build 36）；主程序与 Release 构建一致。升级保留当前 2 个窗口（18、1 个标签）的窗口清单、标签 ID、顺序、置顶和选中标签；原侧栏显示状态已恢复。退出前后快照只保留在本机 `.build/`，未发布用户浏览记录。

| 资产 | 大小 | SHA256 |
| --- | ---: | --- |
| `Nous-Browser-1.0.7-macOS-arm64.dmg` | 4,404,093 字节 | `2e4c89174d3068650a05d2337b5938a2d35a44a739d01719a486bd20e5ac3dc1` |
| `Nous-Browser-1.0.7-macOS-arm64.zip` | 4,380,048 字节 | `8966a6d85caa02dc2ee403a7bcd1f1df7583bf539b6b9b8b8511dc5842687121` |
| `SHA256SUMS.txt` | 202 字节 | `64f1356f30ca2cbe097b6c8dbeccd490332e70b20e2bd5a58f5d75d24fffb428` |

日志：`.build/sheets-identity-tests.log`、`.build/sheets-identity-release.log`、`.build/sheets-identity-package.log`。
