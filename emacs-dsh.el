;;; emacs-dsh.el --- DeepSeek Harness sessions in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-dsh contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (websocket "1.15") (markdown-mode "2.3"))
;; Keywords: tools, processes, convenience
;; URL: https://github.com/wowhxj/emacs-dsh

;;; Commentary:
;; A client for DSH Web Host.  By default it prefers the local Desktop bridge
;; when present, otherwise Emacs starts its own Host.  See README.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-cookie)
(require 'project)
(require 'widget)
(require 'wid-edit)
(require 'websocket)
(require 'markdown-mode)
(require 'browse-url)

(defgroup emacs-dsh nil "Emacs client for DeepSeek Harness." :group 'tools)
(defface emacs-dsh-status-face
  '((t :inherit mode-line))
  "Face for the DSH mode-line status." :group 'emacs-dsh)
(defface emacs-dsh-user-face
  '((((class color) (background light)) :background "#edf5f4" :foreground "#244b48")
    (((class color) (background dark)) :background "#263b3b" :foreground "#d9ebe8")
    (t :inherit default))
  "Face for user messages." :group 'emacs-dsh)
(defface emacs-dsh-assistant-label-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the assistant label." :group 'emacs-dsh)
(defface emacs-dsh-tool-face
  '((((class color) (background light)) :background "#eef1f7" :foreground "#34445e")
    (((class color) (background dark)) :background "#2b3341" :foreground "#d5dfed")
    (t :inherit default))
  "Face for a tool call header." :group 'emacs-dsh)
(defface emacs-dsh-tool-success-face
  '((t :inherit success :weight bold))
  "Face for a successful tool status." :group 'emacs-dsh)
(defface emacs-dsh-tool-error-face
  '((t :inherit error :weight bold))
  "Face for a failed tool status." :group 'emacs-dsh)
(defface emacs-dsh-tool-detail-face
  '((t :inherit fixed-pitch :foreground "gray60"))
  "Face for expanded tool details." :group 'emacs-dsh)
(defcustom emacs-dsh-connection-mode 'auto
  "How Emacs connects to a local DSH Host.
`auto' prefers the local Desktop bridge file when present, otherwise starts
and owns a `dsh web' process.  This is the default.
`managed' starts and owns a `dsh web' process in Emacs's operating system.
`desktop' uses the separately installed Host bridge to join DSH Desktop."
  :type '(choice (const :tag "Prefer Desktop bridge, otherwise dsh web" auto)
                 (const :tag "Emacs-managed dsh web" managed)
                 (const :tag "Existing Desktop Host via bridge" desktop))
  :group 'emacs-dsh)
(defcustom emacs-dsh-managed-command "dsh"
  "Executable used to start the Emacs-managed DSH Web Host.
Set an absolute path if `dsh' is not on Emacs's PATH."
  :type 'string :group 'emacs-dsh)
(defcustom emacs-dsh-url "http://127.0.0.1:19387/"
  "URL of the current DSH Web Host, without its launch token.
The selected connection mode updates this after discovering its local Host.
Never put bearer credentials into version-controlled Emacs configuration."
  :type 'string :group 'emacs-dsh)
(defcustom emacs-dsh-bridge-file nil
  "Override local Host bridge file path; nil discovers it from DSH_HOME.
On WSL the Windows user's ~/.dsh file is located via powershell.exe."
  :type '(choice (const nil) file) :group 'emacs-dsh)
(defcustom emacs-dsh-wsl-path-function nil
  "Optional function converting Emacs paths to paths understood by the DSH Host.
In Desktop mode on WSL, nil uses `emacs-dsh-wsl-windows-path'.  In managed mode
and on macOS, nil sends paths unchanged."
  :type '(choice (const nil) function) :group 'emacs-dsh)
(defcustom emacs-dsh-max-messages 100
  "Number of messages in the first history snapshot."
  :type 'integer :group 'emacs-dsh)
(defcustom emacs-dsh-show-reasoning nil
  "Whether to display assistant reasoning blocks." :type 'boolean :group 'emacs-dsh)
(defcustom emacs-dsh-default-permission "auto"
  "Permission for newly created sessions; auto falls back to danger-full-access.
The fallback is used only when the Host does not offer auto."
  :type '(choice (const "auto") (const "danger-full-access")
                 (const "workspace-write") (const "read-only"))
  :group 'emacs-dsh)

(defvar emacs-dsh--chats (make-hash-table :test #'equal))
(defvar emacs-dsh--created-at (make-hash-table :test #'equal)
  "Creation times learned from Session follow snapshots, keyed by session ID.")
(defvar emacs-dsh--cookie-jar nil "Session-local Cookie header, never written to a file.")
(defvar emacs-dsh--authenticated-base nil "Host base associated with the current cookie.")
(defvar emacs-dsh--authenticated-nonce nil "Host generation for the current cookie.")
(defvar emacs-dsh--authenticated-mode nil "Connection mode for the current cookie.")
(defvar emacs-dsh--auth-waiters nil "Callbacks waiting for automatic authentication.")
(defvar emacs-dsh--auth-running nil "Non-nil while an authentication attempt is in progress.")
(defvar emacs-dsh--managed-process nil "DSH Web Host process owned by this Emacs.")
(defvar emacs-dsh--managed-connection nil "Current managed (base launch nonce) tuple.")
(defvar emacs-dsh--managed-output "" "Bounded startup output before a launch URL arrives.")
(defvar emacs-dsh--managed-waiters nil "Callbacks waiting for managed Host startup.")
(defvar emacs-dsh--managed-timer nil "Startup timeout for the managed Host.")
(defvar-local emacs-dsh--session-id nil)
(defvar-local emacs-dsh--root nil)
(defvar-local emacs-dsh--socket nil)
(defvar-local emacs-dsh--cursor -1)
(defvar-local emacs-dsh--seen nil)
(defvar-local emacs-dsh--pending nil)
(defvar-local emacs-dsh--attachments nil)
(defvar-local emacs-dsh--queue-edit nil)
(defvar-local emacs-dsh--attachment-overlay nil)
(defvar-local emacs-dsh--draft nil)
(defvar-local emacs-dsh--input-start nil)
(defvar-local emacs-dsh--input-background nil)
(defvar-local emacs-dsh--stream-overlay nil)
(defvar-local emacs-dsh--last-prompt nil)
(defvar-local emacs-dsh--task-turn-open nil)
(defvar-local emacs-dsh--task-next-turn-claimed nil)
(defvar-local emacs-dsh--task-first-step nil)
(defvar-local emacs-dsh--inbox-trace nil)
(defvar-local emacs-dsh--turn-start nil)
(defvar-local emacs-dsh--final-start nil)
(defvar-local emacs-dsh--turn-has-process nil)
(defvar-local emacs-dsh--prompt-history nil)
(defvar-local emacs-dsh--history-index nil)
(defvar-local emacs-dsh--history-draft nil)
(defvar-local emacs-dsh--running nil)
(defvar-local emacs-dsh--stream-text nil)
(defvar-local emacs-dsh--stream-id nil)
(defvar-local emacs-dsh--retry-timer nil)
(defvar-local emacs-dsh--closing nil)
(defvar-local emacs-dsh--command-inflight nil)
(defvar-local emacs-dsh--model-selection nil)
(defvar-local emacs-dsh--permission nil)
(defvar-local emacs-dsh--queue-items nil)
(defvar-local emacs-dsh--queue-seq -1)
(defvar-local emacs-dsh--queue-ready nil)
(defvar-local emacs-dsh--tool-cards nil)
(defvar-local emacs-dsh--tool-pending nil)
(defvar-local emacs-dsh--context-pressure nil)
(defvar-local emacs-dsh--agent-preset nil)
(defvar-local emacs-dsh--active-tools nil)
(defvar-local emacs-dsh--waiting nil)
(defvar-local emacs-dsh--spinner-timer nil)
(defvar emacs-dsh--events-socket nil "One host-wide $events connection for all chats.")
(defvar emacs-dsh--events-client nil)
(defvar emacs-dsh--events-queue nil)
(defvar emacs-dsh--events-active nil)
(defvar emacs-dsh--events-prompting nil)
(defvar emacs-dsh--events-cancelled nil)
(defvar emacs-dsh--events-retry nil)
(defvar-local emacs-dsh--spinner-index 0)
(defconst emacs-dsh--composer-prefix "\nYou> ")

(defun emacs-dsh--base ()
  (let ((url (url-generic-parse-url emacs-dsh-url)))
    (unless (and (member (url-type url) '("http" "https"))
                 (url-host url) (url-port url))
      (user-error "emacs-dsh-url must be a complete HTTP(S) URL with port"))
    (format "%s://%s:%d/" (url-type url) (url-host url) (url-port url))))

(defun emacs-dsh--url-retrieve (url callback)
  "Retrieve URL without storing Host cookies in Emacs's global cookie jar."
  (let ((buffer (url-retrieve url callback nil t)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local url-cookie-storage nil)
        (setq-local url-cookie-secure-storage nil)
        (setq-local url-cookie-file nil)))
    buffer))

(defun emacs-dsh--request (endpoint args callback)
  "Call DSH Remote ENDPOINT with named ARGS; pass result/error to CALLBACK.
CALLBACK receives (VALUE ERROR), exactly once.  Always execute it in the
buffer that initiated the call, if that buffer is still alive."
  (let* ((origin (current-buffer))
         (id (emacs-dsh--uuid))
         (url (concat (emacs-dsh--base) "api/" endpoint))
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json")
                    ("Authorization" . ""))
                  (and emacs-dsh--cookie-jar
                       (list (cons "Cookie" emacs-dsh--cookie-jar)))))
         (url-request-data (encode-coding-string
                            (json-serialize
                             `((type . "client-request") (rpcId . ,id)
                               (method . ,endpoint) (payload . ((args . ,args)))))
                            'utf-8)))
    (let ((url-proxy-services (cons '("no_proxy" . "127.0.0.1") url-proxy-services))
          (url-show-status nil)
          (url-cookie-storage nil)
          (url-cookie-secure-storage nil))
      (emacs-dsh--url-retrieve
     url
     (lambda (status)
       (let (value failure)
         (unwind-protect
             (condition-case err
                 (progn
                   (goto-char (point-min))
                   (unless (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                     (error "Connection failed: %s" (or (plist-get status :error)
                                                       "invalid HTTP response")))
                   (unless (= (string-to-number (match-string 1)) 200)
                     (error "DSH HTTP %s (check local Host connection)" (match-string 1)))
                   (unless (re-search-forward "\r?\n\r?\n" nil t)
                     (error "Missing response body"))
                   (let* ((reply (json-parse-buffer :object-type 'alist
                                                    :array-type 'list
                                                    :null-object nil :false-object nil))
                          (result (alist-get 'result reply)))
                     (unless (and (equal (alist-get 'type reply) "server-response")
                                  (equal (alist-get 'rpcId reply) id) result)
                       (error "Invalid or mismatched RPC response"))
                     (if (eq (alist-get 'ok result) t)
                         (setq value (alist-get 'value result))
                       (setq failure
                             (format "%s: %s"
                                     (alist-get 'code (alist-get 'error result))
                                     (alist-get 'message (alist-get 'error result)))))))
               (error (setq failure (error-message-string err))))
           (kill-buffer (current-buffer)))
         (when (buffer-live-p origin)
           (with-current-buffer origin (funcall callback value failure)))))))))

(defun emacs-dsh--invalidate-auth ()
  "Discard the current signed Host cookie."
  (setq emacs-dsh--cookie-jar nil
        emacs-dsh--authenticated-base nil
        emacs-dsh--authenticated-nonce nil
        emacs-dsh--authenticated-mode nil))

(defun emacs-dsh--call-attempt (endpoint args success on-error retry)
  "Call ENDPOINT, retrying once after a stale cookie when RETRY is non-nil."
  (emacs-dsh--ensure-auth
   (lambda (failure)
     (if failure
         (if on-error (funcall on-error failure)
           (message "emacs-dsh: %s" failure))
       (emacs-dsh--request
        endpoint args
        (lambda (value error)
          (cond
           ((and retry error (string-prefix-p "DSH HTTP 401" error))
            (emacs-dsh--invalidate-auth)
            (emacs-dsh--call-attempt endpoint args success on-error nil))
           (error
              (if on-error (funcall on-error error)
                (message "emacs-dsh: %s" error)))
           (t (funcall success value)))))))))

(defun emacs-dsh--call (endpoint args success &optional on-error)
  "Authenticate automatically before calling ENDPOINT with named ARGS."
  (emacs-dsh--call-attempt endpoint args success on-error t))

(defun emacs-dsh--windows-user-home ()
  "Return the WSL-visible Windows home without shell interpolation."
  (when (and (getenv "WSL_DISTRO_NAME") (executable-find "powershell.exe"))
    (with-temp-buffer
      (when (zerop (call-process "powershell.exe" nil t nil "-NoProfile"
                                "-NonInteractive" "-Command" "$env:USERPROFILE"))
        (let ((windows (string-trim (buffer-string))))
          (when (and (not (string-empty-p windows)) (executable-find "wslpath"))
            (with-temp-buffer
              (when (zerop (call-process "wslpath" nil t nil "-u" windows))
                (string-trim (buffer-string))))))))))

(defun emacs-dsh--bridge-path ()
  "Return the local Host bridge file (never search network shares)."
  (or emacs-dsh-bridge-file
      (if (getenv "WSL_DISTRO_NAME")
          (when-let* ((home (emacs-dsh--windows-user-home)))
            (expand-file-name ".dsh/emacs-dsh-bridge.json" home))
        (expand-file-name "emacs-dsh-bridge.json"
                          (or (getenv "DSH_HOME") (expand-file-name "~/.dsh"))))))

(defun emacs-dsh--decrypt-dpapi (cipher)
  "Decrypt CIPHER using the current Windows account, without a shell."
  (unless (and (stringp cipher) (string-match-p "\\`[A-Za-z0-9+/]+=*\\'" cipher)
               (executable-find "powershell.exe"))
    (error "DPAPI is available only to the Windows account running DSH"))
  (let ((script (concat "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;"
                        "$b=[Convert]::FromBase64String('" cipher "');"
                        "$p=[System.Security.Cryptography.ProtectedData]::Unprotect("
                        "$b,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser);"
                        "[Console]::Write([Text.Encoding]::UTF8.GetString($p))")))
    (with-temp-buffer
      (unless (zerop (call-process "powershell.exe" nil t nil "-NoProfile"
                                  "-NonInteractive" "-Command" script))
        (error "Cannot decrypt bridge (must run under the same Windows user)"))
      (buffer-string))))

(defun emacs-dsh--bridge-launch ()
  "Read and validate the opted-in Host's current local launch URL."
  (let ((file (emacs-dsh--bridge-path)))
    (cond
     ((not file)
      (error "DSH bridge path unavailable; check DSH_HOME or emacs-dsh-bridge-file"))
     ((file-remote-p file)
      (error "DSH bridge must be a local file: %s" file))
     ((file-symlink-p file)
      (error "DSH bridge must not be a symlink: %s" file))
     ((not (file-exists-p file))
      (error "DSH bridge missing at %s; check Host plugin, profile and DSH_HOME" file))
     ((not (and (file-regular-p file) (file-readable-p file)))
      (error "DSH bridge is not a readable regular file: %s" file))
     ((>= (file-attribute-size (file-attributes file)) 8192)
      (error "DSH bridge file is unexpectedly large: %s" file)))
    (let* ((data (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'alist)))
           (url (alist-get 'url data))
           (launch (alist-get 'launch data))
           (token (pcase (alist-get 'encoding launch)
                    ("dpapi-current-user"
                     (emacs-dsh--decrypt-dpapi (alist-get 'value launch)))
                     ("plain"
                      (when (and (not (eq system-type 'windows-nt))
                                 (not (getenv "WSL_DISTRO_NAME")))
                        (alist-get 'value launch)))
                    (_ nil))))
      (unless (and (equal (alist-get 'version data) 1)
                   (stringp (alist-get 'nonce data))
                   (stringp url) (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+/\\'" url)
                   (stringp token) (string-match-p
                                    (concat "\\`" (regexp-quote url) "[?]token=[A-Za-z0-9_-]+\\'")
                                    token))
        (error "DSH bridge invalid or not from the local Host"))
      (list url token (alist-get 'nonce data)))))

(defun emacs-dsh--managed-parse-launch (output)
  "Return (base launch) from trusted local DSH startup OUTPUT, or nil."
  (when (string-match
         "dsh web:[[:space:]]*\\(http://127\\.0\\.0\\.1:\\([0-9]+\\)/[?]token=[A-Za-z0-9_-]+\\)"
         output)
    (let ((port (string-to-number (match-string 2 output)))
          (launch (match-string 1 output)))
      (when (<= 1 port 65535)
        (list (format "http://127.0.0.1:%d/" port) launch)))))

(defun emacs-dsh--managed-notify (connection failure)
  "Notify all startup waiters with CONNECTION or FAILURE."
  (let ((waiters (nreverse emacs-dsh--managed-waiters)))
    (setq emacs-dsh--managed-waiters nil)
    (dolist (waiter waiters) (funcall waiter connection failure))))

(defun emacs-dsh--managed-filter (process output)
  "Capture PROCESS's local launch URL from its startup OUTPUT."
  (when (and (eq process emacs-dsh--managed-process)
             (not emacs-dsh--managed-connection))
    (setq emacs-dsh--managed-output
          (concat emacs-dsh--managed-output output))
    (if-let* ((launch (emacs-dsh--managed-parse-launch emacs-dsh--managed-output)))
        (progn
          (when emacs-dsh--managed-timer
            (cancel-timer emacs-dsh--managed-timer)
            (setq emacs-dsh--managed-timer nil))
          (setq emacs-dsh--managed-output ""
                emacs-dsh--managed-connection
                (append launch (list (emacs-dsh--uuid))))
          (emacs-dsh--managed-notify emacs-dsh--managed-connection nil))
      (when (> (length emacs-dsh--managed-output) 8192)
        (setq emacs-dsh--managed-output
              (substring emacs-dsh--managed-output -8192))))))

(defun emacs-dsh--managed-sentinel (process _event)
  "Forget PROCESS if the managed Host exits."
  (when (and (eq process emacs-dsh--managed-process)
             (not (process-live-p process)))
    (when emacs-dsh--managed-timer
      (cancel-timer emacs-dsh--managed-timer)
      (setq emacs-dsh--managed-timer nil))
    (setq emacs-dsh--managed-process nil
          emacs-dsh--managed-connection nil
          emacs-dsh--managed-output "")
    (emacs-dsh--invalidate-auth)
    (emacs-dsh--managed-notify nil
                               "Emacs-managed DSH Host exited; check dsh web availability")))

(defun emacs-dsh--managed-start (callback)
  "Call CALLBACK with (connection error), starting a local Host if needed."
  (cond
   ((and emacs-dsh--managed-process
         (process-live-p emacs-dsh--managed-process)
         emacs-dsh--managed-connection)
    (funcall callback emacs-dsh--managed-connection nil))
   (t
    (push callback emacs-dsh--managed-waiters)
    (unless (and emacs-dsh--managed-process
                 (process-live-p emacs-dsh--managed-process))
      (setq emacs-dsh--managed-process nil
            emacs-dsh--managed-connection nil
            emacs-dsh--managed-output "")
      (condition-case err
          (let ((program (or (executable-find emacs-dsh-managed-command)
                             (and (file-executable-p emacs-dsh-managed-command)
                                  emacs-dsh-managed-command))))
            (unless program
              (error "Cannot find dsh executable; set emacs-dsh-managed-command"))
            (setq emacs-dsh--managed-process
                  (make-process
                   :name "emacs-dsh-web" :buffer nil :noquery t
                   :command (list program "web" "--host" "127.0.0.1"
                                  "--port" "0" "--no-open")
                   :coding 'utf-8-unix
                   :filter #'emacs-dsh--managed-filter
                   :sentinel #'emacs-dsh--managed-sentinel))
            (let ((process emacs-dsh--managed-process))
              (setq emacs-dsh--managed-timer
                    (run-at-time
                     45 nil
                     (lambda ()
                       (when (and (eq process emacs-dsh--managed-process)
                                  (not emacs-dsh--managed-connection))
                         (setq emacs-dsh--managed-process nil
                               emacs-dsh--managed-output ""
                               emacs-dsh--managed-timer nil)
                         (delete-process process)
                         (emacs-dsh--managed-notify
                           nil "Timed out starting dsh web; check the CLI configuration")))))))
        (error
         (setq emacs-dsh--managed-process nil)
         (emacs-dsh--managed-notify nil (error-message-string err))))))))

(defun emacs-dsh--managed-stop ()
  "Stop only the DSH Web Host process owned by this Emacs."
  (when emacs-dsh--managed-timer
    (cancel-timer emacs-dsh--managed-timer)
    (setq emacs-dsh--managed-timer nil))
  (let ((process emacs-dsh--managed-process))
    (setq emacs-dsh--managed-process nil
          emacs-dsh--managed-connection nil
          emacs-dsh--managed-output "")
    (when (and process (process-live-p process)) (delete-process process)))
  (emacs-dsh--invalidate-auth)
  (emacs-dsh--managed-notify nil "Emacs-managed DSH Host stopped"))

(add-hook 'kill-emacs-hook #'emacs-dsh--managed-stop)

(defun emacs-dsh--effective-mode ()
  "Return the Host mode selected by `emacs-dsh-connection-mode'.
In `auto' mode the presence of the bridge file indicates a Desktop Host.
An existing but invalid bridge must fail validation, not silently fall back."
  (pcase emacs-dsh-connection-mode
    ('auto (if-let* ((file (emacs-dsh--bridge-path)))
               (if (or (file-remote-p file)
                       (file-exists-p file)
                       (file-symlink-p file))
                   'desktop 'managed)
             'managed))
    (mode mode)))

(defun emacs-dsh--connection-launch (mode callback)
  "Discover MODE's local Host; pass (connection error) to CALLBACK."
  (pcase mode
    ('managed (emacs-dsh--managed-start callback))
    ('desktop
     (let ((result (condition-case err
                       (list (emacs-dsh--bridge-launch) nil)
                     (error (list nil (error-message-string err))))))
       (apply callback result)))
    (_ (funcall callback nil "Invalid emacs-dsh-connection-mode"))))

(defun emacs-dsh--exchange-token (launch callback)
  "Exchange LAUNCH for a signed cookie; invoke CALLBACK with an error or nil."
  (let* ((url-cookie-file nil)
         (url-cookie-storage nil)
         (url-cookie-secure-storage nil)
         (url-automatic-caching nil)
         (url-max-redirections 0)
         (url-show-status nil)
         (url-proxy-services (cons '("no_proxy" . "127.0.0.1") url-proxy-services))
         (url-request-method "GET")
         (url-request-extra-headers '(("Authorization" . "")))
         (url-request-data nil))
    (emacs-dsh--url-retrieve
     launch
     (lambda (status)
       (let (failure cookie)
         (unwind-protect
             (condition-case err
                 (progn
                   (when (and (plist-get status :error)
                              (not (eq (cadr (plist-get status :error)) 'http-redirect-limit)))
                     (error "Host login failed"))
                   (goto-char (point-min))
                   (unless (looking-at "HTTP/[0-9.]+ 303 ") (error "Host did not accept login"))
                   (when (re-search-forward "^[Ss]et-[Cc]ookie: \\([^;\r\n]+\\)" nil t)
                     (setq cookie (match-string-no-properties 1)))
                   (unless (and cookie (string-match-p "\\`dsh-auth-" cookie))
                     (error "Host returned no signed cookie")))
               (error (setq failure (error-message-string err))))
           (kill-buffer (current-buffer)))
         (funcall callback cookie failure))))))

(defun emacs-dsh--auth-finish (failure)
  (setq emacs-dsh--auth-running nil)
  (let ((waiters (nreverse emacs-dsh--auth-waiters)))
    (setq emacs-dsh--auth-waiters nil)
    (dolist (waiter waiters) (funcall waiter failure))))

(defun emacs-dsh--ensure-auth (callback)
  "Authenticate automatically to the selected local Host, calling CALLBACK once."
  (let* ((origin (current-buffer))
         (notify (lambda (failure)
                   (when (buffer-live-p origin)
                     (with-current-buffer origin (funcall callback failure)))))
         (mode (emacs-dsh--effective-mode)))
    (push notify emacs-dsh--auth-waiters)
    (unless emacs-dsh--auth-running
      (setq emacs-dsh--auth-running t)
      (emacs-dsh--connection-launch
       mode
       (lambda (connection failure)
         (cond
          (failure (emacs-dsh--auth-finish failure))
          ((not (eq mode (emacs-dsh--effective-mode)))
           (emacs-dsh--auth-finish "Connection mode changed; retry"))
          ((and emacs-dsh--cookie-jar
                (equal (car connection) emacs-dsh--authenticated-base)
                (equal (caddr connection) emacs-dsh--authenticated-nonce)
                (eq mode emacs-dsh--authenticated-mode))
           (emacs-dsh--auth-finish nil))
          (t
           (emacs-dsh--invalidate-auth)
           (setq emacs-dsh-url (car connection))
           (condition-case err
               (emacs-dsh--exchange-token
                (cadr connection)
                (lambda (cookie error)
                  (if (and (eq mode 'managed)
                           (not (equal connection emacs-dsh--managed-connection)))
                      (emacs-dsh--auth-finish "Emacs-managed DSH Host restarted; retry")
                    (setq emacs-dsh--cookie-jar cookie
                          emacs-dsh--authenticated-base (and cookie (car connection))
                          emacs-dsh--authenticated-nonce (and cookie (caddr connection))
                          emacs-dsh--authenticated-mode (and cookie mode))
                    (emacs-dsh--auth-finish error))))
             (error (emacs-dsh--auth-finish (error-message-string err)))))))))))

;;;###autoload
(defun emacs-dsh-connect ()
  "Re-authenticate automatically to the DSH Host (normally unnecessary)."
  (interactive)
  (emacs-dsh--invalidate-auth)
  (emacs-dsh--ensure-auth
   (lambda (failure) (message "emacs-dsh: %s" (or failure "connected")))))

(defun emacs-dsh--uuid ()
  "Generate a sufficiently unique client request/session id."
  (format "%x-%x-%x" (floor (* (float-time) 1000000)) (random most-positive-fixnum)
          (random most-positive-fixnum)))

(defun emacs-dsh-wsl-windows-path (path)
  "Convert a WSL PATH into the Windows Host's syntax via wslpath."
  (let ((output (with-temp-buffer
                  (when (zerop (call-process "wslpath" nil t nil "-w" path))
                    (string-trim (buffer-string))))))
    (or output (user-error "wslpath -w failed for %s" path))))

(defun emacs-dsh--host-path (path)
  (cond (emacs-dsh-wsl-path-function
         (funcall emacs-dsh-wsl-path-function path))
        ((and (eq (emacs-dsh--effective-mode) 'desktop)
              (getenv "WSL_DISTRO_NAME"))
         (emacs-dsh-wsl-windows-path path))
        (t path)))

(defun emacs-dsh--local-path (path)
  "Convert a Windows Host PATH to a WSL path when possible."
  (if (and (stringp path) (getenv "WSL_DISTRO_NAME")
           (string-match-p "\\`[A-Za-z]:[/\\\\]" path)
           (executable-find "wslpath"))
      (with-temp-buffer
        (if (zerop (call-process "wslpath" nil t nil "-u" path))
            (string-trim (buffer-string))
          path))
    path))

(defun emacs-dsh--project-root ()
  (let ((project (project-current nil)))
    (expand-file-name (if project (project-root project) default-directory))))

(defvar emacs-dsh-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-dsh-send)
    (define-key map (kbd "M-p") #'emacs-dsh-previous-prompt)
    (define-key map (kbd "M-n") #'emacs-dsh-next-prompt)
    (define-key map (kbd "C-c C-c") #'emacs-dsh-send)
    (define-key map (kbd "C-c C-s") #'emacs-dsh-steer)
    (define-key map (kbd "C-c C-k") #'emacs-dsh-cancel)
    (define-key map (kbd "C-c C-q") #'emacs-dsh-quit)
    (define-key map (kbd "C-c C-r") #'emacs-dsh-resume)
    (define-key map (kbd "C-c C-l") #'emacs-dsh-queue)
    (define-key map (kbd "C-c C-p") #'emacs-dsh-paste)
    (define-key map (kbd "TAB") #'emacs-dsh-complete)
    (define-key map (kbd "M-TAB") #'emacs-dsh-complete)
    (define-key map (kbd "s-v") #'emacs-dsh-paste)
    (define-key map (kbd "s-V") #'emacs-dsh-paste)
    (define-key map (kbd "s-a") #'emacs-dsh-select-draft)
    map)
  "Shared bindings for the DSH transcript and composer.")

(defvar emacs-dsh--queue-edit-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-dsh-queue-edit-save)
    (define-key map (kbd "C-c C-c") #'emacs-dsh-queue-edit-save)
    (define-key map (kbd "C-c C-k") #'emacs-dsh-queue-edit-abort)
    (define-key map (kbd "C-c C-q") #'emacs-dsh-queue-edit-abort)
    (define-key map (kbd "C-c C-s") #'emacs-dsh-queue-edit-save)
    (set-keymap-parent map emacs-dsh-mode-map)
    map)
  "Keys used while editing a queued message in the chat composer.")

(defvar emacs-dsh-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map emacs-dsh-mode-map)
    (define-key map (kbd "i") #'emacs-dsh-focus-input)
    map)
  "Keys in an emacs-dsh chat buffer.")

(defvar emacs-dsh--input-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "S-RET") #'newline)
    (make-composed-keymap (list map emacs-dsh-mode-map widget-field-keymap)))
  "Widget keymap for the DSH composer.")

(defvar emacs-dsh--queue-edit-input-keymap
  (make-composed-keymap (list emacs-dsh--queue-edit-keymap widget-field-keymap))
  "Widget keymap while editing a pending message.")

(define-derived-mode emacs-dsh-chat-mode fundamental-mode "emacs-dsh"
  "Major mode for a DSH chat; compose in the editable field at the bottom."
  (setq-local emacs-dsh--seen (make-hash-table :test #'eql))
  (setq-local emacs-dsh--pending (make-hash-table :test #'equal))
  (setq-local emacs-dsh--closing nil)
  (setq-local emacs-dsh--command-inflight nil)
  (setq-local emacs-dsh--model-selection nil)
  (setq-local emacs-dsh--permission nil)
  (setq-local emacs-dsh--queue-items nil)
  (setq-local emacs-dsh--queue-seq -1)
  (setq-local emacs-dsh--queue-ready nil)
  (setq-local emacs-dsh--queue-edit nil)
  (setq-local emacs-dsh--tool-cards (make-hash-table :test #'equal))
  (setq-local emacs-dsh--tool-pending nil)
  (setq-local emacs-dsh--context-pressure nil)
  (setq-local emacs-dsh--agent-preset nil)
  (setq-local emacs-dsh--active-tools nil)
  (setq-local emacs-dsh--waiting nil)
  (setq-local emacs-dsh--cursor -1)
  (setq-local emacs-dsh--last-prompt nil)
  (setq-local emacs-dsh--task-turn-open nil)
  (setq-local emacs-dsh--task-next-turn-claimed nil)
  (setq-local emacs-dsh--task-first-step nil)
  (setq-local emacs-dsh--inbox-trace nil)
  (setq-local emacs-dsh--prompt-history nil)
  (setq-local emacs-dsh--history-index nil)
  (setq-local emacs-dsh--history-draft nil)
  (setq-local truncate-lines nil)
  (setq-local buffer-invisibility-spec (copy-tree buffer-invisibility-spec))
  (add-to-invisibility-spec 'markdown-markup)
  (add-to-invisibility-spec 'emacs-dsh-tool-details)
  (add-to-invisibility-spec 'emacs-dsh-process)
  (tab-line-mode 1)
  (setq-local tab-line-format '(:eval (emacs-dsh--header)))
  (setq-local header-line-format '(:eval (emacs-dsh--pinned-prompt)))
  (setq-local mode-line-misc-info
              (cons '(:eval (emacs-dsh--state)) mode-line-misc-info))
  (add-hook 'kill-buffer-hook #'emacs-dsh--close nil t))

(defun emacs-dsh--header ()
  "Show context pressure on the left and model and permission on the right."
  (let* ((pressure emacs-dsh--context-pressure)
         (tokens (or (alist-get 'projectedTokens pressure)
                     (alist-get 'pressureTokens pressure)))
         (window (alist-get 'contextWindow pressure))
         (selection emacs-dsh--model-selection)
         (left (if (and (numberp tokens) (numberp window))
                   (format "%.1fk/%.1fk" (/ tokens 1000.0) (/ window 1000.0))
                 "context: —"))
         (right (concat (if selection
                            (format "(%s) %s • %s%s"
                                    (alist-get 'provider selection)
                                    (alist-get 'model selection)
                                    (or (alist-get 'reasoningEffort selection) "default")
                                    (if emacs-dsh--agent-preset
                                        (format " • %s" emacs-dsh--agent-preset) ""))
                          "model: loading")
                        (if (and (stringp emacs-dsh--permission)
                                 (not (string-empty-p emacs-dsh--permission)))
                            (format " • permission: %s" emacs-dsh--permission) ""))))
    (concat left " " (propertize " " 'display `(space :align-to (- right ,(string-width right))))
            (replace-regexp-in-string "%" "%%" right))))

(defun emacs-dsh--pinned-prompt ()
  "Show the current or most recently completed task below the status row."
  (when emacs-dsh--last-prompt
    (propertize
     (truncate-string-to-width
      (concat "You: "
              (replace-regexp-in-string "[\r\n]+" " ⏎ " emacs-dsh--last-prompt))
      (max 1 (1- (window-width))) nil nil "…")
     'face 'emacs-dsh-user-face)))

(defun emacs-dsh--state ()
  "Show the agent's activity in the ordinary Emacs mode line."
  (let ((queued (cl-count 'queued emacs-dsh--queue-items :key #'car))
        (steering (cl-count 'steering emacs-dsh--queue-items :key #'car)))
    (propertize
     (format " DSH %s%s%s"
             (cond (emacs-dsh--queue-edit "editing queue")
                   (emacs-dsh--waiting emacs-dsh--waiting)
                   (emacs-dsh--active-tools
                    (format "tool: %s" (car emacs-dsh--active-tools)))
                   (emacs-dsh--running "thinking")
                   (t "idle"))
             (if emacs-dsh--running
                 (format " %c" (aref "|/-\\" (mod emacs-dsh--spinner-index 4)))
               "")
             (if (or (> queued 0) (> steering 0))
                 (format " [Q%d S%d]" queued steering) ""))
     'face 'emacs-dsh-status-face)))

(defun emacs-dsh--set-running (running)
  "Track RUNNING and animate only while a turn is active."
  (setq emacs-dsh--running running)
  (if running
      (unless emacs-dsh--spinner-timer
        (let ((buffer (current-buffer)))
          (setq emacs-dsh--spinner-timer
                (run-at-time 0.15 0.15
                             (lambda ()
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq emacs-dsh--spinner-index (1+ emacs-dsh--spinner-index))
                                   (force-mode-line-update))))))))
    (when emacs-dsh--spinner-timer
      (cancel-timer emacs-dsh--spinner-timer)
      (setq emacs-dsh--spinner-timer nil)))
   (force-mode-line-update))

(defun emacs-dsh--compose ()
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (setq-local emacs-dsh--input-start (copy-marker (point) nil))
    (insert (propertize emacs-dsh--composer-prefix 'read-only t
                        'rear-nonsticky '(read-only)))
    (let ((start (point)))
      (let ((draft emacs-dsh--draft))
        (setq emacs-dsh--draft nil)
        (setq-local emacs-dsh--draft
                     (widget-create 'editable-field :format "%v"
                                    :keymap (if emacs-dsh--queue-edit
                                                emacs-dsh--queue-edit-input-keymap
                                              emacs-dsh--input-keymap)
                                    :value (or draft ""))))
       (widget-setup)
       (setq-local emacs-dsh--input-background
                   (make-overlay (1+ (marker-position emacs-dsh--input-start))
                                 (point-max) nil t t))
       (overlay-put emacs-dsh--input-background 'face
                    '(:inherit widget-field :extend t))
       (set-marker-insertion-type emacs-dsh--input-start t)
       (goto-char start)
       (when emacs-dsh--attachments
         (emacs-dsh--update-image-preview)))))

(defun emacs-dsh--input-widget ()
  (and emacs-dsh--draft (widget-get emacs-dsh--draft :from) emacs-dsh--draft))

(defun emacs-dsh-focus-input ()
  "Move point to the end of the chat composer."
  (interactive)
  (let ((widget (emacs-dsh--input-widget)))
    (unless widget (user-error "Not in a DSH chat"))
    (goto-char (+ (emacs-dsh--draft-beginning)
                  (length (string-trim-right (widget-value widget)))))))

(defun emacs-dsh--remember-prompt (text)
  "Add nonempty TEXT to the current chat's recent prompt history."
  (when (and (stringp text) (not (string-empty-p (string-trim text)))
             (not (equal text (car emacs-dsh--prompt-history))))
    (push text emacs-dsh--prompt-history)
    (setq emacs-dsh--history-index nil emacs-dsh--history-draft nil)))

(defun emacs-dsh--history-move (direction)
  "Move DIRECTION steps through prompts, retaining the current draft."
  (unless (emacs-dsh--input-widget) (user-error "Not in a DSH chat"))
  (when emacs-dsh--queue-edit (user-error "Finish the queue edit first"))
  (when emacs-dsh--prompt-history
    (let ((index (or emacs-dsh--history-index -1)))
      (when (and (= index -1) (> direction 0))
        (setq emacs-dsh--history-draft
              (widget-value (emacs-dsh--input-widget))))
      (setq index (max -1 (min (1- (length emacs-dsh--prompt-history))
                                (+ index direction))))
      (setq emacs-dsh--history-index (unless (= index -1) index))
      (when (or (>= index 0) emacs-dsh--history-draft)
        (emacs-dsh--replace-draft
         (if (= index -1) emacs-dsh--history-draft
           (nth index emacs-dsh--prompt-history)))))))

(defun emacs-dsh-previous-prompt ()
  "Replace the draft with the previous prompt in this chat."
  (interactive)
  (emacs-dsh--history-move 1))

(defun emacs-dsh-next-prompt ()
  "Replace the draft with the next prompt, or restore the unsent draft."
  (interactive)
  (emacs-dsh--history-move -1))

(defun emacs-dsh--draft-text ()
  (let ((widget (emacs-dsh--input-widget)))
    (if widget (string-trim (widget-value widget)) "")))

(defun emacs-dsh--draft-beginning ()
  "Return the stable start of the editable composer text."
  (+ (marker-position emacs-dsh--input-start)
     (length emacs-dsh--composer-prefix)))

(defun emacs-dsh-select-draft ()
  "Select only the text in the current chat's composer."
  (interactive)
  (let ((widget (emacs-dsh--input-widget)))
    (unless widget (user-error "Not in a DSH chat"))
    (let ((start (emacs-dsh--draft-beginning)))
      (goto-char start)
      (push-mark (+ start
                    (length (string-trim-right (widget-value widget)))) nil t))))

(defun emacs-dsh--replace-draft (text)
  (when-let* ((widget (emacs-dsh--input-widget)))
    (let ((inhibit-read-only t))
      (widget-value-set widget text)
      (widget-setup)
      (goto-char (+ (emacs-dsh--draft-beginning) (length text))))))

(defun emacs-dsh--insert-before-input (text &optional face)
  (let ((inhibit-read-only t)
        (widget (emacs-dsh--input-widget)))
    (save-excursion
      (goto-char (if (and widget emacs-dsh--input-start)
                     emacs-dsh--input-start (point-max)))
      (insert (propertize (concat text "\n") 'read-only t
                          'rear-nonsticky '(read-only)
                           'face (or face 'default))))))

(defun emacs-dsh--markdown-text (text)
  "Return TEXT with Markdown faces and hidden markup as text properties.
The original characters remain in the transcript for copying and search."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (delay-mode-hooks (markdown-mode))
        (setq-local markdown-hide-markup t)
        (setq-local markdown-hide-urls t)
        (font-lock-flush)
        (font-lock-ensure)
        (let* ((source (buffer-substring (point-min) (point-max)))
               (rendered (substring-no-properties source))
               (index 0))
          (while (< index (length source))
            (let ((next (or (next-property-change index source) (length source)))
                  (props nil))
              (dolist (key '(face font-lock-face display invisible))
                (when-let* ((value (get-text-property index key source)))
                  (setq props (plist-put props key value))))
              (when props (add-text-properties index next props rendered))
              (setq index next)))
          rendered))
    (error text)))

(defvar emacs-dsh--link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-dsh-open-link)
    (define-key map [mouse-1] #'emacs-dsh-open-link)
    map)
  "Keymap on Markdown links in a DSH transcript.")

;;;###autoload
(defun emacs-dsh-open-link (&optional event)
  "Open the Markdown URL at point or mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((url (cl-loop for overlay in (overlays-at (point))
                      thereis (overlay-get overlay 'emacs-dsh-url))))
    (unless url (user-error "Move to a DSH Markdown link first"))
    (browse-url url)))

(defun emacs-dsh--linkify-markdown (text start)
  "Make HTTP(S) Markdown links in TEXT interactive at buffer position START."
  (let ((offset 0))
    (while (string-match "\\[\\([^]]+\\)\\](\\(https?://[^)[:space:]]+\\))"
                         text offset)
      (let ((overlay (make-overlay (+ start (match-beginning 1))
                                   (+ start (match-end 1)) nil t nil))
            (url (match-string 2 text)))
        (overlay-put overlay 'emacs-dsh-url url)
        (overlay-put overlay 'keymap emacs-dsh--link-map)
        (overlay-put overlay 'mouse-face 'highlight)
        (overlay-put overlay 'help-echo (concat "Open " url)))
      (setq offset (match-end 0)))))

(defun emacs-dsh--image-block (block)
  "Render a user image BLOCK, falling back to its label without pixels."
  (let* ((mime (alist-get 'mediaType block))
         (type (cdr (assoc mime '(("image/png" . png) ("image/jpeg" . jpeg)
                                  ("image/webp" . webp) ("image/gif" . gif)))))
         (data (alist-get 'data block))
         (image (and (display-images-p) type (stringp data)
                     (ignore-errors
                       (create-image (base64-decode-string data) type t
                                     :max-width 480 :max-height 320)))))
    (if image (propertize "[image]" 'display image) "[image]")))

(defvar emacs-dsh--process-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-dsh-toggle-process)
    (define-key map [mouse-1] #'emacs-dsh-toggle-process)
    map)
  "Keymap on a folded process heading.")

(defun emacs-dsh--fold-process ()
  "Collapse the intermediate transcript for the current finished turn."
  (when (and emacs-dsh--turn-has-process
             emacs-dsh--turn-start emacs-dsh--final-start
             (< (marker-position emacs-dsh--turn-start)
                (marker-position emacs-dsh--final-start)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char emacs-dsh--turn-start)
        (let ((heading (point)))
          (insert "▸ Process (RET to expand)\n")
          (add-text-properties heading (point)
                               '(read-only t rear-nonsticky (read-only)))
          (let ((header (make-overlay heading (1- (point)) nil t nil))
                (body (make-overlay (point) emacs-dsh--final-start nil nil nil)))
            (overlay-put header 'emacs-dsh-process body)
            (overlay-put header 'keymap emacs-dsh--process-map)
            (overlay-put header 'mouse-face 'highlight)
            (overlay-put header 'help-echo "RET or click: toggle intermediate steps")
            (overlay-put body 'invisible 'emacs-dsh-process))))))
  (setq emacs-dsh--turn-start nil emacs-dsh--final-start nil
        emacs-dsh--turn-has-process nil))

;;;###autoload
(defun emacs-dsh-toggle-process (&optional event)
  "Show or hide intermediate steps at point or mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let* ((header (cl-find-if (lambda (overlay)
                               (overlay-get overlay 'emacs-dsh-process))
                             (overlays-at (point))))
         (body (and header (overlay-get header 'emacs-dsh-process))))
    (unless body (user-error "Move to a DSH process heading first"))
    (let ((hidden (overlay-get body 'invisible)))
      (overlay-put body 'invisible (unless hidden 'emacs-dsh-process))
      (overlay-put header 'display (if hidden "▾ Process (RET to collapse)"
                               "▸ Process (RET to expand)")))))

(defun emacs-dsh--insert-message (label text &optional user content)
  "Insert LABEL and TEXT as a readable transcript message.
Assistant TEXT is rendered as Markdown; USER CONTENT may contain images."
  (let* ((body (if user
                   (if content
                       (mapconcat (lambda (block)
                                    (if (equal (alist-get 'type block) "image")
                                        (emacs-dsh--image-block block)
                                      (pcase (alist-get 'type block)
                                        ((or "text" "reasoning")
                                         (or (alist-get 'text block) ""))
                                        ("file" "[file]") (_ ""))))
                                  (if (vectorp content) (append content nil) content)
                                  "\n")
                     text)
                 (emacs-dsh--markdown-text text)))
         (prefix (propertize label 'face (if user 'emacs-dsh-user-face
                                          'emacs-dsh-assistant-label-face)))
         (formatted (concat prefix body "\n")))
    (when user
      (add-face-text-property 0 (length formatted) 'emacs-dsh-user-face
                              'append formatted))
    (let ((inhibit-read-only t)
          (widget (emacs-dsh--input-widget)))
      (save-excursion
        (goto-char (if (and widget emacs-dsh--input-start)
                       emacs-dsh--input-start (point-max)))
        (let ((start (point)))
          (insert formatted "\n")
          (add-text-properties start (point) '(read-only t
                                               rear-nonsticky (read-only)))
          (unless user
            (emacs-dsh--linkify-markdown text (+ start (length label)))))))))

(cl-defstruct (emacs-dsh--tool-card
               (:constructor emacs-dsh--tool-card-create))
  id name summary header details end expanded status)

(defvar emacs-dsh--tool-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-dsh-toggle-tool-details)
    (define-key map [mouse-1] #'emacs-dsh-toggle-tool-details)
    map)
  "Keymap on a tool card header.")

(defun emacs-dsh--tool-summary (arguments)
  "Return a compact one-line summary of tool ARGUMENTS."
  (let* ((parsed (and (stringp arguments)
                      (condition-case nil
                          (json-parse-string arguments :object-type 'alist
                                             :array-type 'list)
                        (error nil))))
         (preferred (cl-loop for key in '(description command code path query url)
                             for value = (alist-get key parsed)
                             when (and (stringp value) (not (string-empty-p value)))
                             return value))
         (first (car (split-string (or preferred arguments "") "[\r\n]" t))))
    (truncate-string-to-width
     (string-trim (replace-regexp-in-string "[[:space:]]+" " " (or first "")))
     88 nil nil t)))

(defun emacs-dsh--tool-label (card)
  "Return the visible header for CARD."
  (let* ((status (emacs-dsh--tool-card-status card))
         (face (pcase status
                 ('success 'emacs-dsh-tool-success-face)
                 ('error 'emacs-dsh-tool-error-face)
                 (_ 'emacs-dsh-tool-face)))
         (symbol (pcase status ('success "✓") ('error "✗") (_ "●")))
         (summary (emacs-dsh--tool-card-summary card)))
    (concat
     (propertize (format "  %s %s "
                         (if (emacs-dsh--tool-card-expanded card) "▾" "▸")
                         symbol) 'face face)
     (propertize (emacs-dsh--tool-card-name card) 'face 'emacs-dsh-tool-face)
     (if (string-empty-p summary) ""
       (propertize (concat " — " summary) 'face 'emacs-dsh-tool-face)))))

(defun emacs-dsh--refresh-tool-card (card)
  "Update CARD's header and detail visibility."
  (overlay-put (emacs-dsh--tool-card-header card) 'display
               (emacs-dsh--tool-label card))
  (overlay-put (emacs-dsh--tool-card-details card) 'invisible
               (unless (emacs-dsh--tool-card-expanded card)
                 'emacs-dsh-tool-details)))

;;;###autoload
(defun emacs-dsh-toggle-tool-details (&optional event)
  "Expand or collapse the tool card at point or mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((card (cl-loop for overlay in (overlays-at (point))
                       thereis (overlay-get overlay 'emacs-dsh-tool-card))))
    (unless card (user-error "Move to a DSH tool header first"))
    (setf (emacs-dsh--tool-card-expanded card)
          (not (emacs-dsh--tool-card-expanded card)))
    (emacs-dsh--refresh-tool-card card)))

(defun emacs-dsh--make-tool-card (id name arguments)
  "Insert a collapsed tool card for ID, NAME and ARGUMENTS."
  (let ((inhibit-read-only t)
        (widget (emacs-dsh--input-widget))
        card)
    (save-excursion
      (goto-char (if (and widget emacs-dsh--input-start)
                     emacs-dsh--input-start (point-max)))
      (let ((header-start (point)))
        (insert "Tool\n")
        (let* ((header (make-overlay header-start (1- (point)) nil t nil))
               (details-start (point))
               (detail-text (if (and (stringp arguments)
                                     (not (string-empty-p arguments)))
                                (concat "    Arguments:\n"
                                        (replace-regexp-in-string
                                         "^" "    " arguments) "\n")
                              "    Arguments: none\n")))
          (insert detail-text "\n")
          (add-text-properties header-start (point)
                               '(read-only t rear-nonsticky (read-only)))
          (add-face-text-property details-start (point)
                                  'emacs-dsh-tool-detail-face 'append)
          (let ((details (make-overlay details-start (point) nil nil nil))
                (end (copy-marker (point) nil)))
            (setq card (emacs-dsh--tool-card-create
                        :id id :name name :summary (emacs-dsh--tool-summary arguments)
                        :header header :details details :end end
                        :expanded nil :status 'running))
            (overlay-put header 'emacs-dsh-tool-card card)
            (overlay-put header 'keymap emacs-dsh--tool-header-map)
            (overlay-put header 'mouse-face 'highlight)
            (overlay-put header 'help-echo "RET or click: toggle tool details")
            (emacs-dsh--refresh-tool-card card)))))
    (puthash id card emacs-dsh--tool-cards)
    card))

(defun emacs-dsh--tool-call (data seq)
  "Render tool call DATA at event SEQ."
  (let* ((id (or (alist-get 'callId data) (format "event:%s" seq)))
         (name (or (alist-get 'name data) "tool")))
    (push id emacs-dsh--tool-pending)
    (push name emacs-dsh--active-tools)
    (emacs-dsh--make-tool-card id name (alist-get 'arguments data))
    (force-mode-line-update)))

(defun emacs-dsh--tool-result (data)
  "Append tool result DATA to its matching card."
  (let* ((message (alist-get 'message data))
         (id (or (alist-get 'callId message)
                 (alist-get 'callId (alist-get 'source message))
                 (alist-get 'callId data)
                 (car emacs-dsh--tool-pending)))
         (card (and id (gethash id emacs-dsh--tool-cards)))
         (blocks (alist-get 'content message))
         (failed (or (alist-get 'error data)
                     (cl-some (lambda (block) (alist-get 'isError block)) blocks)))
         (text (emacs-dsh--content blocks))
         (reason (alist-get 'reason (alist-get 'error data))))
    (unless card
      (setq id (or id (format "orphan:%s" (float-time)))
            card (emacs-dsh--make-tool-card id "tool result" nil)))
    (setq emacs-dsh--tool-pending (delete id emacs-dsh--tool-pending))
    (setq emacs-dsh--active-tools
          (cl-remove (emacs-dsh--tool-card-name card) emacs-dsh--active-tools
                     :test #'equal :count 1))
    (let ((inhibit-read-only t)
          (details (emacs-dsh--tool-card-details card)))
      (save-excursion
        (goto-char (marker-position (emacs-dsh--tool-card-end card)))
        (let ((start (point)))
          (insert (format "    %s:\n%s%s\n\n"
                          (if failed "Error" "Result")
                          (replace-regexp-in-string
                           "^" "    " (if (string-empty-p text) "(empty)" text))
                          (if (and (stringp reason) (not (string-empty-p reason))
                                   (not (string-match-p (regexp-quote reason) text)))
                              (concat "\n    Reason: " reason) "")))
          (add-text-properties start (point)
                               '(read-only t rear-nonsticky (read-only)))
          (add-face-text-property start (point)
                                  'emacs-dsh-tool-detail-face 'append)
          (set-marker (emacs-dsh--tool-card-end card) (point))
          (move-overlay details (overlay-start details) (point)))))
    (setf (emacs-dsh--tool-card-status card) (if failed 'error 'success))
    (emacs-dsh--refresh-tool-card card)
    (force-mode-line-update)))

(defun emacs-dsh--content (blocks)
  (mapconcat
   (lambda (block)
     (pcase (alist-get 'type block)
       ((or "text" "reasoning")
        (if (and (equal (alist-get 'type block) "reasoning")
                 (not emacs-dsh-show-reasoning)) "" (or (alist-get 'text block) "")))
       ("tool-call" (format "[tool: %s %s]" (alist-get 'name block)
                            (or (alist-get 'arguments block) "")))
       ("tool-result" (emacs-dsh--content (alist-get 'content block)))
       ("image" "[image]") ("file" "[file]") (_ "")))
   (if (vectorp blocks) (append blocks nil) blocks) "\n"))

(defun emacs-dsh--task-inbox-splice (data)
  "Track durable inbox claims without promoting pending prompts."
  (let* ((target (pcase (alist-get 'target data)
                   ("next-turn" 'next-turn)
                   ("next-step" 'next-step)))
         (before (alist-get target emacs-dsh--inbox-trace))
         (start (alist-get 'start data))
         (count (or (alist-get 'removedCount data) 0))
         (inserted (alist-get 'inserted data)))
    (when (and target (listp before) (integerp start) (integerp count)
               (or emacs-dsh--inbox-trace (and (zerop start) (zerop count)))
               (>= start 0) (<= (+ start count) (length before)))
      (let ((removed (cl-subseq before start (+ start count))))
        (when (and emacs-dsh--task-turn-open (> count 0)
                   (not (alist-get 'outcome data)))
          (if (eq target 'next-turn)
              (when-let* ((message (car removed))
                          (id (alist-get 'id message)))
                (setq emacs-dsh--task-next-turn-claimed id)
                (let ((text (emacs-dsh--content (alist-get 'content message))))
                  (unless (string-empty-p text)
                    (setq emacs-dsh--last-prompt text))))
            (unless emacs-dsh--task-first-step
              (when-let* ((message (cl-find-if
                                    (lambda (item)
                                      (equal (alist-get 'kind (alist-get 'source item))
                                             "user"))
                                    removed)))
                (setq emacs-dsh--task-first-step (alist-get 'id message))))))
        (setf (alist-get target emacs-dsh--inbox-trace)
              (append (cl-subseq before 0 start) inserted
                      (nthcdr (+ start count) before)))))))

(defun emacs-dsh--event (event)
  (let* ((seq (alist-get 'seq event))
         (type (alist-get 'type event))
         (data (alist-get 'data event)))
    (when (and (numberp seq) (> seq emacs-dsh--cursor))
      (setq emacs-dsh--cursor seq))
    (when (and (numberp seq) (not (gethash seq emacs-dsh--seen)))
      (puthash seq t emacs-dsh--seen)
      (pcase type
        ("agent/inbox/spliced"
         (emacs-dsh--task-inbox-splice data))
        ("user/message"
         (let* ((message (or (alist-get 'message data) data))
                (text (emacs-dsh--content (alist-get 'content message)))
                (id (alist-get 'id message)))
           (when (and (not (string-empty-p text))
                      (let ((source (alist-get 'source message)))
                        (or (not source)
                            (equal (alist-get 'kind source) "user"))))
            (when emacs-dsh--task-turn-open
              (cond ((and emacs-dsh--task-next-turn-claimed
                          (equal id emacs-dsh--task-next-turn-claimed))
                     (setq emacs-dsh--last-prompt text))
                    ((and (not emacs-dsh--last-prompt)
                          (not emacs-dsh--task-next-turn-claimed))
                     (when (or (not emacs-dsh--task-first-step)
                               (equal id emacs-dsh--task-first-step))
                       (setq emacs-dsh--last-prompt text
                             emacs-dsh--task-first-step id)))))
            (when (and emacs-dsh--last-prompt
                       (not emacs-dsh--turn-start))
              (setq emacs-dsh--final-start nil
                    emacs-dsh--turn-has-process nil))
            (emacs-dsh--remember-prompt
             (mapconcat (lambda (block)
                          (if (equal (alist-get 'type block) "text")
                              (or (alist-get 'text block) "") ""))
                        (let ((content (alist-get 'content message)))
                          (if (vectorp content) (append content nil) content)) ""))
            (emacs-dsh--insert-message "You: " text t
                                       (alist-get 'content message))
            (unless emacs-dsh--turn-start
              (setq emacs-dsh--turn-start
                    (copy-marker emacs-dsh--input-start nil))))))
        ("assistant/message"
         (let* ((message (alist-get 'message data))
                (text (emacs-dsh--content (alist-get 'content message))))
          (when (and emacs-dsh--turn-start (not (string-empty-p text)))
            (when emacs-dsh--final-start (setq emacs-dsh--turn-has-process t))
            (setq emacs-dsh--final-start (copy-marker emacs-dsh--input-start nil)))
          (setq emacs-dsh--stream-text nil emacs-dsh--stream-id nil)
          (when emacs-dsh--stream-overlay
            (overlay-put emacs-dsh--stream-overlay 'before-string nil))
          (unless (string-empty-p text)
            (emacs-dsh--insert-message "DSH: " text))))
        ("tool/call"
         (setq emacs-dsh--turn-has-process t)
         (emacs-dsh--tool-call data seq))
        ("tool/result"
          (emacs-dsh--tool-result data))
        ("model/selection"
         (setq emacs-dsh--model-selection data))
        ("agent-preset/selected"
         (setq emacs-dsh--agent-preset (alist-get 'agentPreset data)))
        ("request/header"
         (let* ((header (alist-get 'header data))
                (config (alist-get 'config header))
                (provider (alist-get 'provider config))
                (model (alist-get 'model config))
                (effort (alist-get 'reasoningEffort config)))
           (when (and (stringp provider) (not (string-empty-p provider))
                      (stringp model) (not (string-empty-p model)))
             (setq emacs-dsh--model-selection
                   (append `((provider . ,provider) (model . ,model))
                           (when (and effort
                                      (not (alist-get 'reasoningEffort
                                                     (alist-get 'adapterDefaults header))))
                             `((reasoningEffort . ,(format "%s" effort)))))))))
        ("turn/start"
         (setq emacs-dsh--task-turn-open t
               emacs-dsh--task-next-turn-claimed nil
               emacs-dsh--task-first-step nil
               emacs-dsh--last-prompt nil)
          (unless emacs-dsh--turn-start
            (setq emacs-dsh--turn-start
                  (copy-marker (or emacs-dsh--input-start (point-max)) nil)))
          (setq emacs-dsh--final-start nil)
          (emacs-dsh--set-running t))
        ("turn/end" (setq emacs-dsh--active-tools nil emacs-dsh--waiting nil
                           emacs-dsh--task-turn-open nil
                           emacs-dsh--task-next-turn-claimed nil
                           emacs-dsh--task-first-step nil)
         (emacs-dsh--set-running nil)
         (emacs-dsh--fold-process)
         (let* ((reason (alist-get 'reason data))
                (failure (alist-get 'error reason)))
           (emacs-dsh--insert-before-input
            (format "[turn %s%s]" (or (alist-get 'kind reason) "ended")
                    (if failure
                        (format ": %s" (or (alist-get 'message failure) failure)) ""))
            'shadow)))))
    (force-mode-line-update)))

(defun emacs-dsh--stream (frame)
  "Render transient assistant text from FRAME without recording it as history."
  (pcase (alist-get 'type frame)
    ("start" (setq emacs-dsh--stream-id (alist-get 'attemptId frame)
                    emacs-dsh--stream-text ""))
    ("chunk"
     (when (equal emacs-dsh--stream-id (alist-get 'attemptId frame))
       (let ((chunk (alist-get 'chunk frame)))
         (when (equal (alist-get 'type chunk) "text-delta")
           (setq emacs-dsh--stream-text
                 (concat emacs-dsh--stream-text (alist-get 'text chunk)))))))
    ("end" (setq emacs-dsh--stream-id nil emacs-dsh--stream-text nil)))
  (when (and emacs-dsh--input-start (not emacs-dsh--stream-overlay))
    (setq emacs-dsh--stream-overlay (make-overlay emacs-dsh--input-start
                                                  emacs-dsh--input-start)))
  (when emacs-dsh--stream-overlay
    (overlay-put emacs-dsh--stream-overlay 'before-string
                  (and emacs-dsh--stream-text
                       (concat (propertize "DSH: " 'face
                                           'emacs-dsh-assistant-label-face)
                               (propertize emacs-dsh--stream-text 'face 'shadow)
                               (propertize " ▍\n" 'face 'shadow))))))

(defun emacs-dsh--queue-from-inbox (inbox)
  "Return user-visible (PLACEMENT . MESSAGE) pairs from INBOX."
  (append
   (cl-loop for item in (alist-get 'next-turn inbox)
            when (stringp (alist-get 'id item)) collect (cons 'queued item))
   (cl-loop for item in (alist-get 'next-step inbox)
            when (and (stringp (alist-get 'id item))
                      (equal (alist-get 'kind (alist-get 'source item)) "user"))
            collect (cons 'steering item))))

(defun emacs-dsh--set-inbox (inbox seq)
  "Apply an authoritative INBOX projection at SEQ."
  (when (or (not (numberp seq)) (>= seq emacs-dsh--queue-seq))
    (setq emacs-dsh--queue-items (emacs-dsh--queue-from-inbox inbox)
          emacs-dsh--queue-seq (if (numberp seq) seq emacs-dsh--queue-seq)
          emacs-dsh--queue-ready t
          emacs-dsh--inbox-trace
          (list (cons 'next-turn (alist-get 'next-turn inbox))
                (cons 'next-step (alist-get 'next-step inbox))))

    (force-mode-line-update)))
(defun emacs-dsh--control-item (value)
  "Handle a session/control baseline or projection VALUE."
  (pcase (alist-get 'type value)
    ("baseline"
     (let* ((projections (alist-get 'projections (alist-get 'value value)))
            (entry (cl-loop for (id . cell) in projections
                            when (equal (if (symbolp id) (symbol-name id) id)
                                        emacs-dsh--session-id)
                            return cell))
            (values (alist-get 'values entry)))
       (emacs-dsh--set-inbox (alist-get 'inbox values)
                             (or (alist-get 'asOfSeq entry) -1))
       (setq emacs-dsh--context-pressure (alist-get 'contextPressure values)
             emacs-dsh--agent-preset (alist-get 'agentPreset values))
       (when-let* ((permission (alist-get 'currentValue
                                         (alist-get 'permissions values))))
         (setq emacs-dsh--permission permission))
       (force-mode-line-update)))
    ("projection"
     (when (equal (alist-get 'sessionId value) emacs-dsh--session-id)
       (pcase (alist-get 'key value)
         ("inbox" (emacs-dsh--set-inbox (alist-get 'value value)
                                         (alist-get 'seq value)))
         ("contextPressure"
          (setq emacs-dsh--context-pressure (alist-get 'value value))
          (force-mode-line-update))
         ("permissions"
          (when-let* ((permission (alist-get 'currentValue
                                            (alist-get 'value value))))
            (setq emacs-dsh--permission permission)
            (force-mode-line-update)))
         ("agentPreset"
          (setq emacs-dsh--agent-preset (alist-get 'value value))
          (force-mode-line-update)))))))

(defun emacs-dsh--control-payload ()
  "Return a session/control subscription frame."
  (emacs-dsh--stream-open "dsh-control" "session/control"))

(defun emacs-dsh--on-frame (buffer socket frame)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq socket emacs-dsh--socket)
        (condition-case err
            (let ((data (json-parse-string (websocket-frame-payload frame)
                                           :object-type 'alist :array-type 'list
                                           :null-object nil :false-object nil)))
              (cond
               ((equal (alist-get 'streamId data) "dsh-control")
                (pcase (alist-get 'type data)
                  ("item" (emacs-dsh--control-item (alist-get 'value data)))
                  ("error" (message "emacs-dsh control: %s"
                                    (alist-get 'message (alist-get 'error data))))))
               ((equal (alist-get 'streamId data) emacs-dsh--session-id)
                (pcase (alist-get 'type data)
                  ("item"
                   (let ((value (alist-get 'value data)))
                     (pcase (alist-get 'type value)
                       ("snapshot"
                        (when-let* ((created (alist-get 'createdAt
                                                       (alist-get 'header value))))
                          (puthash emacs-dsh--session-id created emacs-dsh--created-at))
                        (when (< emacs-dsh--cursor 0)
                          (clrhash emacs-dsh--seen))
                        (dolist (record (alist-get 'records value))
                          (emacs-dsh--event (alist-get 'event record)))
                        (let ((values (alist-get 'values (alist-get 'projections value))))
                          (when-let* ((selection (alist-get 'next
                                                             (alist-get 'modelSelection values))))
                            (setq emacs-dsh--model-selection selection))
                          (setq emacs-dsh--context-pressure
                                (alist-get 'contextPressure values)
                                emacs-dsh--agent-preset
                                (or (alist-get 'agentPreset values)
                                    (alist-get 'agentPreset (alist-get 'header value))))
                          (when-let* ((permission (alist-get 'currentValue
                                                            (alist-get 'permissions values))))
                            (setq emacs-dsh--permission permission))
                          (when-let* ((inbox (alist-get 'inbox values)))
                            (emacs-dsh--set-inbox inbox (alist-get 'asOfSeq
                                                                   (alist-get 'projections value)))))
                        (setq emacs-dsh--cursor (max emacs-dsh--cursor
                                                     (or (alist-get 'cursor value) -1))))
                       ("event" (emacs-dsh--event (alist-get 'event value)))
                       ("assistant-stream" (emacs-dsh--stream (alist-get 'frame value))))))
                  ("error" (message "emacs-dsh stream: %s"
                                    (alist-get 'message (alist-get 'error data))))))))
          (error (message "emacs-dsh frame: %s" (error-message-string err))))))))

(defun emacs-dsh--stream-open (stream-id endpoint)
  "Open one no-argument remote stream on the multiplexed socket."
  (json-serialize `((type . "open") (streamId . ,stream-id)
                    (endpoint . ,endpoint)
                    (payload . ((args . ,(make-hash-table)))))))

(defun emacs-dsh--events-result (entry outcome)
  "Reply to waterfall ENTRY using OUTCOME on its original generation."
  (when (and (equal (nth 0 entry) emacs-dsh--events-client)
             (not (member (nth 1 entry) emacs-dsh--events-cancelled)))
    (let ((chat (gethash (nth 2 entry) emacs-dsh--chats)))
      (with-current-buffer (if (buffer-live-p chat) chat (current-buffer))
        (emacs-dsh--call
         "$events/result"
         `((clientId . ,(nth 0 entry)) (eventId . ,(nth 1 entry))
           (outcome . ,outcome))
         (lambda (_value) nil)
         (lambda (error) (message "emacs-dsh: interaction reply failed: %s" error)))))))

(defun emacs-dsh--question-answer (question)
  "Read one QUESTION and return its wire answer.  Empty input skips it."
  (let* ((id (alist-get 'id question))
         (options (alist-get 'options question))
         (labels (mapcar (lambda (option) (alist-get 'label option)) options))
         (multi (alist-get 'multiSelect question))
         (prompt (format "%s%s%s: " (or (alist-get 'question question) "Question")
                         (if-let* ((detail (alist-get 'detail question)))
                             (format " — %s" detail) "")
                         (if multi " (comma-separated; empty skips)" " (empty skips)")))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate)
               (when-let* ((option (cl-find candidate options
                                            :key (lambda (o) (alist-get 'label o))
                                            :test #'equal))
                           (description (alist-get 'description option)))
                 (concat "  " description)))))
         (raw (if multi (completing-read-multiple prompt labels nil nil)
                (list (completing-read prompt labels nil nil))))
         (answers (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim raw)))
         (selected (cl-remove-if-not (lambda (answer) (member answer labels)) answers))
         (custom (string-join
                  (cl-remove-if (lambda (answer) (member answer labels)) answers) ", ")))
    (append `((id . ,id) (selected . ,(vconcat selected)))
            (unless (string-empty-p custom) `((custom . ,custom))))))

(defun emacs-dsh--events-answer (entry)
  "Prompt for one queued ENTRY, then reply to its host waterfall."
  (let ((event (nth 3 entry)) (request (nth 4 entry))
        (emacs-dsh--events-prompting entry))
    (condition-case err
        (pcase event
          ("approval/request"
           (let ((choice (completing-read
                          (format "Allow %s%s? "
                                  (or (alist-get 'toolName request) "tool")
                                  (if-let* ((reason (alist-get 'reason request)))
                                      (format " (%s)" reason) ""))
                          '("Deny" "Allow once") nil t)))
             (emacs-dsh--events-result
              entry `((kind . "result")
                      (value . ,(if (equal choice "Allow once")
                                    "allowed-once" "rejected"))))))
          ("user-questions/request"
           (let ((answers (mapcar #'emacs-dsh--question-answer
                                  (alist-get 'questions request))))
             (emacs-dsh--events-result
              entry `((kind . "result") (value . ((answers . ,(vconcat answers)))))))))
      (quit
       (emacs-dsh--events-result
        entry (if (equal event "approval/request")
                  '((kind . "next"))
                '((kind . "rejected")
                  (error . ((name . "cancelled")
                            (message . "User abandoned the questions")))))))
      (error
       (message "emacs-dsh: interaction failed: %s" (error-message-string err))
       (emacs-dsh--events-result entry '((kind . "next")))))
  (when-let* ((chat (gethash (nth 2 entry) emacs-dsh--chats))
              ((buffer-live-p chat)))
    (with-current-buffer chat
      (setq emacs-dsh--waiting nil)
      (force-mode-line-update)))))

(defun emacs-dsh--events-drain ()
  "Serialize host questions and approvals in Emacs' single minibuffer."
  (if (active-minibuffer-window)
      (when (and emacs-dsh--events-queue (not emacs-dsh--events-active))
        (run-at-time 0.2 nil #'emacs-dsh--events-drain))
    (unless emacs-dsh--events-active
      (while (and emacs-dsh--events-queue (not (active-minibuffer-window)))
        (let ((entry (pop emacs-dsh--events-queue)))
          (unless (member (nth 1 entry) emacs-dsh--events-cancelled)
            (setq emacs-dsh--events-active entry)
            (unwind-protect
                (if (buffer-live-p (gethash (nth 2 entry) emacs-dsh--chats))
                    (emacs-dsh--events-answer entry)
                  (emacs-dsh--events-result entry '((kind . "next"))))
              (setq emacs-dsh--events-active nil))))))))

(defun emacs-dsh--events-frame (socket frame)
  "Handle a host-wide $events FRAME from SOCKET."
  (when (eq socket emacs-dsh--events-socket)
    (condition-case err
        (let* ((message (json-parse-string (websocket-frame-payload frame)
                                           :object-type 'alist :array-type 'list))
               (value (alist-get 'value message))
               (event-id (alist-get 'eventId value)))
          (when (equal (alist-get 'type message) "item")
            (pcase (alist-get 'type value)
              ("ready" (setq emacs-dsh--events-client (alist-get 'clientId value)
                              emacs-dsh--events-queue nil
                              emacs-dsh--events-cancelled nil))
              ("cancel"
               (push event-id emacs-dsh--events-cancelled)
               (let* ((entry (or (and (equal event-id (nth 1 emacs-dsh--events-active))
                                      emacs-dsh--events-active)
                                 (cl-find event-id emacs-dsh--events-queue
                                          :key #'cadr :test #'equal)))
                      (chat (and entry (gethash (nth 2 entry) emacs-dsh--chats))))
                 (when (buffer-live-p chat)
                   (with-current-buffer chat
                     (setq emacs-dsh--waiting nil)
                     (force-mode-line-update))))
               (setq emacs-dsh--events-queue
                     (cl-remove-if (lambda (entry) (equal event-id (nth 1 entry)))
                                   emacs-dsh--events-queue))
               (when (and (equal event-id (nth 1 emacs-dsh--events-prompting))
                          (active-minibuffer-window))
                 (abort-recursive-edit)))
              ("waterfall"
               (when (and emacs-dsh--events-client event-id
                          (member (alist-get 'event value)
                                  '("approval/request" "user-questions/request")))
                 (let ((entry (list emacs-dsh--events-client event-id
                                    (alist-get 'agentId value)
                                    (alist-get 'event value)
                                    (alist-get 'request value))))
                   (unless (or (equal event-id (nth 1 emacs-dsh--events-active))
                               (cl-find event-id emacs-dsh--events-queue
                                        :key #'cadr :test #'equal))
                     (setq emacs-dsh--events-queue
                           (nconc emacs-dsh--events-queue (list entry)))
                     (when-let* ((chat (gethash (nth 2 entry) emacs-dsh--chats))
                                 ((buffer-live-p chat)))
                       (with-current-buffer chat
                         (setq emacs-dsh--waiting
                               (if (equal (nth 3 entry) "approval/request")
                                   "approval needed" "answer needed"))
                         (force-mode-line-update)))
                     (run-at-time 0 nil #'emacs-dsh--events-drain))))))))
      (error (message "emacs-dsh: host interaction frame: %s"
                      (error-message-string err))))))

(defun emacs-dsh--events-connect ()
  "Keep one $events socket subscribed for all open chat buffers."
  (when (and emacs-dsh--cookie-jar (not emacs-dsh--events-socket))
    (when emacs-dsh--events-retry
      (cancel-timer emacs-dsh--events-retry)
      (setq emacs-dsh--events-retry nil))
    (let* ((base (emacs-dsh--base))
           (socket-url (concat (if (string-prefix-p "https:" base) "wss" "ws")
                               (substring base (if (string-prefix-p "https:" base) 5 4))
                               "api/remote.mux")))
      (condition-case err
          (setq emacs-dsh--events-socket
                (websocket-open
                 socket-url
                 :custom-header-alist `(("Cookie" . ,emacs-dsh--cookie-jar))
                 :on-open (lambda (ws)
                            (when (eq ws emacs-dsh--events-socket)
                              (websocket-send-text
                               ws (emacs-dsh--stream-open "dsh-events" "$events"))))
                 :on-message #'emacs-dsh--events-frame
                 :on-close (lambda (ws)
                             (when (eq ws emacs-dsh--events-socket)
                               (setq emacs-dsh--events-socket nil
                                     emacs-dsh--events-client nil
                                     emacs-dsh--events-queue nil)
                               (maphash (lambda (_id chat)
                                          (when (buffer-live-p chat)
                                            (with-current-buffer chat
                                              (setq emacs-dsh--waiting nil)
                                              (force-mode-line-update))))
                                        emacs-dsh--chats)
                               (when (and emacs-dsh--events-prompting
                                          (active-minibuffer-window))
                                 (abort-recursive-edit))
                               (when (> (hash-table-count emacs-dsh--chats) 0)
                                 (setq emacs-dsh--events-retry
                                       (run-at-time 3 nil #'emacs-dsh--events-reconnect)))))
                 :on-error (lambda (_ws _phase error)
                             (message "emacs-dsh $events: %s" error))))
        (error
         (message "emacs-dsh $events: %s" (error-message-string err))
         (when (> (hash-table-count emacs-dsh--chats) 0)
           (setq emacs-dsh--events-retry
                 (run-at-time 3 nil #'emacs-dsh--events-reconnect))))))))

(defun emacs-dsh--events-reconnect ()
  "Reauthenticate before reopening the host interaction stream."
  (setq emacs-dsh--events-retry nil)
  (when (> (hash-table-count emacs-dsh--chats) 0)
    (emacs-dsh--ensure-auth
     (lambda (failure)
       (if failure
           (setq emacs-dsh--events-retry
                 (run-at-time 3 nil #'emacs-dsh--events-reconnect))
         (emacs-dsh--events-connect))))))

(defun emacs-dsh--follow-payload (&optional session-id max-messages)
  "Return a Remote follow frame for SESSION-ID or the current chat.
MAX-MESSAGES limits history included in the first snapshot."
  (setq session-id (or session-id emacs-dsh--session-id))
  (let ((address (list (cons 'kind "session")
                       (cons 'sessionId session-id))))
    (json-serialize
     (list (cons 'type "open")
           (cons 'streamId session-id)
           (cons 'endpoint "session/follow")
           (cons 'payload
                 (list (cons 'args
                             (list (cons 'request
                                         (list (cons 'address address)
                                               (cons 'maxMessages
                                                     (or max-messages emacs-dsh-max-messages))
                                               (cons 'assistantStream t)))))))))))

(defun emacs-dsh--follow ()
  (when emacs-dsh--session-id
    (when emacs-dsh--retry-timer
      (cancel-timer emacs-dsh--retry-timer)
      (setq emacs-dsh--retry-timer nil))
     (let ((old emacs-dsh--socket))
      (setq emacs-dsh--socket nil)
       (when old (websocket-close old)))
     (setq emacs-dsh--queue-seq -1 emacs-dsh--queue-ready nil)
    (let* ((buffer (current-buffer))
           (base (emacs-dsh--base))
           (scheme (if (string-prefix-p "https:" base) "wss" "ws"))
           (url (concat scheme (substring base (if (equal scheme "wss") 5 4)))))
      (let ((url-cookie-storage nil)
            (url-cookie-secure-storage nil))
        (condition-case err
          (setq emacs-dsh--socket
                (websocket-open
                 (concat url "api/remote.mux")
                 :custom-header-alist
                 (and emacs-dsh--cookie-jar
                      (list (cons "Cookie" emacs-dsh--cookie-jar)))
                 :on-open
                 (lambda (ws)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                        (when (eq ws emacs-dsh--socket)
                           (websocket-send-text ws (emacs-dsh--follow-payload))
                           (websocket-send-text ws (emacs-dsh--control-payload))))))
                 :on-message
                 (lambda (ws frame) (emacs-dsh--on-frame buffer ws frame))
                 :on-error
                 (lambda (_ws _phase error)
                   (message "emacs-dsh WebSocket: %s" error))
                 :on-close
                 (lambda (ws)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (and (eq ws emacs-dsh--socket)
                                  (not emacs-dsh--closing))
                         (setq emacs-dsh--socket nil
                               emacs-dsh--retry-timer
                               (run-at-time 3 nil #'emacs-dsh--retry buffer))))))))
        (error
         (message "emacs-dsh: WebSocket failed: %s" (error-message-string err))
         (setq emacs-dsh--retry-timer
               (run-at-time 3 nil #'emacs-dsh--retry buffer))))))))

(defun emacs-dsh--retry (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacs-dsh--retry-timer nil)
      (unless emacs-dsh--closing
        (emacs-dsh--invalidate-auth)
        (emacs-dsh--ensure-auth
         (lambda (failure)
           (if failure
               (progn
                 (message "emacs-dsh: reconnect: %s" failure)
                 (setq emacs-dsh--retry-timer
                       (run-at-time 3 nil #'emacs-dsh--retry buffer)))
             (emacs-dsh--follow))))))))

(defun emacs-dsh--refresh-model-selection ()
  "Read this Session's current or default model without activating an Agent."
  (emacs-dsh--call
   "session/projections" `((request . ((sessionId . ,emacs-dsh--session-id))))
   (lambda (value)
     (let ((selection (alist-get 'next
                                 (alist-get 'modelSelection (alist-get 'values value)))))
       (cond
        ((and selection (not emacs-dsh--model-selection))
         (setq emacs-dsh--model-selection selection)
         (force-mode-line-update))
        ((not selection)
         ;; Blank Sessions have no durable selection until their first request.
         (emacs-dsh--call
          "session/modelCatalog" (make-hash-table)
          (lambda (catalog)
            (unless emacs-dsh--model-selection
              (setq emacs-dsh--model-selection (alist-get 'default catalog))
              (force-mode-line-update)))
          (lambda (failure)
            (message "emacs-dsh: default model unavailable: %s" failure)))))))
   (lambda (failure)
     (message "emacs-dsh: model selection unavailable: %s" failure))))

(defun emacs-dsh--show (id root)
  (let* ((local-root (emacs-dsh--local-path root))
         (root (if (and local-root (file-directory-p local-root))
                   local-root (emacs-dsh--project-root)))
         (existing (gethash id emacs-dsh--chats)))
    (if (buffer-live-p existing)
        (switch-to-buffer existing)
      (let* ((directory (file-name-nondirectory (directory-file-name root)))
             (buffer (generate-new-buffer
                      (format "*emacs-dsh:%s*"
                              (if (string-empty-p directory) "/" directory)))))
        (puthash id buffer emacs-dsh--chats)
        (switch-to-buffer buffer)
        (emacs-dsh-chat-mode)
        (setq-local default-directory (file-name-as-directory root))
        (setq-local emacs-dsh--root root)
        (setq-local emacs-dsh--session-id id)
        (emacs-dsh--compose)
        (emacs-dsh--follow)
        (emacs-dsh--events-connect)
        (emacs-dsh--refresh-model-selection)))))

(defconst emacs-dsh--preset-names
  '(("standard" . "Standard") ("code" . "PTC")
    ("minimal" . "Minimal") ("cordis" . "Creator")))

(defun emacs-dsh--preset-choices (roster)
  "Return selectable display names and ids from the Host ROSTER."
  (delq nil (mapcar (lambda (row)
                      (unless (alist-get 'broken row)
                        (let ((id (alist-get 'id row)))
                          (cons (format "%s (%s)" (or (alist-get 'name row)
                                                       (cdr (assoc id emacs-dsh--preset-names))
                                                       id) id) id))))
                    (alist-get 'presets roster))))

(defun emacs-dsh--pick-preset (callback)
  "Ask for a Host-advertised preset, then call CALLBACK with its id."
  (emacs-dsh--call
   "agentPresets/list" (make-hash-table)
   (lambda (roster)
     (let ((choices (emacs-dsh--preset-choices roster)))
       (if (null choices)
           (message "emacs-dsh: no selectable modes")
         (emacs-dsh--defer-picker
          (lambda ()
            (let ((choice (condition-case nil
                              (completing-read "DSH mode: " choices nil t)
                            (quit nil))))
              (when (and choice (not (string-empty-p choice)))
                (funcall callback (cdr (assoc choice choices))))))))))
   (lambda (failure) (message "emacs-dsh: modes unavailable: %s" failure))))

;;;###autoload
(defun emacs-dsh-chat (&optional root choose-mode)
  "Create a DSH Session in ROOT using Standard by default.
With prefix CHOOSE-MODE, select a preset before creation."
  (interactive (list (read-directory-name "DSH root: " (emacs-dsh--project-root) nil t)
                     current-prefix-arg))
  (setq root (file-name-as-directory (expand-file-name (or root (emacs-dsh--project-root)))))
  (if choose-mode
      (emacs-dsh--pick-preset
       (lambda (preset) (emacs-dsh--create-session root preset)))
    (emacs-dsh--create-session root "standard")))

(defun emacs-dsh--set-default-permission (session catalog root)
  "Set SESSION permission from CATALOG before displaying chat ROOT."
  (let ((permission (if (and (equal emacs-dsh-default-permission "auto")
                             (not (cl-find "auto" (alist-get 'options catalog)
                                           :key (lambda (option) (alist-get 'value option))
                                           :test #'equal)))
                        "danger-full-access" emacs-dsh-default-permission)))
    (emacs-dsh--call
     "commands/execute"
     `((agentId . ,session) (line . ,(concat "/permission " permission))
       (submittedAttachments . []))
     (lambda (value)
       (let ((result (alist-get 'result value)))
         (emacs-dsh--show session root)
         (unless (equal (alist-get 'kind result) "success")
           (message "emacs-dsh: default permission %s was not accepted" permission))))
     (lambda (failure)
       (emacs-dsh--show session root)
       (message "emacs-dsh: default permission unavailable: %s" failure)))))

(defun emacs-dsh--create-session (root preset)
  "Create a session in ROOT with optional PRESET."
  (emacs-dsh--call
   "session/create"
   `((request . ,(append `((cwd . ,(emacs-dsh--host-path root)))
                          (when preset `((agentPreset . ,preset))))))
   (lambda (value)
     (let ((session (alist-get 'sessionId value)))
       (emacs-dsh--call
        "permissionPresets/catalog" (make-hash-table)
        (lambda (catalog)
          (emacs-dsh--set-default-permission session catalog root))
        (lambda (_failure)
          (emacs-dsh--set-default-permission session nil root)))))))

;;;###autoload
(defun emacs-dsh-select-mode ()
  "Select a DSH agent preset for the current blank session."
  (interactive)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (emacs-dsh--pick-preset
   (lambda (preset)
     (emacs-dsh--call
      "agentPresets/select" `((agentId . ,emacs-dsh--session-id)
                              (agentPreset . ,preset))
      (lambda (_value)
        (setq emacs-dsh--agent-preset preset emacs-dsh--command-inflight nil)
        (when (string-prefix-p "/mode" (emacs-dsh--draft-text))
          (emacs-dsh--replace-draft ""))
        (force-mode-line-update))
      (lambda (failure)
        (setq emacs-dsh--command-inflight nil)
        (message "emacs-dsh: mode selection failed (only blank sessions): %s" failure))))))

;;;###autoload
(defun emacs-dsh-resume ()
  "Choose a persisted DSH Session by creation time, ID, and first prompt."
  (interactive)
  (emacs-dsh--call
   "session/list" `((_request . ,(make-hash-table)))
   (lambda (value)
     (let ((items (alist-get 'items value)))
       (if items
           (emacs-dsh--resume-picker items)
         (message "emacs-dsh: no sessions"))))))

(defun emacs-dsh--session-creation-times (items callback)
  "Read immutable creation times for ITEMS, then call CALLBACK.
The Session list only exposes last activity; follow snapshots contain the
actual creation time.  Read all missing snapshots over one temporary socket."
  (let* ((origin (current-buffer))
         (pending (make-hash-table :test #'equal))
         (socket nil) (timer nil) (done nil))
    (dolist (item items)
      (let ((id (alist-get 'sessionId item))
            (created (alist-get 'createdAt item)))
        (if (numberp created)
            (puthash id created emacs-dsh--created-at)
          (unless (gethash id emacs-dsh--created-at)
            (puthash id t pending)))))
    (if (= (hash-table-count pending) 0)
        (funcall callback)
      (cl-labels
          ((finish ()
             (unless done
               (setq done t)
               (when timer (cancel-timer timer))
               (when socket (websocket-close socket))
               (when (buffer-live-p origin)
                 (with-current-buffer origin (funcall callback))))))
        (let* ((base (emacs-dsh--base))
               (scheme (if (string-prefix-p "https:" base) "wss" "ws"))
               (url (concat scheme (substring base (if (equal scheme "wss") 5 4))
                            "api/remote.mux"))
               (url-cookie-storage nil)
               (url-cookie-secure-storage nil))
          (setq timer (run-at-time 8 nil #'finish))
          (condition-case err
              (setq socket
                    (websocket-open
                     url
                     :custom-header-alist
                     (and emacs-dsh--cookie-jar
                          (list (cons "Cookie" emacs-dsh--cookie-jar)))
                     :on-open
                     (lambda (ws)
                       (maphash (lambda (id _)
                                  (websocket-send-text
                                   ws (emacs-dsh--follow-payload id 1)))
                                pending))
                     :on-message
                     (lambda (_ws frame)
                       (condition-case err
                           (let* ((data (json-parse-string
                                         (websocket-frame-payload frame)
                                         :object-type 'alist :array-type 'list))
                                  (id (alist-get 'streamId data))
                                  (value (alist-get 'value data)))
                             (when (gethash id pending)
                               (when (and (equal (alist-get 'type data) "item")
                                          (equal (alist-get 'type value) "snapshot"))
                                 (when-let* ((created (alist-get 'createdAt
                                                                (alist-get 'header value))))
                                   (puthash id created emacs-dsh--created-at))
                                 (remhash id pending))
                               (when (equal (alist-get 'type data) "error")
                                 (remhash id pending))
                               (when (= (hash-table-count pending) 0)
                                 (finish))))
                         (error
                          (message "emacs-dsh: session date frame: %s"
                                   (error-message-string err)))))
                     :on-error (lambda (_ws _phase _error) (finish))
                     :on-close (lambda (_ws) (finish))))
            (error (message "emacs-dsh: session dates unavailable: %s"
                            (error-message-string err))
                   (finish))))))))

(defun emacs-dsh--workspace-label (item)
  "Return ITEM's working directory as a readable workspace label."
  (let ((path (emacs-dsh--local-path (alist-get 'cwd item))))
    (if (and (stringp path) (not (string-empty-p path)))
        (abbreviate-file-name (directory-file-name path))
      "(unknown)")))

(defun emacs-dsh--resume-picker (items)
  "Show all visible sessions with aligned time, ID, workspace, and preview."
  (let* ((id-width (apply #'max (mapcar (lambda (item)
                                         (string-width (alist-get 'sessionId item)))
                                       items)))
         (workspace-width (apply #'max (mapcar (lambda (item)
                                                (string-width (emacs-dsh--workspace-label item)))
                                              items)))
         (choices (mapcar (lambda (item)
                            (cons (emacs-dsh--session-choice-label
                                   item id-width workspace-width)
                                  item))
                          items)))
    (emacs-dsh--defer-picker
     (lambda ()
       (when-let* ((choice (cdr (assoc
                                  (completing-read
                                   "Resume DSH (time | session ID | workspace | prompt): "
                                   choices nil t)
                                  choices))))
         (let ((source (current-buffer))
               (id (alist-get 'sessionId choice)))
           (when (or (not (derived-mode-p 'emacs-dsh-chat-mode))
                     (equal id emacs-dsh--session-id)
                     (and (string-empty-p (emacs-dsh--draft-text))
                          (null emacs-dsh--attachments))
                     (yes-or-no-p "Discard unsent DSH draft and switch sessions? "))
             (let* ((cwd (or (alist-get 'cwd choice) default-directory))
                    (local (emacs-dsh--local-path cwd))
                    (target (if (and local (file-directory-p local))
                                local (emacs-dsh--project-root)))
                    (name (format "*emacs-dsh:%s*"
                                  (file-name-nondirectory (directory-file-name target)))))
               (when (and (buffer-live-p source)
                          (not (equal id emacs-dsh--session-id))
                          (equal (buffer-name source) name))
                 (kill-buffer source))
               (emacs-dsh--show id cwd))
             (when (and (buffer-live-p source)
                        (not (eq source (current-buffer))))
               (with-current-buffer source
                 (when (derived-mode-p 'emacs-dsh-chat-mode)
                   (kill-buffer source)))))))))))

(defun emacs-dsh--session-choice-label (item &optional id-width workspace-width)
  "Format ITEM as aligned time, ID, workspace, and first prompt columns."
  (let* ((values (alist-get 'values (alist-get 'projections item)))
         (outline (alist-get 'turnOutline values))
         (first-prompt (and outline (alist-get 'prompt (car outline))))
         (title (alist-get 'title values))
         (preview (cond ((and (stringp first-prompt)
                             (not (string-empty-p first-prompt))) first-prompt)
                        ((and (stringp title) (not (string-empty-p title))) title)
                        (t "(empty session)")))
         (clean (replace-regexp-in-string "[[:space:]\n\r]+" " " preview))
         (id (alist-get 'sessionId item))
         (workspace (emacs-dsh--workspace-label item))
         (created (or (gethash id emacs-dsh--created-at)
                      (alist-get 'createdAt item)
                      (alist-get 'updatedAt item)))
         (date (if (numberp created)
                   (format-time-string "%Y-%m-%d %H:%M"
                                       (seconds-to-time (/ created 1000.0)))
                 "unknown")))
    (concat (format "%-16s  " date)
            id (make-string (max 0 (- (or id-width (string-width id))
                                      (string-width id))) ?\s)
            "  " workspace
            (make-string (max 0 (- (or workspace-width (string-width workspace))
                                   (string-width workspace))) ?\s)
            "  " (truncate-string-to-width clean 76 nil nil "…"))))

(defun emacs-dsh--model-candidates (catalog)
  "Return completion entries for the routable models in CATALOG."
  (cl-loop for group in (alist-get 'groups catalog)
           append (cl-loop for model in (alist-get 'models group)
                           for provider = (alist-get 'id group)
                           for id = (alist-get 'id model)
                           for name = (alist-get 'name model)
                           collect
                           (cons (format "%s/%s%s" provider id
                                         (if (and name (not (equal name id)))
                                             (format " — %s" name) ""))
                                 `((provider . ,provider) (model . ,id)
                                   (reasoning . ,(alist-get 'reasoning model)))))))

(defun emacs-dsh--matching-models (candidates input)
  "Return CANDIDATES matching model ID or provider-qualified INPUT."
  (if (string-empty-p input)
      candidates
    (cl-remove-if-not
     (lambda (entry)
       (let* ((model (cdr entry))
              (provider (alist-get 'provider model))
              (id (alist-get 'model model)))
         (or (equal input id)
             (equal input (concat provider "/" id))
             (equal input (concat provider ":" id)))))
     candidates)))

(defun emacs-dsh--choose-model (candidates)
  "Ask for one model from CANDIDATES, or return nil if cancelled."
  (condition-case nil
      (cdr (assoc (completing-read "DSH model: " candidates nil t)
                  candidates))
    (quit nil)))

(defun emacs-dsh--defer-picker (callback)
  "Run interactive CALLBACK outside the URL response callback."
  (let ((buffer (current-buffer)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer (funcall callback)))))))

(defun emacs-dsh--select-model (model draft &optional effort)
  "Install MODEL, optionally with EFFORT, then clear DRAFT on success."
  (let ((provider (alist-get 'provider model))
        (id (alist-get 'model model)))
    (emacs-dsh--call
     "session/selectModel"
     `((request . ,(append `((sessionId . ,emacs-dsh--session-id)
                            (provider . ,provider) (model . ,id))
                          (and effort `((reasoningEffort . ,effort))))))
     (lambda (value)
       (setq emacs-dsh--command-inflight nil
             emacs-dsh--model-selection (alist-get 'selected value))
       (when (equal (emacs-dsh--draft-text) draft)
         (emacs-dsh--replace-draft ""))
       (emacs-dsh--insert-before-input
        (format "[model] %s/%s%s" provider id
                (if-let* ((level (alist-get 'reasoningEffort emacs-dsh--model-selection)))
                    (concat " · " level) "")) 'shadow)
       (force-mode-line-update))
     (lambda (failure)
       (setq emacs-dsh--command-inflight nil)
       (message "emacs-dsh: model selection failed: %s" failure)))))

(defun emacs-dsh--model-command (draft)
  "Handle /model DRAFT using the Host model catalog."
  (let ((input (string-trim (substring draft (length "/model")))))
    (emacs-dsh--call
     "session/modelCatalog" (make-hash-table)
     (lambda (catalog)
       (let ((matches (emacs-dsh--matching-models
                       (emacs-dsh--model-candidates catalog) input)))
         (cond
          ((null matches)
           (setq emacs-dsh--command-inflight nil)
           (message "emacs-dsh: unknown model %s; use /model to choose" input))
          ((= (length matches) 1)
           (emacs-dsh--select-catalog-model (cdar matches) draft))
          (t
           (emacs-dsh--defer-picker
            (lambda ()
              (if-let* ((chosen (emacs-dsh--choose-model matches)))
                  (emacs-dsh--select-catalog-model chosen draft)
                (setq emacs-dsh--command-inflight nil))))))))
     (lambda (failure)
       (setq emacs-dsh--command-inflight nil)
       (message "emacs-dsh: model catalog failed: %s" failure)))))

(defun emacs-dsh--select-catalog-model (chosen draft)
  "Select CHOSEN model, retaining the current effort when possible."
  (emacs-dsh--select-model
   chosen draft
   (when (and emacs-dsh--model-selection
              (equal (alist-get 'provider chosen)
                     (alist-get 'provider emacs-dsh--model-selection))
              (equal (alist-get 'model chosen)
                     (alist-get 'model emacs-dsh--model-selection)))
     (alist-get 'reasoningEffort emacs-dsh--model-selection))))

(defun emacs-dsh--reasoning-command (draft)
  "Handle /reasoning DRAFT for the current model's supported levels."
  (let ((requested (string-trim (substring draft (length "/reasoning")))))
    (emacs-dsh--call
     "session/modelCatalog" (make-hash-table)
     (lambda (catalog)
       (let* ((selection (or emacs-dsh--model-selection
                             (alist-get 'default catalog)))
              (entry (cl-find-if
                      (lambda (candidate)
                        (let ((model (cdr candidate)))
                          (and (equal (alist-get 'provider model)
                                      (alist-get 'provider selection))
                               (equal (alist-get 'model model)
                                      (alist-get 'model selection)))))
                      (emacs-dsh--model-candidates catalog)))
              (efforts (alist-get 'efforts (alist-get 'reasoning (cdr entry))))
              (choices (mapcar (lambda (effort) (alist-get 'id effort)) efforts))
              (level (and (not (string-empty-p requested))
                          (member requested choices) requested)))
         (cond
          (level (emacs-dsh--select-model selection draft level))
          ((and choices (string-empty-p requested))
           (emacs-dsh--defer-picker
            (lambda ()
              (let ((chosen (condition-case nil
                                (completing-read "DSH reasoning: " choices nil t)
                              (quit nil))))
                (if (and chosen (not (string-empty-p chosen)))
                    (emacs-dsh--select-model selection draft chosen)
                  (setq emacs-dsh--command-inflight nil))))))
          (t
           (setq emacs-dsh--command-inflight nil)
           (message "emacs-dsh: no such reasoning level for %s/%s: %s"
                    (alist-get 'provider selection) (alist-get 'model selection)
                    (if choices (string-join choices ", ") "none"))))))
     (lambda (failure)
       (setq emacs-dsh--command-inflight nil)
       (message "emacs-dsh: reasoning catalog failed: %s" failure)))))

(defun emacs-dsh--submit-prompt (mode)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (when emacs-dsh--queue-edit (user-error "Finish the queue edit before sending"))
  (let* ((text (emacs-dsh--draft-text))
         (images emacs-dsh--attachments)
         (content (vconcat
                   (unless (string-empty-p text)
                     (list `((type . "text") (text . ,text))))
                   images))
         (id (emacs-dsh--uuid)))
    (when (zerop (length content)) (user-error "Write a prompt or attach an image first"))
    (puthash id (cons text images) emacs-dsh--pending)
    (setq emacs-dsh--history-index nil emacs-dsh--history-draft nil)
    (setq emacs-dsh--attachments nil)
    (emacs-dsh--update-image-preview)
    (emacs-dsh--replace-draft "")
    (force-mode-line-update)
    (emacs-dsh--call
     "session/prompt"
     `((request . ((requestId . ,id) (sessionId . ,emacs-dsh--session-id)
                   (mode . ,mode) (content . ,content))))
     (lambda (_value)
       (remhash id emacs-dsh--pending)
       (force-mode-line-update)
       (message "emacs-dsh: prompt accepted"))
     (lambda (failure)
       (remhash id emacs-dsh--pending)
       (setq emacs-dsh--attachments (append images emacs-dsh--attachments))
       (emacs-dsh--update-image-preview)
       (emacs-dsh--replace-draft
        (concat text (unless (string-empty-p (emacs-dsh--draft-text))
                       (concat "\n" (emacs-dsh--draft-text)))))
       (force-mode-line-update)
       (message "emacs-dsh: %s (draft restored)" failure)))))

(defun emacs-dsh--slash-name (draft)
  "Return DRAFT's DSH slash-command name, or nil for invalid syntax."
  (when (string-match "\\`/\\([a-z][a-z0-9_-]*\\)\\(?:\\'\\|[ \t\n\r]\\)" draft)
    (match-string 1 draft)))

(defun emacs-dsh--maybe-submit-skill (name draft mode)
  "Submit DRAFT as a prompt only if NAME is a registered skill."
  (emacs-dsh--call
   "skills/list" `((request . ((sessionId . ,emacs-dsh--session-id))))
   (lambda (value)
     (setq emacs-dsh--command-inflight nil)
     (cond
      ((not (equal draft (emacs-dsh--draft-text)))
       (message "emacs-dsh: draft changed; press send again"))
      ((cl-find name (alist-get 'skills value)
                :key (lambda (skill) (alist-get 'name skill)) :test #'equal)
       (emacs-dsh--submit-prompt mode))
      (t (message "emacs-dsh: unknown command or skill /%s" name))))
   (lambda (failure)
     (setq emacs-dsh--command-inflight nil)
     (message "emacs-dsh: skill lookup failed: %s" failure))))

(defun emacs-dsh--save-export-response (file status)
  "Write the current HTTP ZIP response to FILE, or signal its error."
  (goto-char (point-min))
  (when (plist-get status :error)
    (error "Export connection failed: %s" (plist-get status :error)))
  (unless (looking-at "HTTP/[0-9.]+ 200 ")
    (error "Export request failed: %s"
           (buffer-substring-no-properties (line-beginning-position)
                                           (line-end-position))))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "Export response has no body"))
  (unless (looking-at "PK")
    (error "Export response is not a ZIP archive"))
  (let ((coding-system-for-write 'no-conversion))
    (write-region (point) (point-max) file nil 'silent)))

(defun emacs-dsh--download-export (file &optional retry)
  "Download this Session's ZIP archive to FILE using the Host cookie."
  (let ((origin (current-buffer)))
    (emacs-dsh--ensure-auth
     (lambda (failure)
       (if failure
           (emacs-dsh--insert-before-input
            (format "[export error] %s" failure) 'error)
         (let* ((url (concat (emacs-dsh--base) "api/session.export?sessionId="
                             (url-hexify-string emacs-dsh--session-id)
                             "&includeDescendants=true"))
                (url-request-method "GET")
                (url-request-data nil)
                (url-request-extra-headers
                 `(("Authorization" . "") ("Cookie" . ,emacs-dsh--cookie-jar)))
                (url-proxy-services (cons '("no_proxy" . "127.0.0.1")
                                          url-proxy-services)))
           (emacs-dsh--url-retrieve
            url
            (lambda (status)
              (let ((unauthorized (save-excursion
                                    (goto-char (point-min))
                                    (looking-at "HTTP/[0-9.]+ 401 ")))
                    (problem nil))
                (unwind-protect
                    (unless (and unauthorized retry)
                      (condition-case err
                          (emacs-dsh--save-export-response file status)
                        (error (setq problem (error-message-string err)))))
                  (kill-buffer (current-buffer)))
                (when (buffer-live-p origin)
                  (with-current-buffer origin
                    (cond
                     ((and unauthorized retry)
                      (emacs-dsh--invalidate-auth)
                      (emacs-dsh--download-export file nil))
                     (problem
                      (emacs-dsh--insert-before-input
                       (format "[export error] %s" problem) 'error))
                     (t
                      (emacs-dsh--insert-before-input
                       (format "[export saved] %s" file) 'shadow))))))))))))))

(defun emacs-dsh--export-command ()
  "Ask where to save the ZIP produced by the successful /export command."
  (emacs-dsh--defer-picker
   (lambda ()
     (condition-case nil
         (let ((file (read-file-name
                      "Save DSH session ZIP: " emacs-dsh--root nil nil
                      (format "dsh-session-%s.zip" emacs-dsh--session-id))))
           (when (and (file-exists-p file)
                      (not (yes-or-no-p (format "Overwrite %s? " file))))
             (user-error "Export cancelled"))
           (emacs-dsh--download-export file t))
       (quit (message "emacs-dsh: export cancelled"))
       (user-error (message "emacs-dsh: export cancelled"))))))

(defun emacs-dsh--execute-command (name draft mode)
  "Run native DSH command DRAFT, falling back only to a known skill NAME."
  (let ((images emacs-dsh--attachments))
    (emacs-dsh--call
     "commands/execute"
     `((agentId . ,emacs-dsh--session-id) (line . ,draft)
       (submittedAttachments . ,(vconcat images)))
     (lambda (value)
       (if (null value)
           (emacs-dsh--maybe-submit-skill name draft mode)
         (let* ((result (alist-get 'result value))
                (kind (alist-get 'kind result))
                (output (alist-get 'text result)))
           (setq emacs-dsh--command-inflight nil)
           (if (equal kind "success")
               (progn
                 (when (equal draft (emacs-dsh--draft-text))
                   (emacs-dsh--replace-draft ""))
                 (when (equal images (cl-subseq emacs-dsh--attachments
                                               0 (min (length images)
                                                      (length emacs-dsh--attachments))))
                   (setq emacs-dsh--attachments
                         (nthcdr (length images) emacs-dsh--attachments))
                   (emacs-dsh--update-image-preview))
                 (force-mode-line-update)
                 (emacs-dsh--insert-before-input
                  (format "[command %s] %s" draft (or output "done")) 'shadow)
                 (when (and (equal name "export")
                            (string-match-p "\\`/export[[:space:]]*\\'" draft))
                   (emacs-dsh--export-command)))
             (emacs-dsh--insert-before-input
              (format "[command error %s] %s" draft (or output "command failed"))
              'error)))))
     (lambda (failure)
       (setq emacs-dsh--command-inflight nil)
       (emacs-dsh--insert-before-input
        (format "[command error %s] %s" draft failure) 'error)))))

(defun emacs-dsh--permission-command ()
  "Choose a Host-advertised permission for the current session."
  (emacs-dsh--call
   "permissionPresets/catalog" (make-hash-table)
   (lambda (catalog)
     (let ((choices (mapcar (lambda (item)
                              (cons (format "%s (%s)"
                                            (alist-get 'name item)
                                            (alist-get 'value item))
                                    (alist-get 'value item)))
                            (alist-get 'options catalog))))
       (if choices
           (emacs-dsh--defer-picker
            (lambda ()
              (when-let* ((selection (cdr (assoc (completing-read
                                                  "DSH permission: " choices nil t)
                                                 choices))))
                (emacs-dsh--execute-command
                 "permission" (concat "/permission " selection) nil))))
         (message "emacs-dsh: no permissions available"))))
   (lambda (failure)
     (message "emacs-dsh: permissions unavailable: %s" failure))))

;;;###autoload
(defun emacs-dsh-permission ()
  "Choose a permission preset for this DSH session."
  (interactive)
  (unless (and (derived-mode-p 'emacs-dsh-chat-mode) emacs-dsh--session-id)
    (user-error "Not in a DSH chat"))
  (emacs-dsh--permission-command))

(defun emacs-dsh--help-command (draft)
  "Display the available native commands and local controls."
  (emacs-dsh--call
   "commands/list" `((agentId . ,emacs-dsh--session-id))
   (lambda (commands)
     (setq emacs-dsh--command-inflight nil)
     (when (equal draft (emacs-dsh--draft-text))
       (emacs-dsh--replace-draft ""))
     (emacs-dsh--insert-before-input
       (concat "Commands: /model, /reasoning, /mode, /new, /resume, /queue, /file, /status, /help; Host: "
              (mapconcat (lambda (command)
                           (concat "/" (alist-get 'name command)))
                         commands ", ")
              ". Registered /skill-name entries also work as prompts.")
      'shadow))
   (lambda (failure)
     (setq emacs-dsh--command-inflight nil)
     (message "emacs-dsh: command list failed: %s" failure))))

(defun emacs-dsh--submit-slash (mode draft)
  "Route DRAFT to the command plane or to a known skill."
  (let ((name (emacs-dsh--slash-name draft)))
    (unless name (user-error "Invalid slash command syntax"))
    (when emacs-dsh--command-inflight
      (user-error "A command is already in progress"))
    (setq emacs-dsh--command-inflight t)
    (cond
     ((equal name "model")
      (if emacs-dsh--attachments
          (progn (setq emacs-dsh--command-inflight nil)
                 (user-error "Send or remove staged images before /model"))
        (emacs-dsh--model-command draft)))
     ((equal name "reasoning")
      (if emacs-dsh--attachments
          (progn (setq emacs-dsh--command-inflight nil)
                 (user-error "Send or remove staged images before /reasoning"))
        (emacs-dsh--reasoning-command draft)))
     ((equal name "mode")
      (if emacs-dsh--attachments
          (progn (setq emacs-dsh--command-inflight nil)
                 (user-error "Send staged images before /mode"))
        (emacs-dsh-select-mode)))
     ((equal name "new")
      (setq emacs-dsh--command-inflight nil)
      (emacs-dsh--replace-draft "")
      (emacs-dsh-chat emacs-dsh--root))
     ((equal name "resume")
       (setq emacs-dsh--command-inflight nil)
       (emacs-dsh--replace-draft "")
       (emacs-dsh-resume))
     ((equal name "queue")
      (setq emacs-dsh--command-inflight nil)
      (emacs-dsh--replace-draft "")
      (emacs-dsh-queue))
     ((equal name "file")
      (setq emacs-dsh--command-inflight nil)
      (emacs-dsh--replace-draft "")
      (call-interactively #'emacs-dsh-insert-file))
     ((equal name "status")
      (setq emacs-dsh--command-inflight nil)
      (emacs-dsh--replace-draft "")
      (emacs-dsh--insert-before-input (string-trim (substring-no-properties
                                                    (emacs-dsh--state))) 'shadow))
     ((equal name "permission")
      (emacs-dsh--execute-command name draft mode))
     ((equal name "help") (emacs-dsh--help-command draft))
     (t (emacs-dsh--execute-command name draft mode)))))

(defun emacs-dsh--submit (mode)
  "Send the current draft as a command, skill, or ordinary prompt."
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (when emacs-dsh--queue-edit (user-error "Finish the queue edit before sending"))
  (let ((draft (emacs-dsh--draft-text)))
    (if (string-prefix-p "/" draft)
        (emacs-dsh--submit-slash mode draft)
      (emacs-dsh--submit-prompt mode))))

;;;###autoload
(defun emacs-dsh-send () "Submit the draft as a command, skill, or queued prompt." (interactive) (emacs-dsh--submit "queue"))
;;;###autoload
(defun emacs-dsh-steer () "Steer a running turn with the draft." (interactive) (emacs-dsh--submit "steer"))
;;;###autoload
(defun emacs-dsh-cancel ()
  "Cancel the active turn (pending messages remain queued)."
  (interactive)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (emacs-dsh--call "session/cancel" `((request . ((sessionId . ,emacs-dsh--session-id))))
                   (lambda (_) (message "emacs-dsh: cancelled"))))

(defun emacs-dsh--queue-text (item)
  "Return a short display string for queue ITEM."
  (let ((content (alist-get 'content item)))
    (string-trim
     (replace-regexp-in-string
      "[[:space:]\n\r]+" " "
      (or (emacs-dsh--content content) "[attachment]")))))

(defun emacs-dsh--queue-update (item kind &optional content on-success)
  "Apply KIND to ITEM, using CONTENT blocks for an edit."
  (let ((action (append `((kind . ,kind))
                        (when (equal kind "edit")
                          `((content . ,(vconcat content)))))))
    (emacs-dsh--call
     "session/updateQueue"
     `((request . ((sessionId . ,emacs-dsh--session-id)
                   (itemId . ,(alist-get 'id item)) (action . ,action))))
     (lambda (_)
       (when on-success (funcall on-success))
       (message "emacs-dsh: queue %s accepted" kind))
     (lambda (failure) (message "emacs-dsh: queue %s failed: %s" kind failure)))))

(defun emacs-dsh--queue-edit-keymap-refresh ()
  "Use queue-edit composer bindings only while editing."
  (when-let* ((widget (emacs-dsh--input-widget)))
    (widget-put widget :keymap (if emacs-dsh--queue-edit
                                   emacs-dsh--queue-edit-input-keymap
                                 emacs-dsh--input-keymap))
    (widget-setup)))

(defun emacs-dsh--queue-edit-finish ()
  "Return to the draft saved before queue editing."
  (when emacs-dsh--queue-edit
    (pcase-let ((`(,_item ,draft ,images) emacs-dsh--queue-edit))
      (setq emacs-dsh--queue-edit nil
            emacs-dsh--attachments images)
      (emacs-dsh--queue-edit-keymap-refresh)
      (emacs-dsh--replace-draft draft)
      (emacs-dsh--update-image-preview)
      (force-mode-line-update))))

(defun emacs-dsh--queue-edit-start (item)
  "Edit pending ITEM using this chat's composer and image preview."
  (when emacs-dsh--queue-edit (user-error "Finish the current queue edit first"))
  (let* ((content (alist-get 'content item))
         (parts (if (vectorp content) (append content nil) content))
         (text (mapconcat (lambda (part)
                            (if (equal (alist-get 'type part) "text")
                                (or (alist-get 'text part) "") ""))
                          parts "\n"))
         (images (cl-remove-if-not
                  (lambda (part) (equal (alist-get 'type part) "image")) parts)))
    (setq emacs-dsh--queue-edit (list item (emacs-dsh--draft-text)
                                      emacs-dsh--attachments)
          emacs-dsh--attachments images)
    (emacs-dsh--queue-edit-keymap-refresh)
    (emacs-dsh--replace-draft text)
    (emacs-dsh--update-image-preview)
    (emacs-dsh-focus-input)
    (message "Editing queue: C-c C-c/RET save, C-c C-k abort; paste or click images")))

(defun emacs-dsh-queue-edit-abort ()
  "Discard the queue edit and restore the previous draft and images."
  (interactive)
  (unless emacs-dsh--queue-edit (user-error "No queue edit in progress"))
  (emacs-dsh--queue-edit-finish)
  (message "emacs-dsh: queue edit cancelled"))

(defun emacs-dsh-queue-edit-save ()
  "Save the edited queue message from the chat composer."
  (interactive)
  (unless emacs-dsh--queue-edit (user-error "No queue edit in progress"))
  (let* ((item (car emacs-dsh--queue-edit))
         (text (emacs-dsh--draft-text))
         (content (append (unless (string-empty-p text)
                            (list `((type . "text") (text . ,text))))
                          emacs-dsh--attachments)))
    (unless content (user-error "Queue message cannot be empty"))
    (emacs-dsh--queue-update item "edit" content
                             #'emacs-dsh--queue-edit-finish)))

;;;###autoload
(defun emacs-dsh-queue ()
  "Review, edit, remove, or steer pending messages in this DSH session."
  (interactive)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (when emacs-dsh--queue-edit (user-error "Finish the current queue edit first"))
  (unless emacs-dsh--queue-ready (user-error "DSH queue is still loading"))
  (unless emacs-dsh--queue-items (user-error "No pending DSH messages"))
  (let* ((choices
          (cl-loop for (placement . item) in emacs-dsh--queue-items
                   collect (cons (format "%s  %s  [%s]"
                                         (if (eq placement 'queued) "Queued  " "Steering")
                                         (truncate-string-to-width
                                          (emacs-dsh--queue-text item) 72 nil nil t)
                                         (alist-get 'id item))
                                 (cons placement item))))
         (picked (cdr (assoc (completing-read "DSH queue: " choices nil t)
                             choices))))
    (when picked
      (let* ((placement (car picked))
             (item (cdr picked))
             (kind (cdr (assoc (completing-read
                                "Queue action: "
                                (append '(("Edit" . "edit") ("Remove" . "remove"))
                                        (when (eq placement 'queued)
                                          '(("Steer into current turn" . "steer"))))
                                nil t)
                               '(("Edit" . "edit") ("Remove" . "remove")
                                 ("Steer into current turn" . "steer"))))))
        (when kind
          (if (equal kind "edit")
              (emacs-dsh--queue-edit-start item)
            (emacs-dsh--queue-update item kind)))))))

(defun emacs-dsh--close ()
  (setq emacs-dsh--closing t)
  (emacs-dsh--set-running nil)
  (when emacs-dsh--retry-timer (cancel-timer emacs-dsh--retry-timer)
        (setq emacs-dsh--retry-timer nil))
  (when emacs-dsh--socket (websocket-close emacs-dsh--socket)
        (setq emacs-dsh--socket nil))
  (when emacs-dsh--stream-overlay
    (delete-overlay emacs-dsh--stream-overlay)
    (setq emacs-dsh--stream-overlay nil))
  (when emacs-dsh--session-id (remhash emacs-dsh--session-id emacs-dsh--chats))
  (when (= (hash-table-count emacs-dsh--chats) 0)
    (when emacs-dsh--events-retry
      (cancel-timer emacs-dsh--events-retry)
      (setq emacs-dsh--events-retry nil))
    (when emacs-dsh--events-socket
      (let ((socket emacs-dsh--events-socket))
        (setq emacs-dsh--events-socket nil emacs-dsh--events-client nil
              emacs-dsh--events-queue nil)
        (websocket-close socket)))))
;;;###autoload
(defun emacs-dsh-quit ()
  "Close this chat buffer without deleting its DSH Session."
  (interactive) (kill-buffer (current-buffer)))

(defun emacs-dsh--completion-context ()
  "Return the active @ mention or slash name at point in the composer."
  (when-let* ((widget (emacs-dsh--input-widget))
              (start (emacs-dsh--draft-beginning)))
    (let* ((draft (widget-value widget))
           (offset (- (point) start)))
      (when (and (<= 0 offset) (<= offset (length draft)))
        (let ((head (substring draft 0 offset)))
          (cond
           ((string-match
             "\\(?:\\`\\|[[:space:]]\\)\\(@\\(?:\"[^\"]*\\|[^[:space:]\" ]*\\)\\)\\'"
             head)
            (let* ((raw (match-string 1 head))
                   (quoted (string-prefix-p "@\"" raw)))
              (list :kind 'file :start (match-beginning 1) :end offset
                    :original raw :query (substring raw (if quoted 2 1))
                    :quoted quoted)))
           ((string-match "\\`/[a-z0-9_-]*\\'" head)
            (list :kind 'slash :start 0 :end offset
                  :original head :query (substring head 1)))))))))

(defun emacs-dsh--replace-completion (context replacement)
  "Replace CONTEXT in the composer with REPLACEMENT if still current."
  (let* ((draft (widget-value (emacs-dsh--input-widget)))
         (start (plist-get context :start))
         (end (plist-get context :end)))
    (if (and (<= end (length draft))
             (equal (substring draft start end) (plist-get context :original)))
        (progn
          (emacs-dsh--replace-draft
           (concat (substring draft 0 start) replacement (substring draft end)))
          (goto-char (+ (emacs-dsh--draft-beginning) start (length replacement))))
      (message "emacs-dsh: draft changed; press TAB again"))))

(defun emacs-dsh--file-mention (path)
  "Format Host candidate PATH as a DSH @ mention."
  (unless (string-match-p "[\"\n\r]" path)
    (if (string-match-p "[[:space:]]" path)
        (concat "@\"" path (unless (string-suffix-p "/" path) "\""))
      (concat "@" path))))

(defun emacs-dsh--local-file-candidates (query)
  "List QUERY's immediate directory, including home and absolute paths."
  (when (and (stringp emacs-dsh--root)
             (file-directory-p emacs-dsh--root))
    (let* ((relative (or (file-name-directory query) ""))
           (directory (expand-file-name relative emacs-dsh--root))
           (external (or (file-name-absolute-p query)
                         (string-prefix-p "~/" query)))
           (root (file-truename emacs-dsh--root)))
      (when (and (file-directory-p directory)
                 (or external (file-in-directory-p (file-truename directory) root)))
        (delq nil
              (mapcar
               (lambda (name)
                 (let ((path (expand-file-name name directory)))
                   (when (and (not (member name '("." "..")))
                              (string-prefix-p (file-name-nondirectory query) name)
                              (or external (file-in-directory-p (file-truename path) root)))
                     (let* ((directory-p (file-directory-p path))
                            (reference (concat relative name
                                               (if directory-p "/" ""))))
                       `((path . ,reference)
                         (kind . ,(if directory-p "directory" "file")))))))
               (directory-files directory)))))))

(defun emacs-dsh--complete-host-file (context)
  "Complete @ from Host files, local files, and cross-session references."
  (let ((query (plist-get context :query)))
    (if (or (file-name-absolute-p query) (string-prefix-p "~/" query))
        (emacs-dsh--show-reference-choices
         context (emacs-dsh--local-file-candidates query) nil)
       (emacs-dsh--call
        "fileReferences/list"
        `((agentId . ,emacs-dsh--session-id) (query . ,query))
        (lambda (files)
          (emacs-dsh--complete-references
           context (or files (emacs-dsh--local-file-candidates query))))
        (lambda (failure)
          (message "emacs-dsh: file candidates unavailable: %s" failure)
          (emacs-dsh--complete-references
           context (emacs-dsh--local-file-candidates query)))))))

(defun emacs-dsh--complete-references (context files)
  "Finish @ completion with FILES and Host session candidates."
  (emacs-dsh--call
   "sessionReferenceResolver/candidates"
   `((agentId . ,emacs-dsh--session-id)
     (query . ,(plist-get context :query)))
    (lambda (sessions)
      (emacs-dsh--show-reference-choices context files sessions))
    (lambda (failure)
      (message "emacs-dsh: session candidates unavailable: %s" failure)
      (emacs-dsh--show-reference-choices context files nil))))

(defun emacs-dsh--show-reference-choices (context files sessions)
  "Offer FILES and SESSIONS, inserting the Host's canonical mention."
  (let ((choices
         (append
          (cl-loop for item in files
                   for path = (alist-get 'path item)
                   for mention = (and (stringp path) (emacs-dsh--file-mention path))
                   when mention
                   collect (cons (format "File: %s  [%s]" path
                                         (or (alist-get 'kind item) "file")) mention))
          (cl-loop for item in sessions
                   for mention = (alist-get 'mention item)
                   when (and (stringp mention)
                             (string-prefix-p "@[" mention)
                             (string-match-p "(dsh-session:" mention))
                   collect (cons (format "Session: %s  [%s]"
                                         (or (alist-get 'displayTitle item)
                                             (alist-get 'label item) "untitled")
                                         (or (alist-get 'sessionId item) "?"))
                                 mention)))))
    (cond
     ((null choices) (message "emacs-dsh: no matching @ references"))
     ((= (length choices) 1)
      (emacs-dsh--replace-completion context (cdar choices)))
     (t (emacs-dsh--defer-picker
         (lambda ()
           (when-let* ((mention (cdr (assoc
                                      (completing-read "DSH @ reference: "
                                                       choices nil t)
                                      choices))))
             (emacs-dsh--replace-completion context mention))))))))

(defconst emacs-dsh--local-commands
  '(("model" . "Select model") ("reasoning" . "Select thinking effort")
     ("new" . "Start a new session") ("resume" . "Resume a session")
     ("queue" . "Manage queued messages")
     ("mode" . "Select mode in a blank session")
    ("file" . "Insert a file reference") ("status" . "Show session status")
    ("help" . "List commands"))
  "Commands implemented by the Emacs client rather than the Host registry.")

(defun emacs-dsh--complete-slash (context)
  "Complete a slash command from local, Host, and skill catalogs."
  (emacs-dsh--call
   "commands/list" `((agentId . ,emacs-dsh--session-id))
   (lambda (commands)
     (emacs-dsh--call
      "skills/list" `((request . ((sessionId . ,emacs-dsh--session-id))))
      (lambda (skills)
        (let* ((entries (append
                         emacs-dsh--local-commands
                         (mapcar (lambda (item)
                                   (cons (alist-get 'name item)
                                         (or (alist-get 'description item) "Host command")))
                                 commands)
                         (mapcar (lambda (item)
                                   (cons (alist-get 'name item)
                                         (or (alist-get 'description item) "Skill")))
                                 (alist-get 'skills skills))))
               (prefix (plist-get context :query))
               (choices (cl-loop for (name . description) in entries
                                 when (and (stringp name)
                                           (string-prefix-p prefix name))
                                 collect (cons (format "/%s  — %s" name description)
                                               (concat "/" name)))))
          (cond
           ((null choices) (message "emacs-dsh: no matching slash commands"))
           ((= (length choices) 1)
            (emacs-dsh--replace-completion context (cdar choices)))
           (t
            (emacs-dsh--defer-picker
             (lambda ()
               (when-let* ((choice (cdr (assoc
                                          (completing-read "DSH command: " choices nil t)
                                          choices))))
                 (emacs-dsh--replace-completion context choice))))))))
      (lambda (failure)
        (message "emacs-dsh: skill completion failed: %s" failure))))
   (lambda (failure)
     (message "emacs-dsh: command completion failed: %s" failure))))

;;;###autoload
(defun emacs-dsh-complete ()
  "Complete a DSH @ reference or / command at point with TAB."
  (interactive)
  (let ((context (emacs-dsh--completion-context)))
    (pcase (plist-get context :kind)
      ('file (emacs-dsh--complete-host-file context))
      ('slash (emacs-dsh--complete-slash context))
      (_ (message "emacs-dsh: TAB completes @files and /commands")))))

(defun emacs-dsh--file-ref (path root)
  (let* ((relative (file-relative-name path root))
         (escaped (replace-regexp-in-string "\"" "\\\\\"" relative)))
    (if (string-match-p "[[:space:]]" escaped)
        (concat "@\"" escaped "\"") (concat "@" escaped))))

;;;###autoload
(defun emacs-dsh-insert-file ()
  "Insert a @file reference relative to the current chat root."
  (interactive)
  (unless emacs-dsh--root (user-error "Not in a DSH chat"))
  (let ((path (read-file-name "Reference file: " emacs-dsh--root nil t)))
    (emacs-dsh--replace-draft
     (concat (emacs-dsh--draft-text) " " (emacs-dsh--file-ref path emacs-dsh--root)))))

(defun emacs-dsh--wsl-powershell (script)
  "Run SCRIPT in Windows PowerShell through stdin; return stdout on success."
  (when (and (getenv "WSL_DISTRO_NAME") (executable-find "powershell.exe"))
    (with-temp-buffer
      (insert script)
      (let ((coding-system-for-read 'utf-8)
            (coding-system-for-write 'utf-8))
        (when (zerop (call-process-region
                      (point-min) (point-max) "powershell.exe" t '(t nil) nil
                      "-NoProfile" "-NonInteractive" "-STA" "-Command" "-"))
          (replace-regexp-in-string "\r" "" (buffer-string)))))))

(defun emacs-dsh--wsl-clipboard-files ()
  "Return local WSL paths for files in the Windows clipboard."
  (when-let* ((output (emacs-dsh--wsl-powershell
                      (concat "Add-Type -AssemblyName System.Windows.Forms; "
                              "$drop=[System.Windows.Forms.Clipboard]::GetFileDropList(); "
                              "foreach ($item in $drop) { Write-Output $item }"))))
    (delq nil
          (mapcar
           (lambda (line)
             (when-let* ((path (string-trim line))
                         (converted (unless (string-empty-p path)
                                      (emacs-dsh--local-path path))))
               (when (file-exists-p converted) converted)))
           (split-string output "\n" t)))))

(defun emacs-dsh--wsl-clipboard-image ()
  "Return a base64 PNG copied from Windows, or nil."
  (let ((data (emacs-dsh--wsl-powershell
               (concat
                "$ErrorActionPreference='Stop'; "
                "Add-Type -AssemblyName System.Windows.Forms; "
                "Add-Type -AssemblyName System.Drawing; "
                "$img=[System.Windows.Forms.Clipboard]::GetImage(); "
                "if ($null -ne $img) { $stream=[IO.MemoryStream]::new(); "
                "try { $img.Save($stream,[Drawing.Imaging.ImageFormat]::Png); "
                "[Console]::Write([Convert]::ToBase64String($stream.ToArray())) "
                "} finally { $stream.Dispose(); $img.Dispose() } }"))))
    (when (and data (string-prefix-p "iVBORw0KGgo" data))
      data)))

(defun emacs-dsh--macos-osascript (script)
  "Run AppleScript SCRIPT without a shell; return stdout on success."
  (when (and (eq system-type 'darwin) (executable-find "osascript"))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (when (zerop (call-process "osascript" nil '(t nil) nil "-e" script))
          (let ((result (string-trim (buffer-string))))
            (unless (string-empty-p result) result)))))))

(defun emacs-dsh--hex-bytes (hex)
  "Decode ASCII HEX into an unibyte string."
  (unless (zerop (% (length hex) 2))
    (error "Invalid clipboard image data"))
  (let ((bytes (make-string (/ (length hex) 2) 0)))
    (dotimes (index (length bytes))
      (aset bytes index
            (string-to-number (substring hex (* index 2) (+ (* index 2) 2)) 16)))
    (encode-coding-string bytes 'no-conversion t)))

(defun emacs-dsh--macos-clipboard-files ()
  "Return existing POSIX paths copied as Finder aliases on macOS."
  (when-let* ((output (emacs-dsh--macos-osascript
                      (concat
                       "set paths to {}\n"
                       "try\n"
                       "  set clipItems to the clipboard as list\n"
                       "  repeat with clipItem in clipItems\n"
                       "    try\n"
                       "      set end of paths to POSIX path of (clipItem as alias)\n"
                       "    end try\n"
                       "  end repeat\n"
                       "end try\n"
                       "set AppleScript's text item delimiters to linefeed\n"
                       "return paths as text"))))
    (cl-remove-if-not #'file-exists-p (split-string output "\n" t))))

(defun emacs-dsh--macos-clipboard-image ()
  "Return macOS clipboard PNG data as base64, converting TIFF if necessary."
  (when (eq system-type 'darwin)
    (let* ((output (or (emacs-dsh--macos-osascript
                        "the clipboard as «class PNGf»")
                       (emacs-dsh--macos-osascript
                        "the clipboard as TIFF picture")))
           (case-fold-search t))
      (when (and output
                 (string-match
                  "\\`«data \\(PNGf\\|TIFF\\)\\([[:xdigit:]]+\\)»\\'"
                  output))
        (let ((kind (upcase (match-string 1 output)))
              (bytes (emacs-dsh--hex-bytes (match-string 2 output))))
          (if (equal kind "PNGF")
              (base64-encode-string bytes t)
            (when (executable-find "sips")
              (let* ((source (make-temp-file "emacs-dsh-clipboard-" nil ".tiff"))
                     (target (concat (file-name-sans-extension source) ".png")))
                (unwind-protect
                    (progn
                      (let ((coding-system-for-write 'no-conversion))
                        (write-region bytes nil source nil 'silent))
                      (with-temp-buffer
                        (when (zerop (call-process "sips" nil '(t nil) nil
                                                  "-s" "format" "png" source
                                                  "--out" target))
                          (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally target)
                            (base64-encode-string (buffer-string) t)))))
                  (when (file-exists-p source) (delete-file source))
                  (when (file-exists-p target) (delete-file target)))))))))))

(defvar emacs-dsh--image-remove-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacs-dsh-remove-image)
    map)
  "Mouse map for removing a staged image from its preview.")

(defun emacs-dsh--update-image-preview ()
  "Show staged image thumbnails above the composer, with remove controls."
  (when emacs-dsh--input-start
    (unless (overlayp emacs-dsh--attachment-overlay)
      (let ((pos (marker-position emacs-dsh--input-start)))
        (setq emacs-dsh--attachment-overlay (make-overlay pos pos nil t t))
        (overlay-put emacs-dsh--attachment-overlay 'priority 1)))
    (move-overlay emacs-dsh--attachment-overlay
                  (marker-position emacs-dsh--input-start)
                  (marker-position emacs-dsh--input-start))
    (overlay-put
     emacs-dsh--attachment-overlay 'before-string
     (when emacs-dsh--attachments
       (concat "\n"
               (string-join
                (cl-loop for attachment in emacs-dsh--attachments
                         for index from 0
                         collect
                         (let* ((mime (alist-get 'mediaType attachment))
                                (type (cdr (assoc mime '(("image/png" . png)
                                                          ("image/jpeg" . jpeg)
                                                          ("image/webp" . webp)
                                                          ("image/gif" . gif)))))
                                (image (and (display-images-p) type
                                            (ignore-errors
                                              (create-image
                                               (base64-decode-string
                                                (alist-get 'data attachment))
                                               type t :data-p t :max-width 200
                                               :max-height 100 :margin '(4 . 4)))))
                                (label (concat (if image
                                                   (propertize " " 'display image)
                                                 "[image]")
                                               " " (or (alist-get 'name attachment) "image")
                                               " ×  ")))
                           (propertize label 'keymap emacs-dsh--image-remove-map
                                       'emacs-dsh-image-index index
                                       'mouse-face 'highlight
                                       'help-echo "Click to remove staged image")))
                "\n")
               "\n")))))

(defun emacs-dsh-remove-image (event)
  "Remove the staged image clicked in the composer preview."
  (interactive "e")
  (let* ((hit (posn-string (event-start event)))
         (index (and hit (get-text-property (cdr hit)
                                            'emacs-dsh-image-index (car hit)))))
    (unless (and (integerp index) (< index (length emacs-dsh--attachments)))
      (user-error "No staged image at this position"))
    (setq emacs-dsh--attachments
          (append (cl-subseq emacs-dsh--attachments 0 index)
                  (nthcdr (1+ index) emacs-dsh--attachments)))
    (emacs-dsh--update-image-preview)
    (force-mode-line-update)))

(defun emacs-dsh--stage-image (mime name data)
  "Stage one MIME image with NAME and base64 DATA for the next prompt."
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (setq emacs-dsh--attachments
        (append emacs-dsh--attachments
                (list `((type . "image") (mediaType . ,mime)
                        (name . ,name) (data . ,data)))))
  (emacs-dsh--update-image-preview)
  (force-mode-line-update)
  (message "emacs-dsh: image attached; %s with C-c C-c"
           (if emacs-dsh--queue-edit "save queue edit" "send")))

(defun emacs-dsh--append-file-refs (paths)
  (let ((refs (mapconcat (lambda (path) (emacs-dsh--file-ref path emacs-dsh--root))
                         paths "\n")))
    (emacs-dsh--replace-draft
     (concat (emacs-dsh--draft-text)
             (unless (string-empty-p (emacs-dsh--draft-text)) " ")
             refs))))

;;;###autoload
(defun emacs-dsh-paste ()
  "Paste clipboard files as @refs, an image as an attachment, or text.
Supports Windows clipboard through WSL and native macOS clipboard flavors."
  (interactive)
  (let* ((files (and emacs-dsh--root
                     (or (emacs-dsh--wsl-clipboard-files)
                         (emacs-dsh--macos-clipboard-files))))
         (image (and (not files)
                     (or (emacs-dsh--wsl-clipboard-image)
                         (emacs-dsh--macos-clipboard-image))))
         (text (and (not image) (ignore-errors (current-kill 0 t))))
         (kill-files (and (stringp text)
                          (not (string-empty-p (string-trim text)))
                          (split-string (string-trim text) "\n" t))))
    (cond
     (files (emacs-dsh--append-file-refs files))
     (image (emacs-dsh--stage-image "image/png" "clipboard.png" image))
     ((and emacs-dsh--root kill-files
           (cl-every #'file-exists-p kill-files))
      (emacs-dsh--append-file-refs kill-files))
     (t (call-interactively #'yank)))))

;;;###autoload
(defun emacs-dsh-attach-image (file)
  "Stage the PNG/JPEG/WebP/GIF image FILE for the next prompt."
  (interactive "fImage file: ")
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (let* ((extension (downcase (or (file-name-extension file) "")))
         (mime (cdr (assoc extension '(("png" . "image/png") ("jpg" . "image/jpeg")
                                        ("jpeg" . "image/jpeg") ("webp" . "image/webp")
                                        ("gif" . "image/gif"))))))
    (unless mime (user-error "Unsupported image format"))
    (let ((data (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally file)
                  (base64-encode-string (buffer-string) t))))
      (emacs-dsh--stage-image mime (file-name-nondirectory file) data))))

(provide 'emacs-dsh)
;;; emacs-dsh.el ends here
