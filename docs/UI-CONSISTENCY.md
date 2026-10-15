# emacs-pi / emacs-dsh UI 一致性记录

核对日期：2026-09-30。参考本机 emacs-pi 0.3.4 的实现，以及项目聊天「规划 Emacs Pi Agent 插件」的全部可访问用户消息（2026-09-29）。本机 Codex 活动和归档 session 检索只找到该项目这一份对话；未发现同目录的 Claude Code 项目记录。后续修正优先，例如 warning 高亮只用于历史，不用于输入区，图片查看使用系统默认程序。

2026-09-30 后续调整：历史用户消息已有 warning 整行高亮，移除回合之间的横向分隔线，保留普通留白。

参考源码：emacs-pi-ui.el、emacs-pi-input.el、emacs-pi-queue.el、emacs-pi-history.el、emacs-pi.el，并核对 README、CHANGELOG、docs/DESIGN.md、docs/QUEUE.md 和验收文档。emacs-pi 原先从 emacs-dsh 迁移了不少 UI，本次将其中后续改进同步回 DSH，保留各自后端。

## 逐项需求对应

| 对话中提出的需求 | emacs-dsh 处理 |
| --- | --- |
| 选择长期维护的 Pi 插件方案、形成详细设计、实现可体验版本 | 属于 emacs-pi 的项目交付，本次以完成后的实现为 UI 基准 |
| mode-line 显示正在进行的状态 | 保留 idle/thinking/tool/waiting 和 spinner；动态文本压平换行并转义 `%` |
| 输入区有明确底色 | 保留灰色 widget-field，不使用 warning 背景 |
| 历史区按 i 聚焦到 prompt 末尾 | 保留；增加与 Pi 一致的 `C-c C-i` |
| C-a 停在 You> 后可编辑位置 | 增加显式共享绑定，多行输入的后续行仍停在普通行首 |
| 只能在 prompt 输入，历史只读 | 保留 widget 和历史 read-only 保护，回归验证 |
| 历史用户消息整行 warning 高亮；撤销输入区 warning | 改为当前主题 warning 颜色的整行背景和有对比度的文字；输入区保持原样 |
| F6/F7 选目录后选已有 session 或新建 | 保留原先目录内会话选择；快捷键仍由用户配置，不占用全局按键 |
| 打开聊天后占满编辑区域，避免每次 C-x 1 | 新建、恢复和切换活动聊天时删除其他窗口 |
| C-c C-r 会话列表含更多信息，更易读 | 保留时间、缩短 ID、目录、prompt、按时间排序与宽度限制 |
| 顶部 context 已用/总长度 | 保留 DSH contextPressure，缺值显示 context: —；模型与推理信息右对齐 |
| 每步折叠、步骤之间无多余空行 | 工具/Thinking 详情默认折叠，去除步骤详情尾部额外空行 |
| 运行中 Process 展开，子项折叠；完成后全部收起 | 新增运行中顶层 Process，保留手动切换；结束时重置整体和详情折叠，最终回答与所有用户消息保持可见 |
| 步骤内容对齐 | DSH 的步骤统一从同一缩进列开始，详情继续缩进；保留 DSH: 助手标签 |
| C-c C-q 后 buffer 不残留 | 保留 kill-buffer，并清理该聊天的队列与编辑 buffer |
| @ 和 / 用 minibuffer，兼容 Orderless/Vertico | 保留 completing-read；路径类别显式继承当前 completion-styles，不要求安装补全框架 |
| @ 引用其他 session | 保留 Host 返回的 canonical dsh-session mention 和服务器解析 |
| ~/sandbox 和多层目录像 C-x C-f 一样深入补全 | @ picker 使用动态 collection 和聊天 root；从完整 minibuffer 输入确定本地目录，保留目录精确候选；RET 插入目录，后续 TAB 浏览子项；session 使用独立入口 |
| queue 可编辑消息 | 新增独立列表和文本编辑 buffer，暂存后应用；保留原先 minibuffer/composer 编辑入口作为兼容命令 |
| queue 调整顺序、steer/follow-up 双向转换 | 支持转为 steer；排序和降回 follow-up 无 DSH 原生接口，窗口明确说明，按对应键给可操作错误 |
| queue 显示图片、编辑图片 | 支持历史式预览和 C-c C-o；图片编辑不受 DSH 接口支持，明确提示删除后重新发送 |
| mode-line 显示两类 queue 数量 | 改为与 Pi 一致的 `[S1 F2]`，空队列不显示 |
| queue 的 q 必须销毁 buffer，不能阻塞后续输入 | q 销毁列表与编辑 buffer；队列编辑不使用聊天 composer，不设置阻塞普通 prompt 的全局编辑状态 |
| queue 写回失败不能一直提示 rewriting | 写回失败释放 applying 状态，保留未完成修改；队列快照变更时拒绝应用，避免修改已经消费的消息 |
| /reload | DSH 的服务端命令由 commands/list 发现；未新增虚假的 Pi 进程重启语义，未知命令保留草稿 |
| 图片粘贴 | 保留 macOS/WSL 图片、文件和文本粘贴实现；没有更改 Pi 或用户 Emacs 配置 |
| 输入区和历史显示图片缩略图 | 保留已有缩略图；历史原始内容或附件 ID 现在也可用于查看命令，终端可以按 ID 请求原图 |
| 输入区图片点击删除（被后续需求取代） | 仅 × 控件按索引删除；图片/名称是可导航的只读文本，点击定位不会删除 |
| 输入和历史图片 C-c C-o 放大查看，最终改用外部默认程序 | 新增统一查看命令：历史原图、Host 附件读取、多张待发送图片选择、系统默认查看器、临时文件退出清理 |

## 指定聊天记录的补充核对

本轮逐项对照 Pi session `01a0ec32-0fbb-706d-8c3f-99924549b86e` 的用户要求（以末尾用户确认的修复为准，忽略记录中滞后的压缩摘要）。

| 需求 | 本轮前状态 | 本轮实现/验证 |
| --- | --- | --- |
| `@` 只补文件/目录，`@session` 单独补会话 | 缺失，仍混合候选 | 分离两条 API 路径，保留 Host canonical session mention |
| 目录 RET 上屏，不自动进入下一级 | 无独立类别保护 | 使用 `emacs-dsh-file`，不触发 Vertico 的 file 类别导航 |
| 目录选择不出现 Match Required | 动态列表不保留目录本身 | 保留本地有效目录和已提供的 Host 目录精确候选 |
| Orderless 多词筛选完整外部路径 | 候选生成使用匹配器传入的短前缀 | 使用完整 minibuffer 输入选择目录，实测 Orderless 外部路径多词匹配 |
| 大小写不敏感（包括大写输入） | 未显式关闭 smart-case | 局部 ignore-case + 关闭 Orderless smart-case；不改变全局配置 |
| `/compact` 及参数/忙碌/附件/草稿保护 | 已走 Host commands/execute，但草稿等完成才清空 | 无参数、空闲/附件保护、即时清空、compacting 状态；失败与未知 Host 命令恢复草稿，新草稿不会被成功回调清空 |
| CLI/插件命令、帮助、补全一致 | Host 原生命令已动态发现，帮助列表仍手写且未列技能 | 共用去重命令目录；本地入口优先，Host 原生指令与技能保持现有派发，不把未知指令作为普通 prompt |
| `/name`、`/session`、`/copy`、`/quit` | 缺少 slash 入口（关闭已有快捷键） | 新增 rename API、会话元数据、最近已加载助手 Markdown 复制、关闭聊天入口 |
| `/export` | 已有 | 保留 Host ZIP 导出与原有二进制/认证回归 |
| `/fork`、`/clone` | 缺失 | 使用原生 session/fork；默认完成回合/显式事件序号/最新已接收前缀；拒绝忙碌、附件和队列写回并发 |
| context/工具参数展开中文乱码 | HTTP/WebSocket 传输已使用 UTF-8；工具参数原样显示 JSON | 解码 JSON Unicode 转义只用于显示，非法 JSON 保留原文，false/null 保真 |
| 粘贴图片点击不应删除，可移动光标后 C-c C-o | 查看器已有；预览是 overlay before-string，整项绑定删除 | 改为可导航 buffer 文本，名称/缩略图按 C-c C-o 查看对应附件；仅 × 删除 |
| commit/push、同步用户 runtime | 属于交付动作，而非插件功能 | 按用户后续明确请求提交、推送并同步安装 checkout；不修改用户 init 配置或模型设置 |

新增命令不伪装 Pi 专属协议：DSH `/compact` 不接受自定义指令；`/export` 是 ZIP，不是 Pi HTML；`/fork [事件序号]` 与 Pi 的输入条目选择器不同；`/clone` 复制收到的日志前缀，不承诺包含随后产生的 Host 事件。`/tree`、`/settings`、`/share` 等不做虚假的 Pi API 映射；如 DSH Host 自己注册命令，会由原生命令目录发现。

## 截图反馈后的修正

- `@session` 候选接口提供 `cwd`，原先客户端只显示标题与完整 ID。现在按显示列宽（而不是字符数）对齐标题、目录、短 ID，长路径保留首尾，保留 Host 的工作目录优先排序及 canonical mention。
- 裸 `@` 优先枚举当前聊天的本地项目目录，不依赖 Host 的索引/过滤结果；已输入路径片段时仍保留 Host 查询。用户确认截图中的项目为 `~/sandbox/dsh/`，检查时此目录为空；空目录不能产生不存在的文件候选，改为明确显示项目路径。不会悄悄补全 `emacs-dsh` 或已安装的 DSH 源码目录。
- DSH Host 的目录候选可能是 `kind: directory, path: docs`，没有末尾 `/`；客户端现在统一补上目录后缀，注解与后续 TAB 浏览保持一致。
- 某些模型的工具调用前后含纯空白 text block，旧渲染器只检查长度非零，导致显示空 `DSH:` 和成片换行。现过滤纯空白消息、移除回复边界空行，保留正文内部空行和代码缩进；`/copy` 仍使用原始文本，不改模型设置或 Host 日志。
- 已补 6 个回归，其中 5 个先确认失败再实现修复；新增用例分别覆盖 session 列对齐、裸 @ 本地优先、空目录诊断、Host 目录后缀、完整工具事件序列的紧凑显示和 Markdown/CRLF 保真。
- 已渲染的历史不会因 load-file 自动重排。保留未发送草稿后，关闭聊天 buffer 并重新恢复该会话，可用新渲染器重放历史；不会删除 Host 会话。
- 本轮源码和 `.elc` 版分别通过 130 项 ERT：129 通过、1 项 Windows DPAPI 测试跳过；严格字节编译、check-parens、diff 检查通过。elisp-checker 三阶段已执行，lint 仍有风格诊断，不宣称 lint 全通过。
- GUI Emacs 未开启 server，不能直接热加载或读取当前聊天 root；目录通过用户选择确认。修复验证阶段未修改 runtime、模型设置或持久 Host 会话；安装同步按后续明确交付请求单独执行。GUI 鼠标/Vertico 的实际显示仍待用户验证。

## 图片预览与输入区外观修正

- 旧预览清理后保留零宽 overlay，实时历史插入会使其与 `input-start` marker 失步；后续贴图/失败恢复按混合锚点删除文本，可导致越界、错误删除和预览位置异常。
- 现在清理使用预览 overlay 自己的完整范围，并立即销毁 overlay，附件为空时保持 nil；不再留下浮动的空预览区域。
- 草稿起点直接采用 `widget-field-start`；预览从真实字段前的 `You>` 前缀位置插入，与可编辑文本完全分离，实时历史仍插在整个输入区上方。不再将预览长度参与草稿位置计算。
- 提交即清除本次预览和附件；失败恢复时保留期间新增的文字、图片，成功回调也不会删除新草稿或新图片。已提交的历史图片仍保留。
- 输入 widget 和输入区底色 overlay 均局部设置 `:underline nil`，保留原有底色；不修改全局 `widget-field` face 或其他输入框。现有外观回归同时验证两处 face。
- 新增 5 项回归，其中 3 项先确认失败；覆盖提交后 overlay/text 清理、历史到达后再贴图、异步失败恢复、过期输入 marker 重新定位、成功回调保留新图片。旧用例同步改为断言无 overlay，而不是只检查 before-string。
- 验证：源码和严格字节编译后的完整 ERT 均为 136 项中 135 通过、1 项 Windows DPAPI 跳过；check-parens、严格编译、git diff --check 通过。checker 的 elisp-lint 仍报告已有的格式/checkdoc 风格问题，未视为 lint 全通过。
- 更新安装 runtime 后，已加载的旧定义仍需重新 load-file 或重启 Emacs，并建议保留草稿后重开会话，避免旧 buffer 的残留标记。不修改 Host 持久历史；GUI 未开启 Emacs server 时无法远程热加载，图形显示仍需人工确认。

## 有意保留的后端差异

- DSH 通过 Host 的 session/updateQueue 按持久 item ID 更新；Pi 用 clear_queue 加逐条重发。此处采用 DSH 原生修改，应用前核对本地权威 inbox 快照；运行中仍可能被消费，服务端可拒绝后续操作，不能保证批量原子性。
- 本机 DSH 的 QueueAction 类型明确只有 edit（TextBlock[]）、remove、steer。排序、降为 follow-up、图片修改需要上游扩展；未通过删除和重发模拟这些操作，以免改变正在执行任务的队列语义。
- DSH 的 C-c C-k 保留取消当前轮次、待发队列仍保留的既有语义；Pi 的 stop 会 clear_queue 后 abort。DSH 当前没有批量清队列接口，本次没有把取消伪装成清空。
- DSH 的 @session 使用 Host 解析，Pi 使用本地 JSONL 当前分支上下文。两者显示简短引用，内部来源不同。
- Pi 的 /reload 重启单个 RPC 进程；DSH 复用共享 Host，客户端不能按此语义重启。DSH 可用命令以 Host 的实际目录为准。
- DSH 的 contextPressure 与 Pi 的 contextUsage 字段不同，沿用各自报告的指标，不把累计 token 当作当前上下文。

## 本轮补充验证

- 源码与 `.elc` 编译版本分别运行全套 ERT：124 项，123 通过，0 失败；1 项 Windows DPAPI 集成测试在 macOS 跳过。Orderless 测试加载本机真实 Orderless 包执行，不是 stub，也未跳过。
- 生产源码和测试均通过 `check-parens`、`byte-compile-error-on-warn=t` 严格字节编译与 `git diff --check`。编译在临时目录完成，不更改仓库或 runtime 的 `.elc`。
- 已执行 elisp-checker 三个阶段；结构和编译通过，elisp-lint 仍报告行宽、缩进和 checkdoc 等风格诊断。脚本会在 lint FAIL 后输出 OK，不能将退出 0 当作风格检查通过。
- 新增 17 项测试并更新旧交互测试，覆盖独立入口、Host/本地目录精确匹配、真实 Orderless 多词/大小写、compact 成功/异步失败/同步失败/未知命令/新草稿、命令目录一致性、rename/fork/clone/copy/session/quit、UTF-8 字节、Unicode 显示、可导航图片与旧 overlay 迁移。
- 未调用真实模型、创建持久 Host 会话或启动外部图片查看器；GUI Vertico 目录 RET、图片鼠标定位、真实压缩/分叉仍需人工验收。本轮测试通过 mock Host API 与系统查看器验证请求、状态和数据；不等同于真实 Host 端到端测试。

## 前轮验证记录

- 修改前：97 项 ERT，96 通过，1 项 Windows DPAPI 集成测试在 macOS 跳过。
- 修改后：107 项 ERT，106 通过，0 失败，1 项同上跳过。
- 新增测试覆盖运行中折叠选择与完成重置、steer 用户消息可见、主题背景、C-a/状态转义、多层 minibuffer 补全和草稿尾部、终端附件读取、系统图片查看文件与清理、队列独立编辑/应用、变化快照拒绝与退出清理。
- source check-parens 与字节编译通过；调用 elisp-checker 的全部阶段。严格 elisp-lint 仍报告风格诊断（包括既有的 70 列、缩进、旧函数缺 docstring，以及部分新增代码的行宽），不能将 checker 的退出 0 / OK 当作 lint 全通过。
- 本机 GUI fixture 已检查历史高亮、输入区灰色、已完成折叠、运行中展开与紧凑步骤、context/model/status、C-a、输入 i、独立队列窗口与草稿保留、待发送图片缩略图、C-c C-q 销毁测试 buffer 并恢复原聊天。
- 未调用真实模型或修改 Host 持久会话；新队列窗口的真实 Host 往返、macOS 图片查看器启动、跨平台剪贴板仍需实际使用验证。系统查看器启动目前通过 stub 检查传参、字节内容与临时文件清理。
