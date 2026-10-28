# 1.1.10（50）地址浮层关闭回归

- 修复：关闭当前标签后同步关闭地址浮层，并将焦点交还剩余标签网页。
- 自动测试：BrowserWindowManagerTests 共 14 项通过，包括新增标签关闭后浮层消失、再次新建正常显示、最后一个标签关闭对应窗口且保留其他窗口。
- 独立调试应用实测：⌘T → ⌘W，以及点击加号 → ⌘W，两条路径均返回原网页且输入浮层消失。测试应用使用独立 bundle ID 和会话，已退出。
- 发布构建输出到 `.build/release50/Nous Browser.app`，未覆盖用户正在运行的 `build/Nous Browser.app`（1.1.9），也未替换 `/Applications` 中的应用。
- DMG、ZIP、SHA256SUMS.txt、签名 appcast.xml 由打包脚本生成；沿用 1.1.9 更新签名公钥。用户自行验收从 1.1.9 更新至 1.1.10 的流程。
