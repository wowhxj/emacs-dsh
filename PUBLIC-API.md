# Public session APIs (development)

```elisp
(emacs-dsh-list-sessions
 (lambda (result) (message "%S" result))
 :on-error (lambda (error) (message "%s" error)))

(emacs-dsh-open-session
 "FULL-SESSION-ID" :directory "/absolute/project" :display 'none
 :on-ready (lambda (buffer) (pop-to-buffer buffer))
 :on-error (lambda (error) (message "%s" error)))
```

Both operations return a silent cancellation function. Cancellation stops
notifications/timers, not an already submitted HTTP request or a chat.
Callbacks terminate at most once and are bounded by a timeout.

Enumeration returns `(:source HOST-IDENTITY :items RAW-HOST-ITEMS)`.
Source is the authenticated base/nonce/mode tuple, never a bearer token.
The only data request is `session/list`. Enumeration does not use the
interactive picker, archive blanks, start a managed Host or subscribe to
chat history. A managed Host must already be owned and running; Desktop
uses its existing bridge. Authentication busy/unavailable/expired errors
are reported, not retried through the startup-capable call path. Missing
metadata remains unknown. A title is not a raw first-user-message.

Opening uses the configured connection lifecycle and exact session ID.
It does not archive, clean up, create a substitute session, or modify
approval parameters. Missing/remote local directories are rejected.
Readiness requires a follow snapshot carrying the exact ID and requested
Host cwd, plus an open socket. If the Host omits these fields, readiness
fails rather than assuming success. Changing buffer default-directory
is not used to claim that the Host changed a session's actual cwd.

Display supports `current`, `none`, or a `display-buffer` action. Existing
interactive commands retain their full-window default. Buffer reuse is
rejected across different authenticated Host generations. This is not a
multi-Host connection manager.

## Unverified contracts and remaining work

- The current Host version's server-side no-management-write guarantee for
  `session/list` has not been source-verified. Tests prove client endpoint
  selection/no startup, not server internals.
- Snapshot ID/cwd field availability and real selected-session recovery
  have not been tested against an actual Host.
- Source guarding is fail-closed across Host generations, but the existing
  global transport/event architecture is not fully isolated per profile.
- Further tests for timeout/cancel/concurrent auth and Host changes are
  required before declaring the ashub client phase complete.

## 中文摘要

新增只读枚举与指定 ID 恢复接口，均支持异步回调和取消通知。
枚举不启动 Host，不走会自动归档空会话的旧 resume picker。
新恢复接口不关闭其他窗口，必须验证实际快照身份与目录；缺字段则报错。
旧交互命令仍保留原有默认行为。

当前仅完成客户端侧基础实现和隔离测试；服务端只读保证、真实快照字段、
真实恢复和多来源连接竞态未验证，不能宣称完整验收，也不能自动安装或推送。
