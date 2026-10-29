# emacs-dsh

English | [简体中文](README.zh-CN.md)

Development integration APIs: [enumerate and restore sessions](PUBLIC-API.md)
(including unverified Host contracts and current limitations).

An Emacs client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH), with an interaction style inspired by [pimacs.el](https://github.com/ananthakumaran/pimacs.el). Create and resume sessions, stream responses, switch models and reasoning effort, run slash commands and skills, manage queued prompts, complete file and cross-session references, and attach images. Authentication is automatic: no username, password, or manually pasted token is required.

## Connection modes

| Mode | When to use | Requirements | Host lifecycle |
| --- | --- | --- | --- |
| `auto` (default) | Reuse the Desktop Host if a bridge file is present; otherwise start a Web Host from Emacs | For Desktop, install [emacs-dsh-host-bridge](https://github.com/wowhxj/emacs-dsh-host-bridge); for the fallback, make the `dsh` CLI available | Follows the selected Host |
| `desktop` | Always reuse the DSH Desktop Host and its profile | Install and enable the separate Host bridge | Managed by Desktop; Emacs does not start the Host |
| `managed` | Always let Emacs start a local Web Host | The `dsh` CLI must run in Emacs's operating system | Starts on first use and stops when Emacs exits |

Both Host types connect only to local `127.0.0.1`. In automatic mode, the bridge file is the signal that Desktop is available: a present but invalid or broken bridge reports an error rather than silently starting a second Host. Managed mode runs `dsh web --host 127.0.0.1 --port 0 --no-open`, discovers its one-time URL, and exchanges it for a Host-signed cookie. Port `0` lets the OS choose an available port. The bridge and Emacs package are installed and updated separately. **The two Hosts have different profiles, so sessions, models, and skills may differ.**

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
| `M-x emacs-dsh-chat` or `<f7>` | Pick a directory, then choose an existing session in that directory to resume or select **New session**; if none exist, a new session is created directly. As with `/resume`, idle blank sessions are archived and hidden from this list. New sessions join the Host workspace for that directory (created if needed), so DSH Desktop lists them under that folder instead of **Ungrouped**. New sessions use **Standard** mode by default; use `C-u M-x emacs-dsh-chat` to choose another agent mode |
| `C-c C-r` or `/resume` | Archive idle, explicitly blank sessions before listing, then search remaining sessions across all workspaces returned by the Host in the minibuffer (Vertico/Orderless supported); entries show last-activity time newest-first, an ID and directory shortened in the middle to retain both ends, and as much of the first prompt as the window allows. Sessions with unknown status or an open Emacs chat buffer are kept. Archiving is reversible from the Host. Resuming closes the old chat buffer, after confirmation if it has an unsent draft |
| `C-c C-t` / `C-c C-j` | Enter transcript copy mode / return to the composer (semi-char mode) |
| `M-p` / `M-n` | Navigate the current session's prompt history; moving forward past the newest prompt restores the unsent draft |
| `RET` or `C-c C-c` | Send the draft |
| `Shift-Enter` | Insert a newline in the composer without sending |
| `C-c C-s` / `C-c C-k` | Steer a running turn / cancel it |
| `C-c C-l` / `C-c C-u` or `/queue` | Open the queue panel; `M-↑` stages promotion of a follow-up to Steering; `x` applies changes |
| `C-c C-q` | Close the Emacs chat buffer without deleting the Host session |
| `/mode` or `M-x emacs-dsh-select-mode` | Select an agent preset **before any conversation begins** (Standard, PTC, Minimal, or Creator, as offered by the Host) |
| `M-x emacs-dsh-permission` or `/permission <preset>` | Select permissions: read-only, workspace-write, full access, or Auto review (`auto`) if offered by the Host |
| `TAB` | Complete `/` commands and skills, `@` files/directories, or `@session` session references separately. `@~/sandbox/` and absolute paths also work outside the project |
| `C-c C-i` / `C-c C-b` | Focus input / switch active chats |
| `C-c C-o` | Open a history image or staged attachment in the system default viewer |
| `C-c C-p`, `s-v`, or `s-V` | Smart-paste text, file references, or images |

Composer background padding is only visual: it does not add spaces to your draft. `C-e` moves directly to the end of the current input line.

The first top row shows context-token usage (when supplied by the Host), model, reasoning effort, agent mode, and the current permission preset (for example, `auto`) from the Host. It updates when permissions change and restores the current value when a session is resumed. The second row pins the prompt for the current task (or the most recently completed task); submitting or editing a queued prompt does not replace it. Long prompts are shortened to one line so they stay visible while the transcript scrolls. During a turn, the top-level `Process` is expanded and individual tools and Thinking details stay collapsed; manual choices survive updates. At completion, all details collapse again and the intermediate steps fold into a single `Process` row showing the total duration and step count (for example, `▸ Process · 8m 37s · 12 steps`), followed directly by the final response; a turn that fails before replying folds the same way. Your prompt is never folded. Move to the heading and press `RET`, `TAB`, or click to expand or collapse it. New sessions default to `auto` permission, falling back to `danger-full-access` when the Host does not offer `auto`; customize `emacs-dsh-default-permission` if needed. The ordinary Emacs mode line names chat buffers after their working directory (numbering multiple chats with the same directory) and shows idle/thinking/tool/waiting state and queue counts (`[S1 F2]`: `S` for steer, `F` for follow-up). The latest user prompt remains in the transcript. New sessions read the Host's default model; `/model` chooses a model and `/reasoning` selects the supported effort. `/help` lists local and Host commands. Other Host commands are discovered via `commands/list` and executed by the Host. Registered `/skill-name` commands are submitted as prompts.

User and assistant messages use Emacs's `markdown-mode` styling for headings, emphasis, code, and links while hiding some Markdown punctuation. The original text remains in the buffer for searching and copying. Open HTTP(S) links in assistant messages with `RET` or a click. Streaming replies display lightweight text first, then receive formatting on completion. Whitespace-only assistant messages do not create empty `DSH:` rows, and excess blank lines at the boundaries of a reply are omitted from display; internal paragraphs, code indentation and the raw `/copy` text remain intact. Each step of a running task is one collapsed line: tool calls show status and a parameter summary (`●` running, `✓` succeeded, `✗` failed), and reasoning shows as `✻ Thinking` with its title (set `emacs-dsh-show-reasoning` to nil to hide it). Press `RET`, `TAB`, or click a step to expand or collapse its full arguments, results, or reasoning.

Type `@` then `TAB` to list the current chat project's files and directories directly from the local filesystem; an empty directory is reported with its path. Typed paths can still use Host candidates or the local fallback. Use `@session` then `TAB` for cross-session references, displayed in aligned title, directory and shortened-ID columns. File and directory candidates are annotated separately. `RET` inserts the selected directory, and another `TAB` browses its children. Path completion inherits your completion styles (including Orderless), ignores case even with smart-case enabled, and leaves global settings unchanged. If the Host has no candidates for a typed path, local workspace files are offered; explicit home-relative and absolute paths also work outside the project. Nested directory navigation requires filesystem access from Emacs. Session references insert the Host-provided `@[title](dsh-session:…)` mention. `M-x emacs-dsh-insert-file` inserts a reference manually; `M-x emacs-dsh-attach-image` stages an image. Staged previews are navigable buffer text: click or move to a thumbnail/name, then press `C-c C-o` to open that image in the system viewer. Only the adjacent **×** removes it. Submitted images disappear from the composer immediately; request failures restore them alongside the unsent draft. Preview positions follow the actual widget field, so live history and later submissions cannot move them below `You>` or absorb them into the draft. Smart paste uses the Windows clipboard in WSL and the native clipboard on macOS.

`/help` and slash completion share a deduplicated catalog of local commands, Host commands (`commands/list`), and registered skills. Host commands keep their native DSH semantics; Pi-only commands are not sent as ordinary prompts. `/compact` takes **no arguments** in DSH, requires idle with no staged images, clears the input immediately, and shows `compacting` while pending. A rejected request restores the command alongside any newer draft. Tool argument details decode JSON Unicode escapes for display without changing wire content.

Client session commands include `/name [title]` (rename; omit the title to open a picker), `/session` (metadata), `/copy` (latest loaded assistant answer as Markdown), and `/quit` (close the chat). `/export` uses the existing Host ZIP workflow. `/fork [event-seq]` uses `session/fork`, defaulting to the latest completed turn; `/clone` uses the same API with the latest **received** event sequence, not an atomic snapshot of future Host events. Both require idle with no staged images or active queue rewrite and open a separate chat while retaining the source. These are client equivalents, not claims that DSH exposes every Pi CLI command.

`C-c C-l` or `C-c C-u` (or `/queue`) opens an independent queue panel. Use `n`/`p` to navigate messages, `RET` to open a text editor, `C-c C-c` to stage the edit, or `C-c C-k` to discard it. In the panel, `d` stages deletion; `M-↑` stages promotion of a follow-up into the running turn, and `x` applies changes. `M-↓` remains unavailable because DSH cannot sort items or convert a steer back to a follow-up. `g` discards unapplied changes and refreshes; `q` destroys the panel and its editor without touching the chat draft. The panel follows live inbox projections when clean and refuses to apply if the queue changed while editing. DSH's native API supports text edits, deletion and steer only; sorting, conversion back to follow-up and image editing are unavailable. Image messages can be previewed and opened, but must be removed and resubmitted to change them. Operations may partially succeed; remaining changes are retained on failure without automatic retries.

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

## Interaction consistency with emacs-pi

See [UI consistency record](docs/UI-CONSISTENCY.md) for the requirement audit and backend differences. Historical user messages use the current theme warning color as a full-line background, distinguishing turns without horizontal separators; the composer retains widget-field styling. Chats fill the selected frame, and `C-c C-q` destroys the chat and associated queue buffers. The `@` path picker and `@session` picker are separate; path completion dynamically navigates nested directories and works with native completion or Vertico/Orderless, and preserves text after the completed token.
