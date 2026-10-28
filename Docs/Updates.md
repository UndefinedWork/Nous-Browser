# GitHub 自动更新

Nous 1.1.9 起，GitHub 发行版使用 Sparkle 2.10.1 检查、验证、下载、替换应用并重新启动。

## 用户行为

- 默认定期检查（4 小时）；发现新版本时显示侧边栏更新按钮，不自动下载或重启。
- 展开侧边栏时按钮位于刷新左侧；竖条状态位于刷新上方。悬停 300 ms 显示玻璃提示。
- 点击更新按钮开始下载，校验后安装并重启。下载阶段可取消；校验或网络失败保留原应用。
- Nous Browser 菜单提供“检查更新…”，完全隐藏侧边栏时也能使用。
- 重启恢复已持久化的窗口与标签；网页未保存的编辑内容不由浏览器保证，更新前应保存。
- 1.1.8 及更早的用户需要手动安装一次包含更新器的版本，之后才可应用内更新。
- Mac App Store 发行应移除 Sparkle 并使用商店更新；代码也会阻止非 `github` 渠道或带 App Store receipt 的应用启动此更新器。

## 发布

1. 修改 `Resources/Info.plist` 的显示版本和 **严格递增** 的 `CFBundleVersion`。
2. 测试后执行 `zsh Scripts/build.sh`。
3. 执行 `zsh Scripts/package-release.sh`，得到 DMG、ZIP、SHA256SUMS.txt 及签名 `appcast.xml`。
4. 在 GitHub 创建对应 `v<版本>` 的 draft release，上传以上四个文件，核对安装包后发布为 stable / latest。
5. 客户端读取 `https://github.com/UndefinedWork/Nous-Browser/releases/latest/download/appcast.xml`。不要只上传 DMG；更新器使用 ZIP。
6. 不要把预发布版本设置为 latest。四个文件全部上传完成后再发布，避免客户端看到不完整的版本。

`appcast.xml` 指向对应版本的固定 ZIP URL；清单和 ZIP 均有 Ed25519 签名。清单任何修改都需要重新签名。下载包在解压前验证签名，错误签名不会安装。SHA256 文件用于人工核验，不代替签名。

## 发布密钥

发布私钥位于发布机器用户目录的 `.local/share/NousBrowserRelease/update-signing-key`（目录权限 0700、文件权限 0600），不使用 macOS 钥匙串，不会要求钥匙串密码。私钥绝不能提交到仓库或上传 Release。可以通过 `NOUS_UPDATE_SIGNING_KEY` 指定安全保存的私钥文件路径。

应用中只包含 `SUPublicEDKey` 公钥。必须安全备份发布私钥；丢失后不能直接换公钥继续更新已安装的版本。更换发布机器时安全迁移原私钥，不能重新生成后覆盖。脚本使用本地文件签名，不从环境变量打印密钥，也不把密钥包含在安装包内。

当前应用仍采用 ad-hoc 代码签名，更新包签名不等于 Apple Developer ID 签名或公证。首次安装仍可能遇到 Gatekeeper 提示；正式对外分发建议配置 Developer ID 和公证，且保持签名身份稳定。应用若不属于当前用户或位于不可写目录，系统仍可能要求安装授权，这与发布私钥无关。
