# Nous Core — Dia 式 Chromium 内核

Nous Browser 的网页内核不再是 CEF，而是仿照 Dia/Arc 的 ADK 路线：
把 Chromium 完整的 `//chrome` 层与我们自己的嵌入层 `//nous` 一起编译成一个
改名的 Chrome Framework —— **`NousCore.framework`**（Dia 对应
`ArcCore.framework`）。Swift 主程序直接链接它，`import NousCore` 使用其
Objective-C API。研究依据见 [Docs/Dia-Architecture-Research.md](../Docs/Dia-Architecture-Research.md)。

```
Nous Browser.app/Contents/
  MacOS/NousBrowser                Swift UI（AppKit + SwiftUI 视图），链接 NousCore
  Frameworks/NousCore.framework/   = //chrome + //nous（导出 ChromeMain、Nous*/NB* 类）
    Versions/156.0.8078.80/
      NousCore                     framework 二进制
      Helpers/Chromium Helper*.app Chrome 原生 helper（dlopen NousCore → ChromeMain）
      Resources/ Libraries/
    Headers/ Modules/              NousCore Clang module（Swift 可直接 import）
```

## 运行模型

| 阶段 | 谁负责 |
| --- | --- |
| `main()` | Swift `NousBrowserLauncher`：实例锁 → `NousBrowserApplication.run(with:)` |
| 进程主循环 | Chromium：`ChromeMain` → `BrowserMainLoop` → `[NSApp run]`（`BrowserCrApplication`） |
| 浏览器就绪 | `PostBrowserStart` 钩子 → `browserApplicationDidInitialize`：Swift 安装 `NSApp.delegate`、AppKit 主菜单、恢复窗口 |
| 标签页 | `NBChromiumView` 持有 `content::WebContents`（挂 Chrome 全套 TabHelpers），其原生 NSView 挂入 Swift 视图树 |
| ⌘Q | `-[BrowserCrApplication terminate:]` → Swift 确认 beforeunload/下载/会话 → `quit` → `chrome::AttemptExit()` |
| 退出 | `PostMainMessageLoopRun` 钩子 → `browserApplicationWillShutDown` → `ChromeMain` 返回 → `exit()` |

没有 CEF、没有外部 message pump、没有 `cef_nous_*` 动态符号探测。

## 目录

| 路径 | 内容 |
| --- | --- |
| `nous/public/` | 公开 ObjC API：`NousBrowserApplication`、`NBChromiumView`、`NBChromiumRuntime`、下载；`module.modulemap` |
| `nous/browser/nous_application.mm` | 运行 `ChromeMain`、keep-alive、终止路由、Memory Saver 站点偏好 |
| `nous/browser/nous_tab.mm` | `WebContentsDelegate`/`Observer`、进程内 DevTools（隔离 world、binding、截图）、JS 对话框、权限、tab-modal 宿主、查找、缩放、打印、全屏、两阶段关闭 |
| `nous/browser/nous_downloads.mm` | 继承 `ChromeDownloadManagerDelegate`：Chrome 判定危险类型/文件名，Nous 决定保存位置 |
| `nous/common/nous_embedder.*` | 无依赖钩子，供 `//chrome` 补丁调用 |
| `patches/apply_chromium_patches.py` | 对 `//chrome` 的全部改动（幂等、锚点失配即报错） |
| `args.gn` | GN 参数（`nous_core = true`、`enable_cef = false`） |

## 构建

```bash
Scripts/build-nouscore.sh        # Chromium 源码 → .build/nouscore/sdk/NousCore.framework
Scripts/build.sh                 # 引擎 + Swift + 打包 → build/Nous Browser.app
NOUS_SKIP_ENGINE_BUILD=1 Scripts/build.sh   # 只改 Swift 时跳过引擎
```

源码树默认为 `~/Library/Caches/NousCEF/156.0.8078.80-arm64-codecs/chromium/src`
（可用 `NOUS_CHROMIUM_SRC` 覆盖）。首次完整编译约数小时，之后只改 `//nous`
时为增量编译 + 重链 framework。

## 相对 CEF 的直接收益

- Chrome 原生右键菜单、密码管理器/自动填充 TabHelper、查找、缩放、favicon、
  安全浏览下载检查、HTTP 认证与外部协议对话框（tab-modal）都直接来自 `//chrome`。
- 下载由 `DownloadItem` 直接观察，标签关闭后进度仍持续上报（CEF 版只能报告失败）。
- 任何 Chromium 内部 API 都可在 `//nous` 中直接调用，不必给 CEF 加 C API 再 `dlsym`。

## 已知差距（下一阶段）

- 标签尚未接入 Chrome 的 `Browser`/`TabStripModel`（Dia 的 `ArcBrowser`）。因此
  Memory Saver 自动丢弃、扩展程序、标签组 API 暂不可用：`hasNativeTabLifecycle`
  返回 NO，`memorySaverMode` 返回 -1，Swift 端走既有降级路径。
- 网站数据使用 Chrome 默认的 “Chromium Safe Storage” 钥匙串项，而不是 CEF 版的
  按构建隔离存储；首次启动可能出现钥匙串授权提示。
- Helper 仍沿用 Chromium 品牌名（`Chromium Helper*.app`）；改为 Nous 品牌需要
  `BRANDING` 文件与图标资源。
- 当前构建复用了带 CEF 补丁的源码树（`enable_cef=false`）；`SetCreatePermissionPromptFunction`
  来自该补丁集。迁移到纯净 Chromium 树时需把这一钩子并入 `apply_chromium_patches.py`。
