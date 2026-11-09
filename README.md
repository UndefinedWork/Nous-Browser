# Nous Browser

给网页多一点空间。

Nous Browser 是一款轻量、简洁的原生 macOS 浏览器，使用 SwiftUI、Liquid Glass、SF Symbols 与 Chromium。内核 NousCore 参照 Dia/Arc 的路线，把 Chromium 的 `//chrome` 层与自研嵌入层 `//nous` 编译成 `NousCore.framework` 直接嵌入。

[下载开发预览版](https://github.com/UndefinedWork/Nous-Browser/releases) · [查看所有 Release](https://github.com/UndefinedWork/Nous-Browser/releases)

## 功能

- **空间（Spaces）**：每个空间有独立的固定项、分组和标签页。在侧边栏左右双指滑动或点底部圆点切换（⌥⌘← / ⌥⌘→）；右键圆点可改名、换图标或删除。
- **固定（Pin）**：固定的网页以图标方块显示，关闭所有窗口后依然保留，并在各窗口间共享。关闭固定页只会卸载它，图标仍在原处。
- **分组（Groups）**：右键新建，拖入／拖出标签，拖动排序；可改名、换图标（SF Symbol 或 emoji）、整体固定。收起时仍显示当前所在的标签；拖着标签停在收起的分组上会自动展开。
- **三合一导航**：后退、前进、刷新合并为一个玻璃控件；竖条状态下纵向排列。
- **资料库（⇧⌘L）**：书签、截图、录屏、历史记录、下载进度与结果、应用更新集中在一处，默认通过 iCloud 云盘同步。
- **书签（⌘D）**：书签在资料库中查看与管理；地址栏推荐和历史记录中带星标。
- **截图（⌥⇧⌘S）**：选取区域后在新标签中打开编辑器：背景、边距、圆角、阴影、比例，以及箭头、形状、文字、序号、马赛克、裁剪等标注。
- **录屏（⌥⇧⌘R）**：录制时遮罩非录制区域；结束后打开编辑器：自动跟随点击缩放、平滑光标、点击效果、剪辑与导出。
- **自定义快捷键**：在 **设置 → 截图与录屏** 修改截图、录屏与网页截取的快捷键；截图与录屏快捷键在任何应用中都可用。
- **三种侧边栏状态**：展开、60 pt 图标竖条、完全隐藏（⌘/、⌘.）。
- **多窗口与标签拖放**：标签可拖出成为新窗口，或拖入其他窗口的指定位置，页面状态不丢失。
- **登录状态与密码**：更新版本后网站登录和保存的密码继续保留，不弹出钥匙串密码框；可导入 Apple「密码」或 Chrome 导出的 CSV。
- **跟随系统**：外观与 11 种界面语言默认跟随 macOS。
- **AI 助手连接**：通过标准 MCP stdio 接口让本机 AI agent 查看与操作网页，默认关闭。

## 连接 AI agent（MCP）

在 **设置 → AI Agents (MCP)／AI 助手（MCP）** 开启访问，复制连接配置，添加到支持 **MCP stdio** 的本机 AI 客户端。只连接你信任的客户端：agent 可以读取和操作包括已登录网站在内的网页。功能默认关闭，可随时在设置中停止。

安装包内置连接程序，无需额外安装 Node.js 或 Python。此版本面向本机客户端，不提供公网 HTTP 接口。具体配置、能力与限制见 [MCP 使用说明](Docs/MCP.md)。

## 系统要求

- **macOS 26 或更新版本**。
- 当前发布包与受支持构建目标为 **Apple Silicon（arm64）**，没有 Intel 发行包。
- 宿主需要 **Swift 6.2+** 及匹配 SDK；从头构建 NousCore 需要本机 Chromium 源码树与 depot_tools，具体要求见 [Chromium 构建说明](Docs/Chromium-Build.md)。

当前源码版本：**1.4.14（Build 70）**。预编译安装包的构建号见对应 Release。

## 下载与安装

1. 前往 [GitHub Release](https://github.com/UndefinedWork/Nous-Browser/releases)，下载 `.dmg` 安装包。
2. 打开 DMG，将 **Nous Browser.app** 拖入 **Applications／应用程序** 文件夹。
3. 从“应用程序”打开 Nous Browser，然后推出磁盘映像。

当前发布使用 **ad-hoc 临时签名，尚未经过 Apple 公证**。首次打开时，macOS 可能要求额外确认；确认安装包来自本仓库 Release 后，可在“系统设置 → 隐私与安全性”中查看打开选项。无需关闭系统的安全检查。

### 设为默认浏览器

先将应用安装到“应用程序”并打开一次，再前往 **系统设置 → 桌面与程序坞 → 默认网页浏览器**，选择 **Nous Browser**。之后从其他应用打开的网页链接会交给 Nous Browser。

### 外观与语言

按 **⌘,** 打开设置，在 **外观** 中选择“跟随系统”“浅色”或“深色”。默认跟随系统；手动选择会自动保存，切换外观不会重新加载网页。网站可通过标准的 `prefers-color-scheme` 响应外观，是否提供深色页面由网站决定。

界面、菜单、提示和权限说明支持英语、简体中文、繁体中文、日语、韩语、德语、法语、西班牙语、巴西葡萄牙语、意大利语和俄语。默认使用系统语言，也可在 macOS 中为应用单独指定语言；不支持的语言回退到英语。

### 窗口与标签页

当前源码中，**⌘N** 新建浏览器窗口，**⌘T** 在当前窗口新建标签页，**⌘W** 关闭当前标签页，关闭最后一个标签页时关闭所在窗口；**⌘⇧W** 直接关闭当前窗口。关闭所有窗口后，应用仍可通过 ⌘T 或 ⌘N 新建窗口。新建标签页直接显示，不播放展开动画；其他 Spring 过渡缩短时长，让侧边栏、标签切换和浮层响应更快。预编译安装包包含哪些改动，请以对应 Release 说明为准。

网页链接的右键菜单提供 **Open in New Tab** 和 **Open Link in New Window**：前者在来源标签下面打开，后者建立独立窗口。来源标签已置顶时，新标签会放在置顶分组之后。按住 ⌘ 点击链接也会在来源标签下面打开新标签。

拖出标签页时移动现有页面，保留当前输入、滚动位置和前后退记录；原窗口没有剩余标签时会关闭。拖动中的标签以独立浮层连续跟随鼠标，跨过窗口边缘时不会被裁切；拖入另一窗口的列表会预留插入位置，并用弹性动画落位。拖到同一窗口的网页区域会取消移动。网页元素正在全屏显示时，需要先退出网页全屏再拖出。

点击侧边栏顶部按钮或按 **⌘/**，在展开列表与图标竖条之间切换。竖条中的标签只显示 favicon，仍可点击、拖拽排序、拖出及跨窗口移动；复制链接、复制标签、置顶和关闭等操作可通过右键菜单使用。鼠标停留在图标上 **300 ms** 后显示液态玻璃标题提示。

**⌘.** 单独控制完全隐藏侧边栏，再按一次恢复隐藏前的状态。例如先用 ⌘/ 收窄为竖条，再用 ⌘. 隐藏，下一次 ⌘. 会恢复竖条；完全隐藏时按 ⌘/ 则直接展开。展开宽度会保留，切换状态采用 Spring 过渡，并遵循系统“减少动态效果”设置。顶部 **View／视图** 菜单提供两项独立操作。

## 快捷键

可从 **Help → Keyboard Shortcuts** 打开应用内的快捷键说明，文案跟随系统语言。

| 快捷键 | 功能 |
| --- | --- |
| ⌘ / | 在展开侧边栏与图标竖条之间切换；完全隐藏时展开侧边栏 |
| ⌘ . | 完全隐藏侧边栏；再按一次恢复隐藏前的展开或图标竖条状态 |
| ⌘ L | 打开或关闭网址／搜索输入框 |
| ⌘ , | 打开设置 |
| ⌘ N | 新建窗口 |
| ⌘ T | 在当前窗口新建标签页 |
| ⌘ W | 关闭当前标签页；最后一个标签页关闭时关闭所在窗口 |
| ⌘ ⇧ W | 关闭当前窗口 |
| ⌘ ⇧ T | 重新打开最近关闭的标签页 |
| ⌘ ⇧ ] / ⌘ ⇧ [，或 Control Tab / Control ⇧ Tab，或 ⌘ ⌥ → / ⌘ ⌥ ← | 下一个／上一个标签页 |
| ⌘ 1–8 / ⌘ 9 | 按列表位置选择标签页／选择最后一个标签页 |
| 后退：⌘ ← 或 ⌘ [；前进：⌘ → 或 ⌘ ] | 后退／前进；在地址框和网页编辑区中，⌘←／⌘→ 仍用于文本移动 |
| ⌘ R | 重新加载网页 |
| ⌘ ⇧ R | 向源站重新验证缓存并刷新；保留登录 Cookie 和网站数据 |
| ⌘ F / ⌘ G / ⌘ ⇧ G | 页面查找／下一个／上一个匹配 |
| ⌘ +（或 ⌘ =）/ ⌘ - / ⌘ 0 | 页面放大／缩小／恢复 100% |
| Esc | 关闭地址／查找浮层；没有浮层时停止加载 |
| ⌘ ⇧ C | 复制当前网址 |
| ⌘ ⇧ P | 验证并填写当前网站保存的密码 |
| ⌘ D | 添加／移除书签 |
| ⇧ ⌘ L / ⌘ Y / ⇧ ⌘ J / ⌥ ⌘ B | 资料库／历史记录／下载／书签 |
| ⌥ ⇧ ⌘ S / ⌥ ⇧ ⌘ R / ⌥ ⇧ ⌘ P | 截图／录屏／截取当前网页（可在设置中修改） |
| ⌥ ⌘ → / ⌥ ⌘ ← | 下一个／上一个空间 |
| ⌥ ⌘ N | 新建分组 |

## 登录状态与密码

### 保留网站登录状态

1.4.0 起，网站登录、Chromium 保存的密码与导入的密码库在**更新后继续保留**，且不会弹出钥匙串密码框。

当前发行包采用 ad-hoc 签名，macOS 会把钥匙串条目绑定到某一个具体构建，因此 Nous 不再把加密密钥放在钥匙串，而是保存在 `~/Library/Application Support/Nous Browser/Secrets/storage.key`（仅当前用户可读）。这与 WebKit 浏览器把网站数据保存在用户资料目录中的方式相当；请像保护整个用户目录一样保护它。

**从 1.1.x（WebKit）或更早的 Chromium 构建升级到 1.4.0 时需要再登录一次**：旧构建的密钥只能由旧构建读取。之后的更新不再需要。

### 截图与录屏权限

1.4.1 起，本机构建用一张本地自签名证书签名（私钥文件位于 `~/Library/Application Support/NousSigning/`，不进钥匙串）。macOS 按证书识别应用，所以「屏幕与系统录音」权限授予一次后，后续更新会继续有效。从 1.4.0 及更早版本升级后需要再授权一次。

### 从 Apple「密码」或 Chrome 导入

1. 在 Apple「密码」或 Chrome 密码管理器中，使用其导出功能生成密码 CSV。
2. 在 Nous Browser 中打开 **设置 → 密码 → 导入密码…**，再选择该 CSV 文件。
3. 按 macOS 提示使用 **Mac 登录密码或 Touch ID** 完成设备验证。
4. 查看导入结果，然后将导出的 CSV 移到废纸篓。CSV 内含可直接读取的明文密码，请妥善处理。

打开支持的 HTTPS 登录页面后，点击“填写密码”或按 **⌘⇧P**。完成设备验证后，选择要使用的账号；只有一个匹配账号时会直接填写。应用不会自动提交登录表单。

填写严格匹配密码条目的**协议、主机和端口**，并检查当前标签页与表单是否仍然有效。跨域 iframe、隐藏字段和更改密码表单不在支持范围内；部分网站可能限制嵌入式浏览器登录或要求额外验证。

### 存储与限制

- 导入的密码库以 AES-GCM 加密保存在 `~/Library/Application Support/Nous Browser/Passwords.vault`。每次导入或读取前都要求 Touch ID 或 Mac 登录密码验证。
- 密码不会写入标签页文件、日志或剪贴板。解锁后的账号列表会在关闭、切换到后台、页面变化或超时后清除。
- CSV 导入是用户主动进行的迁移；不读取 Safari／Chrome 内部密码库或 iCloud 钥匙串，不迁移通行密钥或验证码。

## 本地数据

| 数据 | 位置 |
| --- | --- |
| 窗口、标签页、分组 | `~/Library/Application Support/Nous Browser/session*.json`、`session-windows/` |
| 空间与固定项（各窗口共享） | `~/Library/Application Support/Nous Browser/session-spaces.json` |
| 本机访问记录与网页推荐 | `~/Library/Application Support/Nous Browser/history.json` |
| 资料库（截图、录屏、书签、历史与下载记录） | iCloud 云盘 `Nous Browser/`；未开启 iCloud 云盘时为 `~/Library/Application Support/Nous Browser/Library/` |
| Cookie、网站存储、Chromium 保存的密码 | `~/Library/Application Support/Nous Browser/Chromium/Local/GitHub/` |
| 加密密钥 | `~/Library/Application Support/Nous Browser/Secrets/storage.key` |
| 导入的密码库 | `~/Library/Application Support/Nous Browser/Passwords.vault` |
| 网站图标缓存 | `~/Library/Caches/Nous Browser/Favicons/` |
| 应用偏好与快捷键 | macOS `UserDefaults`，应用标识 `com.cellier.nous-browser` |

删除应用文件不会自动清除以上数据。

网页推荐记录只保存在本机。升级后会先纳入现有标签页，之后随实际访问逐步积累频率；中文标点只归一化网址主机，搜索句子和网址路径、查询参数保留原文。

新标签页标题使用 Instrument Serif 字体，随应用打包，许可见 `Resources/Fonts/OFL.txt`。

## 从源码构建

安装 Xcode 并完成首次启动配置，在仓库根目录运行：

```sh
zsh Scripts/build.sh                              # NousCore 引擎 + Swift + 打包
NOUS_SKIP_ENGINE_BUILD=1 zsh Scripts/build.sh     # 只改 Swift 时跳过引擎
open "build/Nous Browser.app"
```

`Scripts/build-nouscore.sh` 把 `Engine/nous` 链入 Chromium 源码树、应用 `Engine/patches/apply_chromium_patches.py`，编译出 `.build/nouscore/sdk/NousCore.framework`；`Scripts/build-chromium.sh` 编译 Swift、打包并添加无需私钥的 ad-hoc 签名，不安装应用。架构与补丁说明见 [Engine/README.md](Engine/README.md) 和 [Chromium 构建说明](Docs/Chromium-Build.md)。

## 测试

```sh
zsh Scripts/test.sh          # 需先运行 Scripts/build-nouscore.sh 生成 NousCore SDK
```

单元测试使用合成数据和模拟凭据后端，不能替代真实中文输入法、Finder 拖放、网站登录、升级与长时间性能验收。快捷键核对见 [KeyboardShortcuts](Docs/KeyboardShortcuts.md)。**目前没有充分配对测量证明性能与 Chrome 相同。**

需要手动检查导航、下载和登录状态保留时，可启动本机测试页面：

```sh
python3 Tests/Fixtures/browser_test_server.py
```

在应用中访问 `http://127.0.0.1:8765/`，使用页面提供的虚构账号登录、保存测试备注，然后正常退出并重新打开应用，检查会话和备注是否保留。`/browser-profile` 提供浏览器身份检查，`/web-compatibility` 提供网页全屏与弹窗行为检查。

`/downloads` 提供系统保存框、改名、取消、覆盖、Blob、data URL、带模拟登录状态的附件，以及图片／音频右键下载测试。所有文件与登录数据均为本地生成的测试内容。

## 打包安装文件

完成 Release 构建后运行：

```sh
zsh Scripts/package-release.sh
```

安装镜像、ZIP 和 SHA256 校验文件生成在 `dist/`。脚本会核对版本、实际 CPU 架构和应用签名，并验证 DMG 与 ZIP 的内容。
