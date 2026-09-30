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
| @ 和 / 用 minibuffer，兼容 Orderless/Vertico | 保留 completing-read，补充原生 substring 匹配，不要求安装补全框架 |
| @ 引用其他 session | 保留 Host 返回的 canonical dsh-session mention 和服务器解析 |
| ~/sandbox 和多层目录像 C-x C-f 一样深入补全 | @ picker 改为动态 collection，显式捕获聊天 root；minibuffer 变目录时重扫本地目录，隐藏 session 项；保留补全 token 后的草稿 |
| queue 可编辑消息 | 新增独立列表和文本编辑 buffer，暂存后应用；保留原先 minibuffer/composer 编辑入口作为兼容命令 |
| queue 调整顺序、steer/follow-up 双向转换 | 支持转为 steer；排序和降回 follow-up 无 DSH 原生接口，窗口明确说明，按对应键给可操作错误 |
| queue 显示图片、编辑图片 | 支持历史式预览和 C-c C-o；图片编辑不受 DSH 接口支持，明确提示删除后重新发送 |
| mode-line 显示两类 queue 数量 | 改为与 Pi 一致的 `[S1 F2]`，空队列不显示 |
| queue 的 q 必须销毁 buffer，不能阻塞后续输入 | q 销毁列表与编辑 buffer；队列编辑不使用聊天 composer，不设置阻塞普通 prompt 的全局编辑状态 |
| queue 写回失败不能一直提示 rewriting | 写回失败释放 applying 状态，保留未完成修改；队列快照变更时拒绝应用，避免修改已经消费的消息 |
| /reload | DSH 的服务端命令由 commands/list 发现；未新增虚假的 Pi 进程重启语义，未知命令保留草稿 |
| 图片粘贴 | 保留 macOS/WSL 图片、文件和文本粘贴实现；没有更改 Pi 或用户 Emacs 配置 |
| 输入区和历史显示图片缩略图 | 保留已有缩略图；历史原始内容或附件 ID 现在也可用于查看命令，终端可以按 ID 请求原图 |
| 输入区图片点击删除 | 保留按图片索引删除，只影响对应待发送附件 |
| 输入和历史图片 C-c C-o 放大查看，最终改用外部默认程序 | 新增统一查看命令：历史原图、Host 附件读取、多张待发送图片选择、系统默认查看器、临时文件退出清理 |

## 有意保留的后端差异

- DSH 通过 Host 的 session/updateQueue 按持久 item ID 更新；Pi 用 clear_queue 加逐条重发。此处采用 DSH 原生修改，应用前核对本地权威 inbox 快照；运行中仍可能被消费，服务端可拒绝后续操作，不能保证批量原子性。
- 本机 DSH 的 QueueAction 类型明确只有 edit（TextBlock[]）、remove、steer。排序、降为 follow-up、图片修改需要上游扩展；未通过删除和重发模拟这些操作，以免改变正在执行任务的队列语义。
- DSH 的 C-c C-k 保留取消当前轮次、待发队列仍保留的既有语义；Pi 的 stop 会 clear_queue 后 abort。DSH 当前没有批量清队列接口，本次没有把取消伪装成清空。
- DSH 的 @session 使用 Host 解析，Pi 使用本地 JSONL 当前分支上下文。两者显示简短引用，内部来源不同。
- Pi 的 /reload 重启单个 RPC 进程；DSH 复用共享 Host，客户端不能按此语义重启。DSH 可用命令以 Host 的实际目录为准。
- DSH 的 contextPressure 与 Pi 的 contextUsage 字段不同，沿用各自报告的指标，不把累计 token 当作当前上下文。

## 验证记录

- 修改前：97 项 ERT，96 通过，1 项 Windows DPAPI 集成测试在 macOS 跳过。
- 修改后：107 项 ERT，106 通过，0 失败，1 项同上跳过。
- 新增测试覆盖运行中折叠选择与完成重置、steer 用户消息可见、主题背景、C-a/状态转义、多层 minibuffer 补全和草稿尾部、终端附件读取、系统图片查看文件与清理、队列独立编辑/应用、变化快照拒绝与退出清理。
- source check-parens 与字节编译通过；调用 elisp-checker 的全部阶段。严格 elisp-lint 仍报告风格诊断（包括既有的 70 列、缩进、旧函数缺 docstring，以及部分新增代码的行宽），不能将 checker 的退出 0 / OK 当作 lint 全通过。
- 本机 GUI fixture 已检查历史高亮、输入区灰色、已完成折叠、运行中展开与紧凑步骤、context/model/status、C-a、输入 i、独立队列窗口与草稿保留、待发送图片缩略图、C-c C-q 销毁测试 buffer 并恢复原聊天。
- 未调用真实模型或修改 Host 持久会话；新队列窗口的真实 Host 往返、macOS 图片查看器启动、跨平台剪贴板仍需实际使用验证。系统查看器启动目前通过 stub 检查传参、字节内容与临时文件清理。
