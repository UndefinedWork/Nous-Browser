# 1.1.2 Google Docs / Slides 浏览器识别验证记录

版本：1.1.2（Build 42），Apple Silicon，macOS 26.0+。本次实测系统为 macOS 26.7.2。

## 根因与修复

1.0.8 的兼容身份只覆盖 Google Search 和 Sheets。`docs.google.com/document` 与 `/presentation` 仍使用原生嵌入式 WebKit 身份，缺少 Google 编辑器期望的 Safari 版本标识；旧测试还将 Docs 明确列为原生身份页面。因此 1.1.1 中 Docs、Slides 出现浏览器版本不受支持提示，是此前兼容范围遗漏。

本次将策略命名和范围统一为 Google Editors：精确匹配 `docs.google.com` 的 `/document`、`/presentation`、`/spreadsheets` 及其子路径，以及官方 `slides.google.com`、`sheets.google.com` 入口。保留协议、主机、默认端口、凭据及路径边界校验。

- 保留 macOS 26.4 的系统能力门槛和已验证的 Safari 26.4 兼容标识，平台及 WebKit 字段继续来自系统自身的非持久化空白 WKWebView，保留 NousBrowser 标识。
- 保留 Sheets 已验证的 Retina 画布行为，不调整 DPR、页面缩放或渲染层。
- 新建标签、恢复标签、刷新、弹出页及跳转沿用同一主文档导航策略；离开兼容范围时恢复原生身份，异步身份探测的过期结果不能覆盖新导航。
- 未通过隐藏提示条或修改 Google 页面脚本来处理问题。Drive、Google 认证、Forms、其他网站的身份范围未扩大。
- macOS 26.0–26.3 继续沿用原有策略，本次未声称解决旧系统的编辑器提示。浏览器识别改善不代表穷尽 Google 编辑器全部功能的兼容性。

Google 的支持说明：[Docs 编辑器系统和浏览器要求](https://support.google.com/docs/answer/2375082?hl=en)。此前 Sheets 的画布诊断及编辑保存验证见 [1.0.8 QA](QA-1.0.8.md)。

## 自动化验证

- `swift test --filter BrowserUserAgentTests`：15 项通过，包含 Docs／Slides／Sheets 冷启动及取消的参数化场景。
- 真实 WKWebView 探测和 `navigator.userAgent` 读回确认：Docs、Slides 得到含 Safari 26.4 与 NousBrowser 的兼容身份，非 Google 页面恢复原生身份。
- 完整 `swift test`：应用 246 项／37 套件，MCP 共享层与 SDK 8 项／3 套件。合计 254 项，249 项通过、5 项原有密码事件循环场景按预期跳过，0 失败。
- 修复前在实际安装的 1.1.1 中复现：同一窗口的 Docs 和 Slides 均显示不受支持提示，Sheets 没有该提示；三个文件均显示已保存到 Drive。

## 安装版核验

- 正常退出旧应用并备份应用及会话后，安装到 `/Applications/Nous Browser.app`；安装版主程序和 MCP helper 与 Release 构建逐字节一致，版本为 1.1.2（42）。
- 在用户报告的原 Docs、Slides 页面核验，二者加载完成后均没有蓝色“不支持此浏览器版本”提示，显示已保存到 Drive；Docs 普通刷新、Slides 跳过缓存刷新后结果一致。
- 同窗口的 Sheets QA 文件正常加载、没有版本提示，100% 缩放下文字清晰。该文件中的既有测试值仍可见，本轮未重新执行编辑／保存测试。
- 本轮只操作浏览器标签、菜单和刷新，不写入文档内容。Google 的“Try Chrome”推广卡片与版本警告不同：截图先记录版本警告已消失，随后才用 No thanks 收起推广卡片。
- 两个窗口均恢复；本次验收窗口原有 5 个标签的 ID、顺序及 URL 保留。另一窗口在验收期间有标签变化，不以整个会话总数完全不变作为结论。
- Release 构建、应用及 helper 严格签名验证、DMG 校验及只读挂载、ZIP 解包与包内二进制比对均通过。仍为 ad-hoc 签名、未经 Apple 公证的开发预览包。

界面与日志证据保存在本机 `.build/workspace42-*.png`、`.build/workspace42-*.txt`、`.build/google-editors42-*.log`；包含用户文件的截图和地址不会提交到仓库或安装包。

| 资产 | 字节 | SHA256 |
| --- | ---: | --- |
| Nous-Browser-1.1.2-macOS-arm64.dmg | 5,932,427 | `5ae6055d740d65ba0d25fe967005bc9c492acd782ae4870a25eacc2a1ba147f1` |
| Nous-Browser-1.1.2-macOS-arm64.zip | 5,909,444 | `9b4c44b594e1108efbcd92714da2799ca8209ef20e5e7ba4bd27becfd6be8b34` |
