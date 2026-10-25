# Nous Browser

给网页多一点空间。

Nous Browser 是一款轻量、简洁的原生 macOS 浏览器，使用 SwiftUI、WebKit、SF Symbols 和系统 Liquid Glass。把标签页放在可收起的侧边栏里，保留熟悉的网页浏览方式。

[下载开发预览版](https://github.com/UndefinedWork/Nous-Browser/releases) · [查看所有 Release](https://github.com/UndefinedWork/Nous-Browser/releases)

## 功能

- **简洁的侧边栏**：完整展开或收起；拖动右边缘调整宽度，双击恢复默认宽度，布局会自动保存。
- **标签页管理**：获取网站 favicon，支持复制、置顶、拖拽排序和恢复最近关闭的标签页。拖动到列表边缘可自动滚动，按 Esc 取消拖动。
- **多窗口**：新建窗口与新建标签页分开操作，每个窗口分别管理自己的标签页。
- **原生外观**：Liquid Glass、Spring 弹性过渡和 SF Symbols；侧边栏与网页隐藏滚动条，仍可正常滚动。
- **保留浏览状态**：恢复标签页、顺序和侧边栏状态；通过 WebKit 持久化网站数据保留网站自身的登录会话。
- **密码导入与填写**：手动导入 Apple「密码」或 Chrome 导出的 CSV，经设备验证后填写支持的 HTTPS 登录表单。
- **跟随系统**：界面语言和外观默认跟随 macOS，支持浅色、深色以及 11 种界面语言。
- **常用网页能力**：前进、后退、下载、网页全屏、本机 HTML/XHTML 文件和用户主动打开的新标签页；拦截脚本自动弹出的窗口。

## 系统要求

- **macOS 26 或更新版本**。
- 当前首个预编译包为 **Apple Silicon** 版本；Intel Mac 可在满足系统与开发环境要求时从源码构建。
- 从源码构建需要 **Xcode 26 或更新版本、Swift 6.2 或更新版本**。

当前源码版本：**1.0.0（Build 23）**。预编译安装包的构建号见对应 Release。

## 下载与安装

1. 前往 [GitHub Release](https://github.com/UndefinedWork/Nous-Browser/releases)，下载 `.dmg` 安装包。
2. 打开 DMG，将 **Nous Browser.app** 拖入 **Applications／应用程序** 文件夹。
3. 从“应用程序”打开 Nous Browser，然后推出磁盘映像。

当前发布使用 **ad-hoc 临时签名，尚未经过 Apple 公证**。首次打开时，macOS 可能要求额外确认；确认安装包来自本仓库 Release 后，可在“系统设置 → 隐私与安全性”中查看打开选项。无需关闭系统的安全检查。

### 设为默认浏览器

先将应用安装到“应用程序”并打开一次，再前往 **系统设置 → 桌面与程序坞 → 默认网页浏览器**，选择 **Nous Browser**。之后从其他应用打开的网页链接会交给 Nous Browser。

### 外观与语言

在 **显示 → 外观** 中选择“跟随系统”“浅色”或“深色”。默认跟随系统；手动选择会自动保存，切换外观不会重新加载网页。网站可通过标准的 `prefers-color-scheme` 响应外观，是否提供深色页面由网站决定。

界面、菜单、提示和权限说明支持英语、简体中文、繁体中文、日语、韩语、德语、法语、西班牙语、巴西葡萄牙语、意大利语和俄语。默认使用系统语言，也可在 macOS 中为应用单独指定语言；不支持的语言回退到英语。

### 窗口与标签页

当前源码中，**⌘N** 新建浏览器窗口，**⌘T** 在当前窗口新建标签页，**⌘⇧W** 关闭当前窗口。新建标签页直接显示，不播放展开动画；其他 Spring 过渡缩短时长，让侧边栏、标签切换和浮层响应更快。预编译安装包包含哪些改动，请以对应 Release 说明为准。

## 快捷键

| 快捷键 | 功能 |
| --- | --- |
| ⌘ / | 展开或完全收起侧边栏 |
| ⌘ L | 打开或关闭网址／搜索输入框 |
| ⌘ N | 新建窗口 |
| ⌘ T | 在当前窗口新建标签页 |
| ⌘ W | 关闭当前标签页 |
| ⌘ ⇧ W | 关闭当前窗口 |
| ⌘ ⇧ T | 重新打开最近关闭的标签页 |
| ⌘ ⇧ ] / ⌘ ⇧ [ | 下一个／上一个标签页 |
| 后退：⌘ ← 或 ⌘ [；前进：⌘ → 或 ⌘ ] | 后退／前进；在地址框和网页编辑区中，⌘←／⌘→ 仍用于文本移动 |
| ⌘ R | 重新加载网页 |
| ⌘ . | 停止加载 |
| ⌘ ⇧ C | 复制当前网址 |
| ⌘ ⇧ P | 验证并填写当前网站保存的密码 |

## 登录状态与密码

### 保留网站登录状态

Cookie、Local Storage 等网站数据由 WebKit 的持久化存储管理。正常退出并重新打开应用后，网站可继续使用已有会话；有效期和是否需要重新登录由网站决定。Nous Browser 不会直接继承 Safari、Chrome 或其他浏览器的登录状态。

### 从 Apple「密码」或 Chrome 导入

1. 在 Apple「密码」或 Chrome 密码管理器中，使用其导出功能生成密码 CSV。
2. 在 Nous Browser 中选择 **密码 → 导入密码…**，再选择该 CSV 文件。
3. 按 macOS 提示使用 **Mac 登录密码或 Touch ID** 完成设备验证。
4. 查看导入结果，然后将导出的 CSV 移到废纸篓。CSV 内含可直接读取的明文密码，请妥善处理。

打开支持的 HTTPS 登录页面后，点击“填写密码”或按 **⌘⇧P**。完成设备验证后，选择要使用的账号；只有一个匹配账号时会直接填写。应用不会自动提交登录表单。

填写严格匹配密码条目的**协议、主机和端口**，并检查当前标签页与表单是否仍然有效。跨域 iframe、隐藏字段和更改密码表单不在支持范围内；部分网站可能限制嵌入式浏览器登录或要求额外验证。

### 存储与限制

- 导入的密码库保存在**本机登录钥匙串**。应用在每次导入或读取密码前执行新的设备验证；未完成验证时不继续读取或写入密码库。
- 密码不会写入标签页文件、日志或剪贴板。解锁后的账号列表会在关闭、切换到后台、页面变化或超时后清除。
- CSV 导入是用户主动进行的迁移；此版本没有直接读取 Safari／Chrome 内部密码库或 iCloud Passwords、同步其他设备密码、迁移登录 Cookie、通行密钥或验证码的功能。
- 当前 ad-hoc 签名没有稳定的开发者签名身份。**首次使用钥匙串或升级应用后，macOS 可能另外要求钥匙串访问许可**，该提示与每次填写前的设备验证不同。
- 当前实现使用登录钥匙串及应用执行的设备验证；不宣称使用数据保护钥匙串的 `userPresence` 访问控制。后续正式签名发布仍需处理升级时的钥匙串信任。

## 本地数据

| 数据 | 位置 |
| --- | --- |
| 标签页、排序和侧边栏状态 | `~/Library/Application Support/Nous Browser/session.json` |
| 多窗口清单与当前窗口 | `~/Library/Application Support/Nous Browser/session.windows.json` |
| 其他窗口的标签页和布局 | `~/Library/Application Support/Nous Browser/session-windows/` |
| 网站图标缓存 | `~/Library/Caches/Nous Browser/Favicons/` |
| 外观等应用偏好 | macOS `UserDefaults`，应用标识为 `com.cellier.nous-browser` |
| 导入的密码库 | 本机登录钥匙串，服务名为 `com.nous.browser.password-vault` |
| Cookie、网站本地存储等 | 由 WebKit 的持久化网站数据存储管理 |

删除应用文件不会自动清除以上数据。

## 从源码构建

安装 Xcode 并完成首次启动配置，在仓库根目录运行：

```sh
zsh Scripts/build.sh
open "build/Nous Browser.app"
```

脚本默认构建当前 Mac 架构的 Release 版本，生成 `build/Nous Browser.app` 并添加 ad-hoc 签名。也可使用 Xcode 打开 `Package.swift` 查看和修改代码。

## 测试

```sh
swift test
zsh Scripts/run-password-autofill-tests.sh
```

`swift test` 运行自动化测试。部分需要可见网页和完整应用事件循环的填写场景会在命令行环境中跳过；第二个脚本使用独立的原生测试窗口补充这些场景，需要当前 Mac 的图形桌面会话。

密码测试使用虚构账号、测试存储和模拟设备验证，不读取真实浏览器密码或真实钥匙串数据。自动检查不能替代真人确认 Touch ID／Mac 登录密码验证、首次钥匙串许可、真实网站兼容性及升级后的行为。

需要手动检查导航、下载和登录状态保留时，可启动本机测试页面：

```sh
python3 Tests/Fixtures/browser_test_server.py
```

在应用中访问 `http://127.0.0.1:8765/`，使用页面提供的虚构账号登录、保存测试备注，然后正常退出并重新打开应用，检查会话和备注是否保留。`/browser-profile` 提供浏览器身份检查，`/web-compatibility` 提供网页全屏与弹窗行为检查。

## 打包安装文件

完成 Release 构建后运行：

```sh
zsh Scripts/package-release.sh
```

安装镜像、ZIP 和 SHA256 校验文件生成在 `dist/`。脚本会核对版本、实际 CPU 架构和应用签名，并验证 DMG 与 ZIP 的内容。
