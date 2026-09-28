# emacs-dsh

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 Emacs 客户端，交互方式参考 [pimacs.el](https://github.com/ananthakumaran/pimacs.el)。支持创建和恢复会话、流式回复、模型与思考程度切换、`/` 命令、技能、`@` 文件补全和图片附件。连接时无需输入用户名、密码或手动粘贴 token。

## 连接方式

| 模式 | 适用情况 | 安装要求 | Host 生命周期 |
| --- | --- | --- | --- |
| `auto`（默认） | 检测到 bridge 文件时优先复用 Desktop，否则由 Emacs 启动 Web Host | 使用 Desktop 时安装 [emacs-dsh-host-bridge](https://github.com/wowhxj/emacs-dsh-host-bridge)；回退启动时需有 `dsh` CLI | 跟随实际选中的 Host |
| `desktop` | 始终复用 DSH Desktop Host 及其 profile | 安装并启用独立 Host bridge | 由 Desktop 管理；Emacs 不负责启动 |
| `managed` | 始终由 Emacs 启动本机 Web Host | Emacs 所在系统中能运行 `dsh` CLI | 首次连接时启动 `dsh web`，退出 Emacs 时结束该进程 |

两种 Host 都只连接本机 `127.0.0.1`。自动模式以 bridge 文件作为 Desktop Host 可用的信号；文件存在但损坏或无效时会报告错误，不会悄悄启动另一个 Host。托管 Host 用 `dsh web --host 127.0.0.1 --port 0 --no-open` 启动，从输出取得一次性 URL，并换取 Host 签名 cookie。`--port 0` 由系统选择空闲端口。bridge 与 Emacs 包分别安装和更新。**两个 Host 使用不同的 profile，会话、模型设置与技能配置不一定相同。**

## 安装

需要 Emacs 29.1+ 和可用的 DSH。`websocket.el` 已声明在 Emacs 包的 `Package-Requires` 中，通过包管理器安装时无需单独配置；源码直载时需自行确保它在 `load-path` 中。

通过 Emacs 包管理器安装本仓库后，示例配置为：

```elisp
(use-package emacs-dsh
  :commands (emacs-dsh-chat emacs-dsh-resume emacs-dsh-connect)
  :bind (("<f7>" . emacs-dsh-chat)
         ("C-c C-r" . emacs-dsh-resume)))
```

开发时也可添加 `:load-path "/absolute/path/to/emacs-dsh"`。源码直载时若有旧的 `emacs-dsh.elc`，请重新编译或删除该旧文件，以免 Emacs 加载旧实现。

### 没有 bridge 时：Emacs 管理 Host

先在 **Emacs 所在的操作系统** 中确认 `dsh web --help` 可运行，并为该 DSH profile 配置模型。没有 bridge 文件时运行 `M-x emacs-dsh-chat` 会自动启动本机 Host；无需预先打开 DSH Desktop。若图形 Emacs 的 PATH 找不到 CLI，可指定绝对路径：

```elisp
(setq emacs-dsh-managed-command "/absolute/path/to/dsh")
```

WSL Emacs 会启动 **WSL 内的 Linux `dsh`**，并向该 Host 发送 Linux 路径。macOS Emacs 会启动 macOS `dsh`。托管 Host 随当前 Emacs 进程结束；再次使用时会重新启动，已保存的会话仍由 DSH profile 管理。

### 可选：连接 DSH Desktop

先在 DSH Desktop 的 **Plugins → Install** 安装 `github:wowhxj/emacs-dsh-host-bridge`，启用后按提示重启 App/Host。安装说明和故障排查见 [独立插件仓库](https://github.com/wowhxj/emacs-dsh-host-bridge)。默认 `auto` 模式会优先使用生成的 bridge 文件，无需额外配置。如果想强制只使用 Desktop，可设置：

```elisp
(setq emacs-dsh-connection-mode 'desktop)
```

bridge 文件应位于 macOS 的 `~/.dsh/emacs-dsh-bridge.json`，或 Windows 的 `%USERPROFILE%\.dsh\emacs-dsh-bridge.json`；自定义 `DSH_HOME` 时位于相应目录。**不要打印、分享或提交此文件**，其中含有认证凭据。macOS 上需先保证 DSH home 仅当前用户可访问：`chmod 700 "${DSH_HOME:-$HOME/.dsh}"`。Windows 版用当前用户的 DPAPI 保护凭据；WSL Emacs 通过 `powershell.exe` 解密。

Windows Desktop + WSL Emacs 时，新会话目录必须能被 Windows Host 访问，例如 `/mnt/d/project/`；插件会用 `wslpath` 转换路径。原生 macOS 无需路径转换。Desktop Host 必须运行，但 Emacs 不需要一直显示 Desktop 窗口。

## 使用

| 操作 | 说明 |
| --- | --- |
| `M-x emacs-dsh-chat` 或 `<f7>` | 选择目录并创建新会话；`C-u M-x emacs-dsh-chat` 可在创建前选择模式 |
| `C-c C-r` 或 `/resume` | 在 minibuffer 中搜索 Host 列出的所有工作区的会话（可用 Vertico/Orderless）；按时间、session ID、工作目录和首句交互对齐显示；恢复后关闭原聊天 buffer（未发送的输入会先确认） |
| `RET` 或 `C-c C-c` | 发送输入 |
| `C-c C-s` / `C-c C-k` | 运行中 steer / 取消轮次 |
| `C-c C-q` | 关闭 Emacs 聊天 buffer，不删除 Host 会话 |
| `/mode` 或 `M-x emacs-dsh-select-mode` | 为**尚未开始对话**的会话选择模式（Standard、PTC、Minimal、Creator，按 Host 实际可用模式显示） |
| `TAB` | 补全 `/` 命令、技能或 `@` 文件引用 |
| `C-c C-p`、`s-v` 或 `s-V` | 智能粘贴文本、文件引用或图片 |

顶部状态行显示上下文 token 使用量（Host 提供时）、模型、推理程度和模式；Emacs 原有 mode-line 的聊天 buffer 名显示工作目录（同名目录的多个会话会自动编号），并追加 DSH 空闲/思考/工具执行/等待操作的动态状态。最近一条用户 query 保留在聊天记录中。新会话会自动读取 Host 默认模型。`/model` 可选择模型，`/reasoning` 可选择当前模型支持的思考程度。`/help` 显示客户端命令及 Host 提供的命令；其他 Host 命令由 `commands/list` 发现并交给 Host 执行。已注册的 `/skill-name` 作为 prompt 提交。

输入 `@` 后按 `TAB` 补全 Host 文件引用；Host 没有候选时，会从当前工作目录就地补全文件和子目录（进入目录后可继续补全，不扫描整个项目）。`M-x emacs-dsh-insert-file` 可手动插入引用，`M-x emacs-dsh-attach-image` 可暂存图片；待发送图片显示在输入框上方，图形界面显示缩略图，点击预览即可移除。智能粘贴在 WSL 读取 Windows 剪贴板，在 macOS 读取本机剪贴板。

历史由 Host 保存。`/resume` 的 minibuffer 搜索覆盖 `session/list` 返回的全部可见会话，不逐个请求历史快照；进入会话后初次加载最近 `emacs-dsh-max-messages` 条消息，随后通过 WebSocket 接收实时事件并支持重连。旧**消息**分页和历史图片预览尚未实现。

Host 请求审批或提问时，客户端通过 `$events` 接收并在 minibuffer 中逐个处理：审批可“拒绝/仅本次允许”，问答支持选项、逗号分隔多选、自由文本和空输入跳过；`C-g` 取消问题组。关闭聊天 buffer 后该客户端不再接管该会话的请求，仍可由其他 DSH 客户端处理。切换模式只适用于空白会话；已开始对话的会话需要先新建会话再选择模式。

## 故障排查

- **提示找不到 `dsh`**：自动模式没有找到 bridge 文件，已尝试启动本机 Host。请在 Emacs 所在系统安装/配置 CLI，或设置 `emacs-dsh-managed-command` 的绝对路径；若希望复用 Desktop，确认独立 bridge 已启用并生成文件。
- **托管 Host 启动超时或退出**：在 Emacs 所在系统手动运行 `dsh web --host 127.0.0.1 --port 0 --no-open` 检查 CLI/profile 的错误。不要分享输出中的 token URL。
- **Desktop 模式找不到 bridge**：确认独立插件安装在 Desktop 使用的 profile、已启用且 Host 已重启。用 `ls -ld ~/.dsh ~/.dsh/emacs-dsh-bridge.json` 检查 macOS 文件是否存在和权限，不要输出文件内容。自定义路径可设 `emacs-dsh-bridge-file`。
- **HTTP 401/403**：401 会重新换取 cookie；反复失败时检查 Host 是否重启或 bridge 是否属于当前 Host。403 检查 Host/Origin 配置。
- **路径、`@` 引用或技能不可用**：确认当前模式的 Host 能访问项目目录，并在该 Host profile 中配置了技能。客户端从 `skills/list` 读取 Host 已发现的技能。

`M-x emacs-dsh-connect` 可主动检查并重新鉴权；正常聊天无需先运行它。

## 开发验证

把本仓库与已安装的 `websocket.el` 加入 `load-path` 后运行：

```sh
emacs -Q --batch -L /path/to/websocket-el -L . -f batch-byte-compile emacs-dsh.el
emacs -Q --batch -L /path/to/websocket-el -L . -l emacs-dsh.el -l tests.el -f ert-run-tests-batch-and-exit
```

Windows/WSL 的 Emacs 回归测试可运行；macOS 的剪贴板与路径有单元测试，真实 Desktop Host 端到端行为仍需在 Mac 上验证。Host bridge 有自己的测试和发布流程。

协议参考：[Session Controller](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/session-controller)、[Connection](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client/connection)、[API Gateway](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/gateway)。
