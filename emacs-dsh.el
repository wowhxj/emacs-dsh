;;; emacs-dsh.el --- DeepSeek Harness sessions in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-dsh contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (websocket "1.15"))
;; Keywords: tools, processes, convenience
;; URL: https://github.com/wowhxj/emacs-dsh

;;; Commentary:
;; A small, independent client for the *running* DSH Web Host.  It uses the
;; authenticated Connection HTTP RPC and the Gateway Remote-stream WebSocket;
;; it does not launch a second Harness runtime or import Pimacs/PI internals.
;; See README.md for the token-based initial connection and WSL path mapping.

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

(defgroup emacs-dsh nil "Emacs client for DeepSeek Harness." :group 'tools)
(defcustom emacs-dsh-url "http://127.0.0.1:19387/"
  "URL of the existing DSH Web Host, without its launch token.
Pass the tokenized launch URL only to `emacs-dsh-connect' when authenticating.
Do not put a tokenized URL into version-controlled Emacs configuration."
  :type 'string :group 'emacs-dsh)
(defcustom emacs-dsh-wsl-path-function nil
  "Optional function converting Emacs paths to paths understood by the DSH Host.
For example, on a Windows Host and WSL Emacs, translate /mnt/d/foo to
D:\\foo using wslpath -w.  If nil paths are sent unchanged."
  :type '(choice (const nil) function) :group 'emacs-dsh)
(defcustom emacs-dsh-max-messages 100
  "Number of messages in the first history snapshot."
  :type 'integer :group 'emacs-dsh)
(defcustom emacs-dsh-show-reasoning nil
  "Whether to display assistant reasoning blocks." :type 'boolean :group 'emacs-dsh)

(defvar emacs-dsh--chats (make-hash-table :test #'equal))
(defvar emacs-dsh--cookie-jar nil "Session-local Cookie header, never written to a file.")
(defvar-local emacs-dsh--session-id nil)
(defvar-local emacs-dsh--root nil)
(defvar-local emacs-dsh--socket nil)
(defvar-local emacs-dsh--cursor -1)
(defvar-local emacs-dsh--seen nil)
(defvar-local emacs-dsh--pending nil)
(defvar-local emacs-dsh--draft nil)
(defvar-local emacs-dsh--input-start nil)
(defvar-local emacs-dsh--stream-overlay nil)
(defvar-local emacs-dsh--last-prompt nil)
(defvar-local emacs-dsh--running nil)
(defvar-local emacs-dsh--stream-text nil)
(defvar-local emacs-dsh--stream-id nil)
(defvar-local emacs-dsh--retry-timer nil)
(defvar-local emacs-dsh--closing nil)

(defun emacs-dsh--base ()
  (let ((url (url-generic-parse-url emacs-dsh-url)))
    (unless (and (member (url-type url) '("http" "https"))
                 (url-host url) (url-port url))
      (user-error "emacs-dsh-url must be a complete HTTP(S) URL with port"))
    (format "%s://%s:%d/" (url-type url) (url-host url) (url-port url))))

(defun emacs-dsh--request (endpoint args callback)
  "Call DSH Remote ENDPOINT with named ARGS; pass result/error to CALLBACK.
CALLBACK receives (VALUE ERROR), exactly once.  Always execute it in the
buffer that initiated the call, if that buffer is still alive."
  (let* ((origin (current-buffer))
         (id (emacs-dsh--uuid))
         (url (concat (emacs-dsh--base) "api/" endpoint))
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json"))
                  (and emacs-dsh--cookie-jar
                       (list (cons "Cookie" emacs-dsh--cookie-jar)))))
         (url-request-data (encode-coding-string
                            (json-serialize
                             `((type . "client-request") (rpcId . ,id)
                               (method . ,endpoint) (payload . ((args . ,args)))))
                            'utf-8)))
    (url-retrieve
     url
     (lambda (status)
       (let (value failure)
         (unwind-protect
             (condition-case err
                 (progn
                   (when (plist-get status :error)
                     (error "Connection failed: %s" (plist-get status :error)))
                   (goto-char (point-min))
                   (unless (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                     (error "Invalid HTTP response"))
                   (unless (= (string-to-number (match-string 1)) 200)
                     (error "HTTP %s (authenticate with emacs-dsh-connect)"
                            (match-string 1)))
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
           (with-current-buffer origin (funcall callback value failure)))))
     nil t)))

(defun emacs-dsh--call (endpoint args success &optional on-error)
  (emacs-dsh--request
   endpoint args
   (lambda (value failure)
     (if failure
         (if on-error (funcall on-error failure)
           (message "emacs-dsh: %s" failure))
       (funcall success value)))))

;;;###autoload
(defun emacs-dsh-connect (&optional launch-url)
  "Exchange token from LAUNCH-URL for the Host's signed browser cookie.
Paste the full URL printed when `dsh web' started (including ?token=...)."
  (interactive (list (read-string "DSH launch URL (with ?token=): " emacs-dsh-url)))
  (let* ((launch (or launch-url emacs-dsh-url))
         (parsed (url-generic-parse-url launch))
         (base (emacs-dsh--base))
         (expected (url-generic-parse-url base)))
    (unless (and (equal (url-host parsed) (url-host expected))
                 (equal (url-port parsed) (url-port expected))
                 (string-match-p "[?&]token=[^&]+" launch))
      (user-error "Use the tokenized launch URL from this exact DSH Host"))
    (let ((url-automatic-caching nil)
          (url-max-redirections 0))
      (url-retrieve
       launch
       (lambda (status)
         (unwind-protect
             (if (and (plist-get status :error)
                      (not (eq (cadr (plist-get status :error)) 'http-redirect-limit)))
                 (message "emacs-dsh: authentication failed: %s" (plist-get status :error))
               (goto-char (point-min))
               (if (and (re-search-forward "^[Ss]et-[Cc]ookie: \\([^;\r\n]+\\)" nil t)
                        (string-match-p "\\`dsh-auth-" (match-string 1)))
                   (progn
                     (setq emacs-dsh--cookie-jar (match-string 1))
                     (message "emacs-dsh: authenticated; token retained only in emacs-dsh-url if configured"))
                 (message "emacs-dsh: no signed cookie; check launch URL")))
           (kill-buffer (current-buffer))))
       nil t))))

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
  (if emacs-dsh-wsl-path-function
      (funcall emacs-dsh-wsl-path-function path)
    path))

(defun emacs-dsh--project-root ()
  (let ((project (project-current nil)))
    (expand-file-name (if project (project-root project) default-directory))))

(defvar emacs-dsh-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-dsh-send)
    (define-key map (kbd "C-c C-s") #'emacs-dsh-steer)
    (define-key map (kbd "C-c C-k") #'emacs-dsh-cancel)
    (define-key map (kbd "C-c C-q") #'emacs-dsh-quit)
    (define-key map (kbd "C-c C-r") #'emacs-dsh-resume)
    (define-key map (kbd "C-c C-p") #'emacs-dsh-paste)
    (define-key map (kbd "TAB") #'completion-at-point)
    map)
  "Keys in an emacs-dsh chat buffer.")

(define-derived-mode emacs-dsh-chat-mode special-mode "emacs-dsh"
  "Major mode for a DSH chat; compose in the editable field at the bottom."
  (setq-local emacs-dsh--seen (make-hash-table :test #'eql))
  (setq-local emacs-dsh--pending (make-hash-table :test #'equal))
  (setq-local emacs-dsh--closing nil)
  (setq-local emacs-dsh--cursor -1)
  (setq-local emacs-dsh--last-prompt nil)
  (setq-local truncate-lines nil)
  (setq-local header-line-format '(:eval (emacs-dsh--header)))
  (tab-line-mode 1)
  (setq-local tab-line-format '(:eval (emacs-dsh--state)))
  (add-hook 'completion-at-point-functions #'emacs-dsh--complete-file nil t)
  (add-hook 'kill-buffer-hook #'emacs-dsh--close nil t))

(defun emacs-dsh--header ()
  (when emacs-dsh--last-prompt
    (replace-regexp-in-string "%" "%%"
                              (concat "user> " (replace-regexp-in-string
                                                "[\r\n]+" " ↵ " emacs-dsh--last-prompt)))))
(defun emacs-dsh--state ()
  (format " DSH [%s] %s  %s " (or emacs-dsh--session-id "connecting")
          (if emacs-dsh--running "running" "idle") (or emacs-dsh--root "")))

(defun emacs-dsh--compose ()
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (setq-local emacs-dsh--input-start (copy-marker (point) nil))
    (insert "\nYou> ")
    (let ((start (point)))
      (let ((draft emacs-dsh--draft))
        (setq emacs-dsh--draft nil)
        (setq-local emacs-dsh--draft
                    (widget-create 'editable-field :size 64 :format "%v"
                                   :value (or draft ""))))
      (widget-setup)
      (goto-char (max start (1- (point-max)))))))

(defun emacs-dsh--input-widget ()
  (and emacs-dsh--draft (widget-get emacs-dsh--draft :from) emacs-dsh--draft))

(defun emacs-dsh--draft-text ()
  (let ((widget (emacs-dsh--input-widget)))
    (if widget (string-trim (widget-value widget)) "")))

(defun emacs-dsh--replace-draft (text)
  (when-let* ((widget (emacs-dsh--input-widget)))
    (let ((inhibit-read-only t))
      (widget-value-set widget text)
      (widget-setup)
      (goto-char (point-max)))))

(defun emacs-dsh--insert-before-input (text &optional face)
  (let ((inhibit-read-only t)
        (widget (emacs-dsh--input-widget)))
    (save-excursion
      (goto-char (if (and widget emacs-dsh--input-start)
                     emacs-dsh--input-start (point-max)))
      (insert (if face (propertize text 'face face) text) "\n"))))

(defun emacs-dsh--content (blocks)
  (mapconcat
   (lambda (block)
     (pcase (alist-get 'type block)
       ((or "text" "reasoning")
        (if (and (equal (alist-get 'type block) "reasoning")
                 (not emacs-dsh-show-reasoning)) "" (or (alist-get 'text block) "")))
       ("tool-call" (format "[tool: %s %s]" (alist-get 'name block)
                            (or (alist-get 'arguments block) "")))
       ("image" "[image]") ("file" "[file]") (_ "")))
   (if (vectorp blocks) (append blocks nil) blocks) "\n"))

(defun emacs-dsh--event (event)
  (let* ((seq (alist-get 'seq event))
         (type (alist-get 'type event))
         (data (alist-get 'data event)))
    (when (and (numberp seq) (> seq emacs-dsh--cursor))
      (setq emacs-dsh--cursor seq))
    (when (and (numberp seq) (not (gethash seq emacs-dsh--seen)))
      (puthash seq t emacs-dsh--seen)
      (pcase type
        ("user/message"
         (let* ((message (or (alist-get 'message data) data))
                (text (emacs-dsh--content (alist-get 'content message))))
           (unless (string-empty-p text)
             (setq emacs-dsh--last-prompt text)
             (emacs-dsh--insert-before-input (concat "You: " text) 'font-lock-keyword-face))))
        ("assistant/message"
         (let* ((message (alist-get 'message data))
                (text (emacs-dsh--content (alist-get 'content message))))
           (setq emacs-dsh--stream-text nil emacs-dsh--stream-id nil)
            (when emacs-dsh--stream-overlay
              (overlay-put emacs-dsh--stream-overlay 'before-string nil))
           (unless (string-empty-p text)
             (emacs-dsh--insert-before-input (concat "DSH: " text) 'default))))
        ("tool/call"
         (emacs-dsh--insert-before-input
          (format "[tool %s] %s" (or (alist-get 'name data) "?")
                  (or (alist-get 'arguments data) "")) 'shadow))
        ("turn/start" (setq emacs-dsh--running t))
        ("turn/end" (setq emacs-dsh--running nil)
         (emacs-dsh--insert-before-input
          (format "[turn %s]" (or (alist-get 'kind (alist-get 'reason data)) "ended"))
          'shadow))))
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
                      (propertize (concat "DSH (streaming): " emacs-dsh--stream-text "\n")
                                  'face 'shadow)))))

(defun emacs-dsh--on-frame (buffer socket frame)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq socket emacs-dsh--socket)
        (condition-case err
            (let ((data (json-parse-string (websocket-frame-payload frame)
                                           :object-type 'alist :array-type 'list
                                           :null-object nil :false-object nil)))
              (when (equal (alist-get 'streamId data) emacs-dsh--session-id)
                (pcase (alist-get 'type data)
                  ("item"
                   (let ((value (alist-get 'value data)))
                     (pcase (alist-get 'type value)
                       ("snapshot"
                        (when (< emacs-dsh--cursor 0)
                          (clrhash emacs-dsh--seen))
                        (dolist (record (alist-get 'records value))
                          (emacs-dsh--event (alist-get 'event record)))
                        (setq emacs-dsh--cursor (max emacs-dsh--cursor
                                                     (or (alist-get 'cursor value) -1))))
                       ("event" (emacs-dsh--event (alist-get 'event value)))
                       ("assistant-stream" (emacs-dsh--stream (alist-get 'frame value))))))
                  ("error" (message "emacs-dsh stream: %s"
                                     (alist-get 'message (alist-get 'error data)))))))
          (error (message "emacs-dsh frame: %s" (error-message-string err))))))))

(defun emacs-dsh--follow ()
  (when emacs-dsh--session-id
    (when (and emacs-dsh--socket (websocket-openp emacs-dsh--socket))
      (websocket-close emacs-dsh--socket))
    (let* ((buffer (current-buffer))
           (scheme (if (string-prefix-p "https:" (emacs-dsh--base)) "wss" "ws"))
           (url (replace-regexp-in-string "\\`https?" scheme (emacs-dsh--base))))
      (condition-case err
          (setq emacs-dsh--socket
                (websocket-open
                 (concat url "api/remote.mux")
                 :custom-header-alist (and emacs-dsh--cookie-jar
                                          (list (cons "Cookie" emacs-dsh--cookie-jar)))
                 :on-open (lambda (ws)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (when (eq ws emacs-dsh--socket)
                                  (websocket-send-text
                                   ws (json-serialize
                                       `((type . "open")
                                         (streamId . ,emacs-dsh--session-id)
                                         (endpoint . "session/follow")
                                         (payload . ((args . ((request .
                                                               ((address . ((kind . "session")
                                                                            (sessionId . ,emacs-dsh--session-id)))
                                                                (maxMessages . ,emacs-dsh-max-messages)
                                                                (assistantStream . t)))))))))))))
                 :on-message (lambda (ws frame) (emacs-dsh--on-frame buffer ws frame))
                 :on-error (lambda (_ws _phase error)
                             (message "emacs-dsh WebSocket: %s" error))
                 :on-close (lambda (ws)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (when (and (eq ws emacs-dsh--socket)
                                            (not emacs-dsh--closing))
                                   (setq emacs-dsh--socket nil)
                                   (setq emacs-dsh--retry-timer
                                         (run-at-time 3 nil #'emacs-dsh--retry buffer)))))))))
        (error (message "emacs-dsh: WebSocket failed: %s" (error-message-string err)))))))

(defun emacs-dsh--retry (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacs-dsh--retry-timer nil)
      (unless emacs-dsh--closing (emacs-dsh--follow)))))

(defun emacs-dsh--show (id root)
  (let ((existing (gethash id emacs-dsh--chats)))
    (if (buffer-live-p existing)
        (pop-to-buffer existing)
      (let ((buffer (generate-new-buffer (format "*emacs-dsh:%s*" id))))
        (puthash id buffer emacs-dsh--chats)
        (pop-to-buffer buffer)
        (emacs-dsh-chat-mode)
        (setq-local default-directory (file-name-as-directory
                                        (if (file-directory-p root) root (emacs-dsh--project-root))))
        (setq-local emacs-dsh--root root)
        (setq-local emacs-dsh--session-id id)
        (emacs-dsh--insert-before-input (format "DSH session %s (%s)" id root))
        (emacs-dsh--compose)
        (emacs-dsh--follow)))))

;;;###autoload
(defun emacs-dsh-chat (&optional root)
  "Choose ROOT and create a fresh DSH Session, even when ROOT is already open."
  (interactive (list (read-directory-name "DSH root: " (emacs-dsh--project-root) nil t)))
  (setq root (file-name-as-directory (expand-file-name (or root (emacs-dsh--project-root)))))
  (emacs-dsh--call
   "session/create" `((request . ((cwd . ,(emacs-dsh--host-path root)))))
   (lambda (value) (emacs-dsh--show (alist-get 'sessionId value) root))))

;;;###autoload
(defun emacs-dsh-resume ()
  "List the DSH Host's persisted sessions; select one without starting a new one."
  (interactive)
  (emacs-dsh--call
   "session/list" `((request . ,(make-hash-table)))
   (lambda (value)
     (let* ((items (alist-get 'items value))
            (choices (mapcar
                      (lambda (item)
                        (cons (format "%s  %s" (alist-get 'sessionId item)
                                      (or (alist-get 'cwd item) "")) item)) items))
            (choice (and choices
                         (cdr (assoc (completing-read "Resume DSH session: " choices nil t)
                                     choices)))))
       (if choice
           (emacs-dsh--show (alist-get 'sessionId choice)
                            (or (alist-get 'cwd choice) default-directory))
         (message "emacs-dsh: no sessions"))))))

(defun emacs-dsh--submit (mode)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (let* ((text (emacs-dsh--draft-text))
         (id (emacs-dsh--uuid)))
    (when (string-empty-p text) (user-error "Write a prompt first"))
    (puthash id text emacs-dsh--pending)
    (emacs-dsh--replace-draft "")
    (emacs-dsh--call
     "session/prompt"
     `((request . ((requestId . ,id) (sessionId . ,emacs-dsh--session-id)
                   (mode . ,mode) (content . [((type . "text") (text . ,text))]))))
     (lambda (_value)
       (remhash id emacs-dsh--pending)
       (setq emacs-dsh--last-prompt text)
       (force-mode-line-update)
       (message "emacs-dsh: prompt accepted"))
     (lambda (failure)
       (remhash id emacs-dsh--pending)
       (emacs-dsh--replace-draft
        (concat text (unless (string-empty-p (emacs-dsh--draft-text))
                       (concat "\n" (emacs-dsh--draft-text)))))
       (message "emacs-dsh: %s (draft restored)" failure)))))

;;;###autoload
(defun emacs-dsh-send () "Queue the draft as a new prompt." (interactive) (emacs-dsh--submit "queue"))
;;;###autoload
(defun emacs-dsh-steer () "Steer a running turn with the draft." (interactive) (emacs-dsh--submit "steer"))
;;;###autoload
(defun emacs-dsh-cancel ()
  "Cancel the active turn (pending messages remain queued)."
  (interactive)
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (emacs-dsh--call "session/cancel" `((request . ((sessionId . ,emacs-dsh--session-id))))
                   (lambda (_) (message "emacs-dsh: cancelled"))))

(defun emacs-dsh--close ()
  (setq emacs-dsh--closing t)
  (when emacs-dsh--retry-timer (cancel-timer emacs-dsh--retry-timer)
        (setq emacs-dsh--retry-timer nil))
  (when emacs-dsh--socket (websocket-close emacs-dsh--socket)
        (setq emacs-dsh--socket nil))
  (when emacs-dsh--stream-overlay
    (delete-overlay emacs-dsh--stream-overlay)
    (setq emacs-dsh--stream-overlay nil))
  (when emacs-dsh--session-id (remhash emacs-dsh--session-id emacs-dsh--chats)))
;;;###autoload
(defun emacs-dsh-quit ()
  "Close this chat buffer without deleting its DSH Session."
  (interactive) (kill-buffer (current-buffer)))

(defun emacs-dsh--complete-file ()
  "Complete @paths from the local project or absolute filesystem."
  (when (and emacs-dsh--session-id (emacs-dsh--input-widget))
    (save-excursion
      (when (re-search-backward "@\\([^[:space:]]*\\)" (line-beginning-position) t)
        (let* ((start (match-beginning 1))
               (prefix (match-string-no-properties 1))
               (root emacs-dsh--root)
               (directory (file-name-directory prefix))
               (base (file-name-nondirectory prefix))
               (folder (expand-file-name (or directory "") root)))
          (when (file-directory-p folder)
            (let ((matches (mapcar (lambda (name) (concat (or directory "") name))
                                   (file-name-all-completions base folder))))
              (list start (point) matches :exclusive 'no))))))))

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

;;;###autoload
(defun emacs-dsh-paste ()
  "Smart paste: clipboard file paths become @refs; otherwise yank text.
Windows/WSL clipboard bitmap attachment is not yet supported; use
`emacs-dsh-attach-image' for images."
  (interactive)
  (let ((text (current-kill 0 t)))
    (if (and emacs-dsh--root (stringp text)
             (cl-every #'file-exists-p (split-string (string-trim text) "\n" t)))
        (emacs-dsh--replace-draft
         (concat (emacs-dsh--draft-text) " " (mapconcat
                                              (lambda (path) (emacs-dsh--file-ref path emacs-dsh--root))
                                              (split-string (string-trim text) "\n" t) "\n")))
      (call-interactively #'yank))))

;;;###autoload
(defun emacs-dsh-attach-image (file)
  "Send the current draft plus the PNG/JPEG/WebP/GIF image FILE.
Image bytes are admitted by DSH and stored in the Session."
  (interactive "fImage file: ")
  (unless emacs-dsh--session-id (user-error "Not in a DSH chat"))
  (let* ((extension (downcase (or (file-name-extension file) "")))
         (mime (cdr (assoc extension '(("png" . "image/png") ("jpg" . "image/jpeg")
                                        ("jpeg" . "image/jpeg") ("webp" . "image/webp")
                                        ("gif" . "image/gif")))))
         (text (emacs-dsh--draft-text)))
    (unless mime (user-error "Unsupported image format"))
    (let ((bytes (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file)
                   (base64-encode-string (buffer-string) t))))
      (emacs-dsh--call
       "session/prompt"
       `((request . ((requestId . ,(emacs-dsh--uuid))
                     (sessionId . ,emacs-dsh--session-id) (mode . "queue")
                     (content . [((type . "text") (text . ,text))
                                 ((type . "image") (mediaType . ,mime)
                                  (name . ,(file-name-nondirectory file)) (data . ,bytes))]))))
       (lambda (_) (emacs-dsh--replace-draft "")
         (setq emacs-dsh--last-prompt text) (message "emacs-dsh: image accepted"))))))

(provide 'emacs-dsh)
;;; emacs-dsh.el ends here
