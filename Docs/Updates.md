# GitHub 自动更新

Nous 1.1.9 起，GitHub 发行版使用 Sparkle 2.10.1 检查、验证、下载、替换应用并重新启动。

## 用户行为

- 默认定期检查（4 小时）；发现新版本时侧边栏的资料库按钮出现小圆点，不自动下载或重启。
- 资料库的“更新”页显示版本说明，点击“下载并安装”后下载、校验、安装并重启。校验或网络失败保留原应用。
- 1.4.0 起网站登录和保存的密码在更新后保留（见 [Chromium 构建说明](Chromium-Build.md#website-data)）。
- Nous Browser 菜单提供“检查更新…”，完全隐藏侧边栏时也能使用。
- 重启恢复已持久化的窗口与标签；网页未保存的编辑内容不由浏览器保证，更新前应保存。
- 1.1.8 及更早的用户需要手动安装一次包含更新器的版本，之后才可应用内更新。
- Mac App Store 发行应移除 Sparkle 并使用商店更新；代码也会阻止非 `github` 渠道或带 App Store receipt 的应用启动此更新器。

## 从另一台 Mac 发布新版

**每次发版只需在开发 Mac 上构建、测试、上传三个文件，然后在 GitHub 点一次发布工作流。** GitHub 用老用户已经信任的密钥签名。开发 Mac 只需仓库写权限，原发布 Mac 可以关机。

可以把下面这段话直接发给另一台电脑上的开发助手。

> 请先同步 Nous Browser 的 main，阅读 Docs/Updates.md，按这份手册发布我指定的新版本。构建、测试通过后，用 --for-github 打包，将本版本的三个文件上传到 Release 草稿，运行 Publish Nous Update。完成后发给我正式版链接和旧版「检查更新」的验收结果。更新签名交给 GitHub。

### 1. 准备版本并打包

在仓库根目录工作。开始开发前切到 `main` 并同步代码。如果改动在其他分支，先将本次要发布的改动合入 `main`。首次搭建构建环境请看[Chromium 构建说明](Chromium-Build.md)。

```sh
git switch main
git pull --ff-only origin main
```

在 `Resources/Info.plist` 设置新的显示版本 `CFBundleShortVersionString`（如 `X.Y.Z`）和比上次发行更大的整数构建号 `CFBundleVersion`。保留已有的更新公钥及更新地址。把用户能感知的变化写入 `Docs/releases/<版本号>.md`。使用全英文说明，或沿用双语文件的 `## English` 小节。GitHub 用该版本标签所对应的说明生成英文 Release notes。

提交本次源码、版本号和说明后，确认当前提交就是要发布的版本。在同一提交上构建、测试和打包。以下命令适用于装好 Xcode 并配置好 NousCore 编译环境的 Apple 芯片 Mac。

```sh
zsh Scripts/build.sh &&
zsh Scripts/test.sh &&
zsh Scripts/package-release.sh --for-github
```

打包会核对应用签名、版本、架构，以及 DMG 和 ZIP 的内容。成功后，记下 `dist/` 下本版本的 DMG、ZIP 和 `SHA256SUMS.txt`。有任何一步失败就先修复，然后重新打包。

### 2. 上传 GitHub Release 草稿

在同一个终端从项目版本文件读取版本并给本次提交打标签。执行前确认 `git status --short` 为空、这个版本号尚未发布。如果标签已存在，先确认它指向本次构建所用的提交。

```sh
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
RELEASE_TAG="v${RELEASE_VERSION}"
RELEASE_ASSET="dist/Nous-Browser-${RELEASE_VERSION}-macOS-arm64"
git tag "$RELEASE_TAG" HEAD &&
git push --atomic origin main "refs/tags/$RELEASE_TAG"
```

在 [GitHub Releases](https://github.com/UndefinedWork/Nous-Browser/releases) 创建草稿，选择刚推送的标签，上传上述三个文件，点 **Save draft**。也可以在同一个终端用已登录的 GitHub CLI 完成这步。

```sh
gh release create "$RELEASE_TAG" \
  "${RELEASE_ASSET}.dmg" "${RELEASE_ASSET}.zip" dist/SHA256SUMS.txt \
  --repo UndefinedWork/Nous-Browser --draft --verify-tag \
  --title "Nous Browser $RELEASE_VERSION" --notes-file "Docs/releases/$RELEASE_VERSION.md"
```

### 3. 签名并正式发布

打开 [Actions → Publish Nous Update](https://github.com/UndefinedWork/Nous-Browser/actions/workflows/publish-nous-update.yml)，点 **Run workflow**，分支选 **main**，`version` 填显示版本号（省略开头的 `v`），`mode` 选 **publish**，再点 **Run workflow**。也可以在上一步的终端运行。

```sh
gh workflow run publish-nous-update.yml --ref main \
  --repo UndefinedWork/Nous-Browser -f version="$RELEASE_VERSION" -f mode=publish
```

如果想先演练，选择 **verify**。它会验证包并测试签名，保留当前公开版本。确认后再以 **publish** 运行。已公开为预发布的版本也可以从这一步晋升为正式版。

### 4. 确认老用户能收到

1. 等本次 Actions 运行成功。打开 [最新正式版](https://github.com/UndefinedWork/Nous-Browser/releases/latest)，确认标签为本次版本，下载区有 DMG、ZIP、`SHA256SUMS.txt` 和 GitHub 生成的 `appcast.xml`。
2. 打开[客户端实际读取的更新清单](https://github.com/UndefinedWork/Nous-Browser/releases/latest/download/appcast.xml)。`sparkle:shortVersionString` 应对应本次版本，`sparkle:version` 应对应新构建号。
3. 在符合系统要求、仍运行旧版的 GitHub 版 Nous 里点 **Nous Browser → 检查更新**，应看到新版本。运行同一版本的客户端会显示已是最新版。

工作流显示红色时，打开失败的步骤查看原因。核对版本、标签、构建号及三个文件是否来自同一次打包；缺少附件就补入同一个草稿，再运行工作流。若失败发生在最后的公开下载验证，先检查 Latest 和更新清单的实际状态再重试。已公开的安装包要改内容时，使用新的版本号和构建号重新发布。

## 密钥和 macOS 授权

GitHub 的 `production-updates` 发布环境保存了加密密钥，只用于签署更新 ZIP 和更新清单。其他开发电脑无需复制、导出或重新生成私钥。仓库、Release 附件和发版说明里只应包含公开信息。

macOS 通过应用代码签名身份识别录屏授权。1.4.19 使用本地签名证书，1.4.21 使用 ad-hoc 签名，切换身份后系统可能要求重新授权。GitHub 的更新签名不会改变应用已有的 macOS 签名或 Apple 公证状态。

保有原更新私钥的 Mac 仍可用 `zsh Scripts/package-release.sh` 完成本地离线签名。请将原私钥单独安全备份。
