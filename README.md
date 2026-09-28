# emacs-dsh

emacs-dsh 是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 Emacs 客户端。它参考了 [pimacs.el](https://github.com/ananthakumaran/pimacs.el) 的对话方式，连接**已经运行的 DSH Web Host**，在 Emacs 中创建、恢复和使用 Host 保存的会话，不会另起一个 Harness 后端。

首次使用需在 DSH Host 中安装并启用本仓库的 `host-bridge` 插件。此后 Emacs 会自动发现本机 Host 并完成鉴权；打开聊天时无需输入用户名、密码或粘贴令牌。**Host 进程必须保持运行**，但不必一直打开 DSH Desktop 窗口：也可以运行配置了同一 bridge 的 `dsh web --no-open`。

## 环境要求

- Emacs 29.1+，以及已配置可用模型的 DSH Web Host。
- `websocket.el` 是 Emacs 包依赖，已写入 `emacs-dsh.el` 的 `Package-Requires`。通过 Emacs 包管理器安装本插件时会安装依赖；若直接把源码放进 `load-path`，需确保 Emacs 已能加载 `websocket`。
- Emacs 与 Host 在同一台机器上。本插件只连接 bridge 公布的 `127.0.0.1` 地址。Windows Host + WSL Emacs、原生 macOS Emacs 使用同一客户端；两者的本机鉴权方式见下文。

## 安装

1. 在**正在使用的 DSH Host profile** 中安装本仓库的 `host-bridge` 目录并启用，然后重启 Host。官方 DSH Desktop 的 `desktop` profile 由应用管理：请在 Desktop 的 **Plugins** 页安装本地 `host-bridge` 目录，不要用独立 CLI 修改这个 profile。若运行独立的 `dsh web`，可在其 Web profile 中执行 `dsh plugin --profile web add file:/absolute/path/to/emacs-dsh/host-bridge`。只安装 Emacs 包不会自动安装 Host bridge。
2. 确认 bridge 文件已生成：Windows 为 `%USERPROFILE%/.dsh/emacs-dsh-bridge.json`；macOS 默认为 `~/.dsh/emacs-dsh-bridge.json`。如果 Host 设置了 `DSH_HOME`，文件位于该目录下。**不要把 bridge 文件提交到 Git。**
3. 安装 Emacs 客户端。使用包管理器安装本仓库后，可加入以下配置；`<f7>` 是示例快捷键，可按需修改：

```elisp
(use-package emacs-dsh
  :commands (emacs-dsh-chat emacs-dsh-resume emacs-dsh-connect)
  :bind (("<f7>" . emacs-dsh-chat)
         ("C-c C-r" . emacs-dsh-resume)))
```

开发时也可在上述配置中加入 `:load-path "/absolute/path/to/emacs-dsh"` 直接加载本仓库。源码直载不会替你安装包依赖，但**不需要**在配置里额外写一个 `use-package websocket` 声明。

### Windows Host + WSL Emacs

bridge 将启动 URL 用当前 Windows 用户的 DPAPI 加密后保存。WSL Emacs 会通过 `powershell.exe` 解密，并用 `wslpath` 在 WSL 与 Windows 路径间转换；通常无需设置 `emacs-dsh-wsl-path-function`。用于新会话的目录必须是 Windows Host 可访问的目录，例如 `/mnt/d/project/`。

### 原生 macOS Emacs

Emacs 和 Host 直接使用 POSIX 路径，不需要 PowerShell 或 `wslpath`。bridge 在 macOS 上将启动 URL 写入本机文件，因此启用前要确保 DSH home 是当前用户专用目录，例如 `chmod 700 ~/.dsh`；bridge 文件以 `0600` 权限创建。若使用自定义 `DSH_HOME`，请让 Emacs 和 Host 使用同一个值。

macOS Desktop 首次安装 Host bridge：

1. 在终端运行 `chmod 700 ~/.dsh`。若 Mac 上还没有本仓库源码，运行 `git clone https://github.com/wowhxj/emacs-dsh.git ~/sandbox/emacs-dsh`；已有源码则直接使用现有目录。
2. 在 DSH Desktop 左侧打开 **Plugins**，选择安装插件，在安装输入框填入本地 `host-bridge` 目录的**绝对路径**，例如 `/Users/randolph/sandbox/emacs-dsh/host-bridge`。安装后确认 `emacs-dsh-host-bridge` 已启用，并重启 App 和 Host。只把 `emacs-dsh.el` 安装进 Emacs 不会完成这一步。
3. 运行 `test -f ~/.dsh/emacs-dsh-bridge.json && echo ready || echo missing`。看到 `ready` 后再启动 `M-x emacs-dsh-chat`。不要用 `cat` 输出 bridge 文件，其中含有启动令牌。

macOS 的代码路径已有回归测试，但目前尚未在真实 macOS Host 上完成端到端验证。

## 使用

| 操作 | 说明 |
| --- | --- |
| `M-x emacs-dsh-chat` 或 `<f7>` | 选择目录并创建新会话；同一目录再次启动仍会新建会话。 |
| `C-c C-r` 或 `/resume` | 恢复 Host 保存的会话。列表按「创建时间、session ID、首句交互」三列对齐；首次打开会从会话快照读取创建时间。 |
| `RET` 或 `C-c C-c` | 发送输入框中的消息。 |
| `C-c C-s` / `C-c C-k` | 在运行中 steer / 取消当前轮次。 |
| `C-c C-q` | 关闭当前 Emacs 聊天 buffer，不删除 Host 会话。 |
| `TAB` | 补全 `/` 命令、技能或 `@` 文件引用。 |
| `C-c C-p`、`s-v` 或 `s-V` | 智能粘贴文本、文件引用或图片附件。 |

最近一条用户 query 固定显示在聊天窗口顶部。Emacs mode-line 显示会话 ID、运行状态、模型、思考程度和项目路径。新会话会自动读取 Host 的默认模型，无需先运行 `/model`。

`/model` 可以从 Host 的模型列表选择，也支持 `/model provider/model`；`/reasoning` 可以选择当前模型支持的思考程度。输入 `/help` 可查看客户端命令及 Host 当时提供的命令。普通 Host 命令通过 `commands/list` 实时发现并交给 Host 执行；已注册的 `/skill-name` 作为 prompt 提交。未知命令会提示错误并保留草稿。

输入 `@` 后按 `TAB` 可补全 Host 的文件引用；含空格的文件名会写成 `@"..."`。`M-x emacs-dsh-insert-file` 可手动插入引用，`M-x emacs-dsh-attach-image` 可暂存 PNG/JPEG/WebP/GIF 图片。智能粘贴在 WSL 下读取 Windows 剪贴板，在 macOS 下读取本机剪贴板：文件变成 `@` 引用，PNG/TIFF 图片变成下一次发送时附带的 PNG 附件。

会话历史由 Host 保存。客户端初次加载最近 `emacs-dsh-max-messages` 条消息，随后通过 WebSocket 接收实时事件和重连。旧历史分页、图片历史预览、人工审批及交互式问答控件尚未实现；遇到需要审批或回答的轮次，请在 DSH Desktop/Web 中处理。

## 连接与故障排查

bridge 使用 Host 自身的 `connection.authenticatedUrl()`，不新增未鉴权 HTTP 接口。Windows 的 bridge 文件保存 DPAPI 密文；macOS 的 bridge 文件保存明文启动 URL，因此其目录和文件权限很重要。Emacs 会用该 URL 换取签名 cookie，cookie 失效时自动重新鉴权。`M-x emacs-dsh-connect` 可用于主动检查连接，日常聊天无需先运行它。

- **找不到 bridge**：错误会给出 Emacs 实际查找的路径。确认 bridge 安装在当前 Host profile、已启用，且 Host 已重启；只安装 Emacs 包不够。macOS 可用 `ls -ld ~/.dsh ~/.dsh/emacs-dsh-bridge.json` 检查文件是否存在和目录权限，但不要输出 bridge 文件内容，其中含有启动令牌。若 Host 使用了自定义 `DSH_HOME`，让 Emacs 使用同一变量，或把文件路径设置为 `emacs-dsh-bridge-file`。仅在 Plugins 界面看到 active 状态不足以证明文件已生成。
- **Host 关闭后无法连接**：保持 DSH Web Host 运行；若改用 `dsh web --no-open`，需要在其 profile 中启用 bridge。
- **HTTP 401/403**：401 会自动尝试换新 cookie；反复失败时检查 bridge 是否属于当前 Host。403 请检查 Host/Origin 配置。
- **路径或 `@` 引用不可用**：确认 Host 能访问所选项目目录。Windows Host 无法直接读取 WSL 专属的 Linux 路径。
- **技能未出现**：技能由 DSH Host 发现，Emacs 只读取 Host 的 `skills/list`；检查 Host profile 的技能目录配置。

## 开发验证

把本仓库和已安装的 `websocket.el` 加入 Emacs 的 `load-path` 后运行：

```sh
emacs -Q --batch -L /path/to/websocket-el -L . -f batch-byte-compile emacs-dsh.el
emacs -Q --batch -L /path/to/websocket-el -L . -l tests.el -f ert-run-tests-batch-and-exit
node --test host-bridge/tests.mjs
```

Host bridge 测试应分别在 Windows 和 POSIX 环境运行；Windows DPAPI 测试需使用运行 DSH 的 Windows 用户。当前 WSL/Windows 环境已通过 Emacs 测试及两侧的 Host bridge 测试，macOS 的真实 Host 与剪贴板行为仍待实机验证。

协议参考：[Session Controller](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/session-controller)、[Connection](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client/connection)、[API Gateway](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/gateway)。
