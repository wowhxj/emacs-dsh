# emacs-dsh

English | [简体中文](README.zh-CN.md)

An Emacs client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH), with an interaction style inspired by [pimacs.el](https://github.com/ananthakumaran/pimacs.el). Create and resume sessions, stream responses, switch models and reasoning effort, run slash commands and skills, manage queued prompts, complete file and cross-session references, and attach images. Authentication is automatic: no username, password, or manually pasted token is required.

## Connection modes

| Mode | When to use | Requirements | Host lifecycle |
| --- | --- | --- | --- |
| `auto` (default) | Reuse the Desktop Host if a bridge file is present; otherwise start a Web Host from Emacs | For Desktop, install [emacs-dsh-host-bridge](https://github.com/wowhxj/emacs-dsh-host-bridge); for the fallback, make the `dsh` CLI available | Follows the selected Host |
| `desktop` | Always reuse the DSH Desktop Host and its profile | Install and enable the separate Host bridge | Managed by Desktop; Emacs does not start the Host |
| `managed` | Always let Emacs start a local Web Host | The `dsh` CLI must run in Emacs's operating system | Starts on first use and stops when Emacs exits |

Both modes connect only to local `127.0.0.1`. In automatic mode, the bridge file is the signal that Desktop is available: a present but invalid or broken bridge reports an error rather than silently starting a second Host. Managed mode runs `dsh web --host 127.0.0.1 --port 0 --no-open`, discovers its one-time URL, and exchanges it for a Host-signed cookie. Port `0` lets the OS choose an available port. The bridge and Emacs package are installed and updated separately. **The two Hosts have different profiles, so sessions, models, and skills may differ.**

## Installation

Requires Emacs 29.1+ and an available DSH Host. `websocket.el` and `markdown-mode` are declared in `Package-Requires` and installed automatically by a package manager; if you load the source directly, put both dependencies on your `load-path`.

After installing this repository with your Emacs package manager, you can use:

```elisp
(use-package emacs-dsh
  :commands (emacs-dsh-chat emacs-dsh-resume emacs-dsh-connect)
  :bind ("<f7>" . emacs-dsh-chat))
```

`C-c C-r`, `C-c C-l`, and the other chat shortcuts are local to `emacs-dsh-chat-mode`. They are defined in the shared `emacs-dsh-mode-map` and also work in the composer; they do not reserve global keys.

For source development you can set `:load-path "/absolute/path/to/emacs-dsh"`. Recompile or remove a stale `emacs-dsh.elc` when loading the source directly, or Emacs may load the older implementation.

### Managed Host (without a bridge)

Make sure `dsh web --help` works **on the OS running Emacs**, and configure a model in that DSH profile. Without a bridge file, `M-x emacs-dsh-chat` starts a local Host automatically; you do not need to open DSH Desktop. If GUI Emacs cannot find the CLI on its `PATH`, specify the executable:

```elisp
(setq emacs-dsh-managed-command "/absolute/path/to/dsh")
```

WSL Emacs launches the **Linux `dsh` inside WSL** and passes Linux paths to that Host. macOS Emacs launches the macOS CLI. The managed Host exits with its Emacs process; saved sessions remain in the DSH profile and are available after it starts again.

### Optional: connect to DSH Desktop

Install `github:wowhxj/emacs-dsh-host-bridge` from **Plugins → Install** in DSH Desktop, enable it, and restart the App/Host as directed. See the [separate bridge repository](https://github.com/wowhxj/emacs-dsh-host-bridge) for setup and troubleshooting. The default `auto` mode prefers the bridge when available. To require Desktop explicitly:

```elisp
(setq emacs-dsh-connection-mode 'desktop)
```

The bridge file is at `~/.dsh/emacs-dsh-bridge.json` on macOS, or `%USERPROFILE%\.dsh\emacs-dsh-bridge.json` on Windows; a custom `DSH_HOME` changes the corresponding location. **Never print, share, or commit this file: it contains authentication credentials.** On macOS, make sure your DSH home is accessible only to your user: `chmod 700 "${DSH_HOME:-$HOME/.dsh}"`. The Windows bridge protects credentials with the current user's DPAPI; WSL Emacs decrypts them with `powershell.exe`.

When using Windows Desktop with WSL Emacs, choose a new-session directory that the Windows Host can reach, such as `/mnt/d/project/`; the client converts paths with `wslpath`. Native macOS needs no conversion. The Desktop Host must be running, but its window need not remain visible.

## Usage

| Action | Description |
| --- | --- |
| `M-x emacs-dsh-chat` or `<f7>` | Pick a directory, then choose an existing session in that directory to resume or select **New session**; if none exist, a new session is created directly. New sessions use **Standard** mode by default; use `C-u M-x emacs-dsh-chat` to choose another agent mode |
| `C-c C-r` or `/resume` | Archive idle, explicitly blank sessions before listing, then search remaining sessions across all workspaces returned by the Host in the minibuffer (Vertico/Orderless supported); entries show creation time, a shortened ID, a capped directory path, and as much of the first prompt as the window allows. Sessions with unknown status or an open Emacs chat buffer are kept. Archiving is reversible from the Host. Resuming closes the old chat buffer, after confirmation if it has an unsent draft |
| `i` (outside the composer) | Jump to the end of the draft; typing `i` inside the composer inserts text normally |
| `M-p` / `M-n` | Navigate the current session's prompt history; moving forward past the newest prompt restores the unsent draft |
| `RET` or `C-c C-c` | Send the draft |
| `Shift-Enter` | Insert a newline in the composer without sending |
| `C-c C-s` / `C-c C-k` | Steer a running turn / cancel it |
| `C-c C-l` or `/queue` | Manage pending and steer messages: edit text and add/remove images in the chat composer, remove messages, or turn a queued message into a steer |
| `C-c C-q` | Close the Emacs chat buffer without deleting the Host session |
| `/mode` or `M-x emacs-dsh-select-mode` | Select an agent preset **before any conversation begins** (Standard, PTC, Minimal, or Creator, as offered by the Host) |
| `M-x emacs-dsh-permission` or `/permission <preset>` | Select permissions: read-only, workspace-write, full access, or Auto review (`auto`) if offered by the Host |
| `TAB` | Complete slash commands, skills, workspace files, and cross-session `@` references. `@~/sandbox/` or `@/absolute/path/` completes files and directories outside the project |
| `C-c C-p`, `s-v`, or `s-V` | Smart-paste text, file references, or images |

Composer background padding is only visual: it does not add spaces to your draft. `C-e` moves directly to the end of the current input line.

The first top row shows context-token usage (when supplied by the Host), model, reasoning effort, agent mode, and the current permission preset (for example, `permission: auto`) from the Host. It updates when permissions change and restores the current value when a session is resumed. The second row pins the prompt for the current task (or the most recently completed task); submitting or editing a queued prompt does not replace it. Long prompts are shortened to one line so they stay visible while the transcript scrolls. Once a final response arrives, intermediate steps such as tool calls fold into a single `Process` row; move to its heading and press `RET` or click to expand or collapse it. New sessions default to `auto` permission, falling back to `danger-full-access` when the Host does not offer `auto`; customize `emacs-dsh-default-permission` if needed. The ordinary Emacs mode line names chat buffers after their working directory (numbering multiple chats with the same directory) and shows idle/thinking/tool/waiting state and queue counts (`Q` for queued, `S` for steer). The latest user prompt remains in the transcript. New sessions read the Host's default model; `/model` chooses a model and `/reasoning` selects the supported effort. `/help` lists local and Host commands. Other Host commands are discovered via `commands/list` and executed by the Host. Registered `/skill-name` commands are submitted as prompts.

Assistant messages use Emacs's `markdown-mode` styling for headings, emphasis, code, and links while hiding some Markdown punctuation. The original text remains in the buffer for searching and copying. Open HTTP(S) links with `RET` or a click. Streaming replies display lightweight text first, then receive formatting on completion. Tool calls appear as cards with status and a parameter summary: `●` running, `✓` succeeded, `✗` failed. Press `RET` or click the card heading to expand or collapse complete arguments and results.

Type `@` then `TAB` to select Host files or other sessions. If the Host has no file candidates, local files and subdirectories under the current working directory are offered. Explicit home-relative and absolute paths are completed from the local filesystem, even outside the project. Cross-session references insert the Host-provided `@[title](dsh-session:…)` mention. `M-x emacs-dsh-insert-file` inserts a reference manually; `M-x emacs-dsh-attach-image` stages an image. Staged images appear above the composer as thumbnails in graphical Emacs; click a preview to remove it. Smart paste uses the Windows clipboard in WSL and the native clipboard on macOS.

`C-c C-l` (or `/queue`) shows messages that the Host has not consumed. Select **Edit** to load its text and image previews into the chat composer rather than the minibuffer. Paste or attach new images, click existing previews to remove them, then press `C-c C-c` or `RET` to save; `C-c C-k` aborts and restores your original draft and attachments. You can also delete the entire message or turn a pending message into a steer for the current turn (only while the agent is running). Queue state comes from the Host's live `session/control` → `inbox` projection and is reloaded after reconnecting.

History is saved by the Host. `/resume` searches all visible sessions from `session/list` without requesting snapshots for each result. Entering a session loads its latest `emacs-dsh-max-messages` messages, then receives live WebSocket events with reconnection support. Pagination of older **messages** is not implemented yet. Images included by the Host appear in graphical Emacs; text terminals show `[image]` instead.

When the Host requests approval or asks a question, the client receives `$events` and handles them in the minibuffer, one at a time. Approvals can be rejected or allowed once; questions support choices, comma-separated multiple choices, free text, and an empty answer to skip. `C-g` cancels the question group. After closing the chat buffer, this client no longer handles that session's requests; another DSH client can still handle them. Agent modes can only be switched before a conversation has started; create a new session to choose another mode later.

## Troubleshooting

- **Cannot find `dsh`**: Auto mode did not find a bridge and tried to launch a local Host. Install/configure the CLI on the OS running Emacs or set `emacs-dsh-managed-command` to an absolute path. To reuse Desktop, enable the separate bridge and ensure it created the bridge file.
- **Managed Host times out or exits**: Run `dsh web --host 127.0.0.1 --port 0 --no-open` manually on the Emacs OS to check CLI/profile errors. Do not share the token URL it prints.
- **Desktop bridge missing**: Check that the separate plugin is installed in Desktop's current profile, enabled, and restarted. On macOS, use `ls -ld ~/.dsh ~/.dsh/emacs-dsh-bridge.json` to inspect file existence and permissions; do not display its contents. Set `emacs-dsh-bridge-file` for a custom path.
- **HTTP 401/403**: A 401 triggers another cookie exchange. For repeated failures, check whether the Host restarted or the bridge points at the wrong Host. For 403, inspect Host/Origin configuration.
- **Paths, `@` references, or skills unavailable**: Ensure the Host in the current mode can access the project directory and has skills configured in its profile. The client queries `skills/list` for discovered skills.

`M-x emacs-dsh-connect` manually checks the connection and reauthenticates; it is not required for ordinary chat.

## Development and tests

Put this repository and installed `websocket.el` and `markdown-mode` on `load-path`, then run:

```sh
emacs -Q --batch -L /path/to/websocket-el -L /path/to/markdown-mode -L . -f batch-byte-compile emacs-dsh.el
emacs -Q --batch -L /path/to/websocket-el -L /path/to/markdown-mode -L . -l emacs-dsh.el -l tests.el -f ert-run-tests-batch-and-exit
```

Emacs regression tests can run on Windows/WSL; unit tests cover macOS clipboard and path logic, while queue and reference logic does not depend on WSL path utilities. Actual end-to-end behavior with the Desktop Host should still be checked on macOS. The Host bridge has its own test and release process.

Protocol references: [Session Controller](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/session-controller), [Connection](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client/connection), and [API Gateway](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/gateway).
