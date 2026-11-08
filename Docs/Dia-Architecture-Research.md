# Dia 技术路线研究（2026-11-07）

研究对象：官方 `Dia-latest.dmg`（Dia 1.56.0 build 90312，来源
`releases.diabrowser.com`），仅做静态分析：Bundle 结构、Info.plist、
`otool -L`、`nm` 导出符号、`strings`，以及 framework 自带的公开头文件。
未安装、未运行。公开资料部分来自 The Browser Company 官方信件与 Dia 安全页。

## 一句话结论

Dia **不是 CEF**，也不是 WKWebView。它把 Chromium 的完整 `//chrome` 层
（不只是 `//content`）连同自研的 ADK（Arc Development Kit，源码目录
`//arc`）一起编译成一个改名的 Chrome Framework —— `ArcCore.framework`。
Swift（AppKit + SwiftUI）主程序直接链接这个 framework，通过 ADK 暴露的
Objective-C API（Clang module，Swift 直接 `import ArcCore`）驱动 Chromium。

## 证据

### 1. Bundle 结构

```
Dia.app/Contents/
  MacOS/Dia                       137 MB  Swift 主程序（AppKit/SwiftUI UI 全在这里）
  Frameworks/
    ArcCore.framework             338 MB  = 改名的 Chrome Framework + ADK
      Versions/A/ArcCore          242 MB  导出 ChromeMain / ChromeAppModeStart_v8
      Versions/A/Headers/         205 个 ObjC 头文件（arc/browser/objcpp/*）
      Versions/A/Modules/module.modulemap   framework module ArcCore
      Versions/A/Helpers/
        Browser Helper.app / (GPU) / (Renderer) / (Alerts)
        Browser Helper (Aperitif*).app      Chrome 的备用 helper 变体
        app_mode_loader                     Chrome PWA shim
      Versions/A/Libraries/       libvk_swiftshader、libaperitif 等
      Versions/A/Resources/       chrome_100_percent.pak、*.lproj、ArcCore.sig…
    Sparkle / GRDB / Lottie / Sentry / libAIInfra / libContentConversion
```

- `ArcCore.framework/Resources/Info.plist`：`CFBundleShortVersionString =
  157.0.8103.39`，`SCMRevision = …refs/branch-heads/8103@{#1035}` —— 即 Chrome
  157 稳定分支。Dia 安全页称每周四跟随最新稳定 Chromium 发版、关键安全修复
  48 小时内上线。
- `ArcCore.sig` 出现在 Resources —— 对应 `chrome/BUILD.gn` 中
  `$chrome_framework_name.sig`，说明他们是用 Chrome 自己的 GN 打包规则，只把
  `chrome_framework_name` 改成了 `ArcCore`。
- Helper 可执行文件只有 88 KB，字符串中只有 `../../../../ArcCore` 与
  `ChromeMain`：就是 Chrome 原生的 helper stub（dlopen framework 后调用
  `ChromeMain`），沙箱与多进程模型完全沿用 Chrome。
- 主程序 `otool -L`：直接链接
  `@executable_path/../Frameworks/ArcCore.framework/Versions/A/ArcCore`
  （而 Chrome 自己的主程序是 dlopen）。

### 2. ADK API 形态（来自公开头文件）

核心对象层次与 Chrome 内部概念一一对应：

| ADK（ObjC，Swift 可见） | Chromium 内部 |
| --- | --- |
| `ArcBrowserApplication`：`init(delegate)` → `initialize(config)` → `run` → `tryToTerminate(completion:)` | `ChromeMain` / `BrowserMainLoop` / `BrowserProcess` |
| `ArcBrowserApplicationConfiguration(argc, argv, profilePath, …, quitRunLoopOnTermination)` | 命令行 + user-data-dir |
| `ArcBrowserContext`（创建/加载/删除，Regular/Incognito） | `Profile` |
| `ArcBrowser`：`createBrowser(context, delegate, forWindow: windowId)`、`setWindow(NSWindow)`、`createWebContents(config)`、`tryToClose(skipBeforeUnloadHandlers:)`、`takeOwnershipOfWebContents` | `Browser` + `TabStripModel`（扩展、tab group 依赖它） |
| `ArcWebContents`：导航、find、zoom、capture、print、executeJavascript、discard、freezing vote、mediaSession、devTools、PDF… | `content::WebContents` + chrome TabHelpers |
| `ArcWebContentsUIDelegate`：JS 对话框、beforeunload、权限请求、全屏、上下文菜单、凭据保存、hung renderer、process gone… | `WebContentsDelegate` / 各种 chrome 对话框工厂 |
| `ArcWebContentsNavigationDelegate` 等 | `WebContentsObserver` |

关键实现细节（头文件注释可见）：

1. **API 由 mojom IDL 代码生成**：`ArcWebContents.h` 由
   `bindings/web_contents.mojom` 自动生成，`*.mojom-objc.h` 也是生成物；
   生成器无法表达的签名放在手写 category（`ArcWebContentsExtensions.h`）。
2. **状态以 KVO 推送**：`WebContentsObserver` 把 title/url/themeColor/
   zoomLevel 等写入 ObjC 属性，触发 KVO，Swift 侧用 Combine 订阅。
3. **视图采用 pane host 模式**：`createPaneHostView` /
   `attachToPaneHostView:` / `detachFromPaneHostView:` / `nativeView`。
   Swift UI 持有宿主 NSView，WebContents 的原生 NSView 挂入/摘出，从而在
   窗口、分屏、侧栏之间移动标签不需要重建页面。
4. **主线程/run loop 归 Chromium**：Swift 的 NSApplication 子类实现
   Chromium 的 `CrAppProtocol` / `CrAppControlProtocol`
   （`isHandlingSendEvent`，主程序字符串中可见）；`ArcBrowserApplication.run`
   进入 Chromium 的 `BrowserMainLoop`（其底层就是 `[NSApp run]`），
   AppKit/SwiftUI 事件照常在这个 run loop 中分发。
5. 所有 ADK 类型标注 `NS_SWIFT_UI_ACTOR`，即全部主线程 API。

### 3. 与 CEF 的本质区别

| | CEF（Nous 1.2.0 现状） | Dia / ADK |
| --- | --- | --- |
| Chromium 层次 | CEF Alloy/Chrome runtime 包一层 C API，再由 C++ wrapper 封装 | 直接使用 `//chrome` 与 `//content` C++ 类 |
| 能力扩展 | 需要给 CEF 打补丁再导出 `cef_nous_*` C 符号，`dlsym` 动态探测 | 直接在 `//nous` 里写 ObjC++，调用任意 Chromium 内部 API |
| Framework | `Chromium Embedded Framework.framework` | 改名的 Chrome Framework（`ArcCore`），Chrome 原生 helper |
| run loop | 外部 message pump（`CefDoMessageLoopWork` 调度器） | Chromium 自己的 `MessagePumpNSApplication` |
| 版本跟进 | 等 CEF 发布分支 | 直接跟 Chrome 稳定分支 |

## 公开资料

- [Letter to Arc members 2025](https://browsercompany.substack.com/p/letter-to-arc-members-2025)：
  "Arc isn't just a Chromium fork. It runs on custom infrastructure we call ADK"，
  ADK 同时是 Dia 的基础。
- [Dia Security](https://www.diabrowser.com/security)：每周跟随最新稳定 Chromium。
