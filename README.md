# emacs-dsh

一个面向**正在运行的 DeepSeek Harness Web Host** 的 Emacs 客户端。借鉴 [pimacs.el](https://github.com/ananthakumaran/pimacs.el) 的 Emacs 对话交互，但直接使用 DSH 的 Connection RPC + Gateway Remote Stream 协议，**不依赖 Pi，也不另起一个 DSH 后端**。参考了用户 WSL Emacs 配置的「选目录后总是新会话」「独立恢复旧会话」「顶部钉住上一条 prompt」「@ 文件引用」「WSL 路径映射」设计。

> 状态：可加载和测试的初版。需在已开启 Web Host 的 DSH 上使用；`dsh web` 的启动 URL（含 `?token=`）用于首次鉴权。尚未对真实 Host 执行端到端发送测试，因为当前会话没有提供其启动令牌。

## 安装

Emacs 29.1+，依赖 [websocket.el](https://github.com/ahyatt/emacs-websocket)。`:vc` 关键字需要 Emacs 30+ 内置的 `use-package-vc`（Emacs 29 可另装 `use-package-vc`）。例如：

```elisp
(use-package websocket :ensure t)
(use-package emacs-dsh
  :vc (:url "https://github.com/wowhxj/emacs-dsh" :rev newest)
  :after websocket
  :commands (emacs-dsh-chat emacs-dsh-connect emacs-dsh-resume)
  :bind (("<f6>" . emacs-dsh-chat)
         ("C-c p r" . emacs-dsh-resume))
  :custom
  (emacs-dsh-url "http://127.0.0.1:19387/")
  :config
  (when (getenv "WSL_DISTRO_NAME")
    (setq emacs-dsh-wsl-path-function #'emacs-dsh-wsl-windows-path)))
```

1. 打开正在运行的 DSH Web Host。拿到其启动时打印的完整 URL，例如 `http://127.0.0.1:19387/?token=...`。
2. `M-x emacs-dsh-connect`，**临时粘贴**完整 URL；成功时取得签名 cookie。不要将 token 放进版本管理或长期配置。Emacs 默认 `url-cookie-file` 为 nil，不自动持久化 cookie；若你自行配置了持久化 cookie 文件，请把它按秘密文件保护。
3. `<f6>` 选择 root 创建新会话；`C-c p r` 或 `C-c C-r` 浏览并恢复 Host 的会话（不会创建新会话）。
4. 在底部输入框撰写，`C-c C-c` 发送；`C-c C-s` steer；`C-c C-k` 取消运行中的轮次；`C-c C-q` 关闭本地窗口。`C-c C-p` 智能粘贴文本/文件路径；`M-x emacs-dsh-insert-file` 插入文件引用；`M-x emacs-dsh-attach-image` 发送图片。

会话在 DSH Host 持久化；关闭 Emacs buffer 不删除 Host 的会话。同一目录重复 `<f6>` 每次生成独立会话。上一条用户 prompt 显示在 header-line，运行状态显示在 tab-line。恢复时首先显示最近 `emacs-dsh-max-messages` 条消息，再通过 WebSocket 接收新增事件、自动重连；旧历史分页、工具输出详情和图片历史预览尚未做。

### Windows Host + WSL Emacs

用户的 WSL 配置会直接从 Windows 剪贴板读取文件列表及位图。当前初版的智能粘贴只处理 Emacs kill-ring 中可访问的文件路径；Windows 文件拖放/位图暂不支持自动粘贴，图片请用 `emacs-dsh-attach-image` 选择文件。**WSL Linux 路径必须转换成 Windows Host 可识别的路径**：

```elisp
(setq emacs-dsh-wsl-path-function #'emacs-dsh-wsl-windows-path)
```

例如 WSL 内 `/mnt/d/project/` 将通过 `wslpath -w` 转成 Windows 路径发送给 Host；无法访问的 WSL 专属路径不能用作 Windows 工作目录。恢复 Windows Host 的会话时若 `cwd` 不是 WSL 可访问路径，输入/显示依然可用，文件补全须选择本地可访问目录。

### 故障排查

- HTTP 401：重新执行 `emacs-dsh-connect`，并确保 URL 来自**当前进程**，Host/IP/端口一致。Cookie 会过期；Host 重启可能需要重新鉴权。
- HTTP 403：检查 Host、Origin、网络配置；不要绕过 DSH 的 Host/Origin 防护。
- WebSocket 断开会在约 3 秒后重连；浏览器页面和 Emacs 都应连接**同一个** DSH Web Host。
- 没有可用模型时，先在 DSH GUI 选择、配置模型；本插件使用 Host 的会话默认模型。

## 开发与测试

```sh
emacs -Q --batch -L /path/to/websocket-el -L . -f batch-byte-compile emacs-dsh.el
emacs -Q --batch -L /path/to/websocket-el -L . -l tests.el -f ert-run-tests-batch-and-exit
```

协议参考：[DSH Session API](https://github.com/deepseek-ai/deepseek-harness/tree/main/packages/api/session-controller)、[Connection transport](https://github.com/deepseek-ai/deepseek-harness/tree/main/packages/client/connection)、[Gateway Remote stream](https://github.com/deepseek-ai/deepseek-harness/tree/main/packages/api/gateway)。Session 创建、列表、prompt、cancel 是 Host 的命名参数 RPC；`session/follow` 通过 `/api/remote.mux` WebSocket 流订阅。请勿把 [SDK stdio JSON-RPC](https://github.com/deepseek-ai/deepseek-harness/tree/main/packages/sdk/protocol) 与 Web Host RPC 混淆：前者会另启运行时且无法接入当前 GUI 会话。
