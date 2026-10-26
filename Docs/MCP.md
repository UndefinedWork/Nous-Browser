# 使用 AI agent 操作 Nous Browser

Nous Browser 提供标准 MCP（Model Context Protocol）服务器。支持 **MCP stdio** 的本机客户端可以连接，例如桌面 AI 应用、命令行 agent 或自己编写的 MCP 客户端；不绑定某一家模型服务。

## 连接

1. 安装并打开包含 MCP 功能的 Nous Browser。
2. 按 **⌘,** 打开 **设置 → AI Agents (MCP)／AI 助手（MCP）**，打开“允许 AI 助手使用 Nous Browser”。
3. 点击“复制连接配置”，把配置加入所用 AI 客户端的 MCP 服务器设置。
4. 在客户端重新连接服务器。Nous Browser 的设置页显示“已就绪，可供本机 AI 助手使用”时，客户端可发现并调用浏览器工具。

安装在“应用程序”中的标准配置：

```json
{
  "mcpServers": {
    "nous-browser": {
      "command": "/Applications/Nous Browser.app/Contents/MacOS/NousBrowserMCP",
      "args": []
    }
  }
}
```

不同客户端的配置文件位置、外层字段和界面可能不同。通用连接信息是 **类型 stdio**、**命令为上述完整路径**、**无额外参数**。在 JSON 的 `command` 中保留路径中的空格，不要另外添加 shell 引号。如果应用不在“应用程序”文件夹，优先复制应用设置页生成的实际路径。

客户端启动的是随应用安装的小型 MCP 辅助程序；它连接正在运行的 Nous Browser，操作其中现有的窗口和标签页。浏览器未打开或此设置已关闭时，调用会返回可读错误；不会悄悄创建另一个浏览器会话。

## 使用范围

AI 助手可以通过已暴露的工具查看窗口和标签、打开或切换标签、导航网页、读取页面结构与文字、操作页面元素，以及获取页面截图。页面交互需要指定标签 ID；元素操作使用最近一次页面快照提供的引用，页面变化后需要重新获取快照。

| 工具 | 能力 |
| --- | --- |
| `browser_list_windows`、`browser_list_tabs` | 获取窗口、标签、标题、网址和稳定 ID；标签列表可按窗口筛选。 |
| `browser_new_window`、`browser_new_tab` | 新建窗口或在指定窗口中新建标签，可提供网址；新标签可指定放在哪个标签之后。 |
| `browser_select_tab`、`browser_close_tab` | 切换或关闭指定标签；关闭最后一个标签也会关闭其窗口。 |
| `browser_navigate`、`browser_back`、`browser_forward`、`browser_reload` | 导航指定标签；刷新可选择跳过缓存。 |
| `browser_snapshot` | 获取主文档的文字和可交互元素，最多 50,000 个字符、300 个元素，返回 `snapshot_id` 和元素 `ref`。 |
| `browser_click`、`browser_fill`、`browser_press_key` | 使用 `tab_id`、`snapshot_id`、`ref` 操作对应元素；填写不支持密码和文件字段。 |
| `browser_scroll` | 按 CSS 像素滚动指定页面。 |
| `browser_screenshot` | 获取指定网页当前可见区域的 PNG 截图，宽度最多 2,000 像素。 |

工具接受和返回的字段以客户端读取到的 `tools/list` 为准。导航只接受完整的 `http://` 或 `https://` 网址，不开放 `file:`、`javascript:` 或外部应用协议。

可让 agent 先尝试：“列出 Nous Browser 的标签页，打开一个新标签访问 example.com，然后读取页面标题。”客户端应先列出可用工具，再按工具的输入说明调用。

## 控制与隐私

- 此功能默认关闭。只连接你信任的 AI 客户端；启用后，当前 macOS 用户下能够连接本地通道的程序可以读取和操作浏览器中的网页，包括已登录的网站。此版本不提供逐个 agent 的独立授权。网页内容交给哪个模型、是否发送到云端，取决于该客户端的设置。
- 设置中的开关可随时停止后续调用，已完成的网页操作不会因此撤销。
- 本机连接使用当前 macOS 用户专用的本地通道，不开放局域网或公网端口。stdio 辅助程序不需要 Node.js 或 Python。
- 没有导出密码库、Cookie、完整浏览历史或执行任意 JavaScript 的工具。不要把这理解为页面本身不含敏感信息：agent 仍可能读到当前网页中展示的账号或业务内容。
- MCP 客户端负责根据用户指令决定调用哪些工具。涉及提交表单、购买、删除内容等操作，仍应由客户端遵守自己的确认与权限规则。

## 当前边界

- 支持本机 **stdio** MCP 客户端。只有 HTTP／远程 MCP 接口的云端 agent，不能直接连接此版本；尚未提供 Streamable HTTP 或旧式 SSE 服务。
- 只操作 Nous Browser 的网页和标签，不提供控制其他应用或整个桌面的接口。
- 站点可能要求真实用户手势、系统权限、验证码或额外认证。此接口不会绕过这些要求；可回到浏览器手动完成后再继续。
- DOM 快照针对页面主文档，不包含任何 iframe 的内部内容。点击和按键使用网页 DOM 事件，不能替代浏览器要求的真实用户手势；按键范围以工具 schema 为准。
- 画布、浏览器原生对话框和网站自定义控件可能无法通过 DOM 元素工具操作。操作失败时应重新读取页面状态，不应重复猜测点击。

## 排查连接

| 情况 | 检查方法 |
| --- | --- |
| 客户端找不到命令 | 确认安装的是包含 MCP 的版本，使用设置页复制的完整路径。 |
| 可以列出工具，但调用提示浏览器不可用 | 打开 Nous Browser，并开启设置中的 AI 助手访问。 |
| 设置显示无法启动 | 先关闭此功能，再重新打开；同时避免运行多个使用同一用户数据的正式版实例。 |
| 元素引用失效或页面已改变 | 重新读取该标签的页面快照，使用新引用。 |
| 想停止 agent 操作 | 在设置中关闭访问，再在 AI 客户端断开 Nous Browser MCP 服务器。 |

协议参考：[MCP 标准传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) · [MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。
