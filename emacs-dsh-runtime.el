;;; emacs-dsh-runtime.el --- Independent managed Host launcher -*- lexical-binding: t; -*-

;;; Commentary:
;; Desktop keeps its own Host.  This module manages only the independent
;; dsh web runtime, with private local IPC and no package installation.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'seq)
(defvar emacs-dsh-managed-command)

(defcustom emacs-dsh-managed-persistent t
  "Whether a managed dsh web Host survives Emacs.
Nil selects legacy Emacs-owned startup.  Persistent failures never fall back."
  :type 'boolean :group 'emacs-dsh)
(defcustom emacs-dsh-node-executable "node"
  "Node executable for the bundled managed Host supervisor."
  :type 'string :group 'emacs-dsh)
(defcustom emacs-dsh-managed-home nil
  "DSH_HOME for managed Hosts; nil uses the environment or ~/.dsh.
Desktop bridge discovery remains independent of this setting."
  :type '(choice (const nil) directory) :group 'emacs-dsh)
(defcustom emacs-dsh-managed-directory (expand-file-name "~/")
  "Working directory for the shared managed Host, not a chat project identity."
  :type 'directory :group 'emacs-dsh)
(defcustom emacs-dsh-managed-arguments
  '("web" "--host" "127.0.0.1" "--port" "0" "--no-open")
  "Arguments used to launch the managed Host on a local ephemeral port.
Include profile selection here when not using the default web profile."
  :type '(repeat string) :group 'emacs-dsh)
(defcustom emacs-dsh-runtime-directory (expand-file-name "~/.cache/emacs-dsh/hosts")
  "Private, short, local directory for independent managed Host identities."
  :type 'directory :group 'emacs-dsh)

(defconst emacs-dsh-runtime--helper
  (expand-file-name "emacs-dsh-host.mjs"
                    (file-name-directory (or load-file-name buffer-file-name))))
(defvar emacs-dsh-runtime--checked-node nil)

(defun emacs-dsh-runtime--node ()
  "Return validated Node, rejecting missing resources or unsupported platforms."
  (when (eq system-type 'windows-nt)
    (user-error "Persistent managed DSH currently requires POSIX; Desktop mode is unchanged"))
  (unless (file-readable-p emacs-dsh-runtime--helper)
    (user-error "Missing bundled DSH supervisor; reinstall package resources"))
  (let ((node (or (executable-find emacs-dsh-node-executable)
                  (and (file-executable-p emacs-dsh-node-executable)
                       (expand-file-name emacs-dsh-node-executable)))))
    (unless node (user-error "Node unavailable; set emacs-dsh-node-executable"))
    (unless (equal node emacs-dsh-runtime--checked-node)
      (with-temp-buffer
        (unless (and (zerop (call-process node nil t nil "--version"))
                     (string-match "v\\([0-9]+\\)\\.\\([0-9]+\\)" (buffer-string))
                     (let ((major (string-to-number (match-string 1 (buffer-string))))
                           (minor (string-to-number (match-string 2 (buffer-string)))))
                       (or (> major 22) (and (= major 22) (>= minor 19)))))
          (user-error "Persistent managed DSH requires Node >=22.19")))
      (setq emacs-dsh-runtime--checked-node node))
    node))

(defun emacs-dsh-runtime-config ()
  "Return the local managed Host configuration, without changing Host state."
  (let* ((program (or (executable-find emacs-dsh-managed-command)
                      (and (file-executable-p emacs-dsh-managed-command)
                           (expand-file-name emacs-dsh-managed-command))))
         (home (expand-file-name
                (or emacs-dsh-managed-home (getenv "DSH_HOME") "~/.dsh")))
         (directory (expand-file-name emacs-dsh-managed-directory)))
    (unless program (user-error "Cannot find dsh; set emacs-dsh-managed-command"))
    (when (seq-some #'file-remote-p (list home directory emacs-dsh-runtime-directory))
      (user-error "Managed Host requires local home, cwd and runtime paths"))
    `((argv . ,(vconcat (cons program emacs-dsh-managed-arguments)))
      (home . ,home) (cwd . ,directory)
      (runtime . ,(expand-file-name emacs-dsh-runtime-directory)))))

(defun emacs-dsh-runtime-key ()
  "Fingerprint selected Host home and argv for in-Emacs source guarding."
  (secure-hash 'sha256 (json-serialize (emacs-dsh-runtime-config))))

(defun emacs-dsh-runtime-command (operation)
  "Return the bundled Node command for OPERATION using the current settings."
  (list (emacs-dsh-runtime--node) emacs-dsh-runtime--helper operation
        (base64-encode-string
         (encode-coding-string (json-serialize (emacs-dsh-runtime-config)) 'utf-8) t)))

(defun emacs-dsh-runtime-inspect ()
  "Read and authenticate an existing managed supervisor without starting a Host.
This local query has a bounded supervisor deadline.  Return an alist;
never include the private output in error messages or the message log."
  (with-temp-buffer
    (let* ((command (emacs-dsh-runtime-command "inspect"))
           (status (apply #'call-process (car command) nil (list t nil) nil (cdr command))))
      (unless (and (integerp status) (zerop status))
        (error "Managed Host inspection failed; no Host was started"))
      (goto-char (point-min))
      (condition-case nil
          (json-parse-buffer :object-type 'alist :null-object nil :false-object nil)
        (error (error "Invalid private managed Host inspection response"))))))

(defun emacs-dsh-runtime-existing-connection ()
  "Return (BASE LAUNCH GENERATION) only for a verified existing running Host."
  (let* ((state (emacs-dsh-runtime-inspect))
         (base (alist-get 'base state))
         (launch (alist-get 'launch state))
         (generation (alist-get 'generation state)))
    (unless (and (equal (alist-get 'status state) "running")
                 (stringp base) (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+/\\'" base)
                 (stringp launch)
                 (string-match-p (concat "\\`" (regexp-quote base)
                                         "[?]token=[A-Za-z0-9_-]+\\'") launch)
                 (stringp generation))
      (error "Existing managed Host unavailable; no Host was started"))
    (list base launch generation)))

(defun emacs-dsh-runtime-shutdown (callback)
  "Explicitly shut down the selected independently managed Host.
CALLBACK receives (STATE FAILURE).  It is called only after the supervisor
confirms Host exit or reports an uncertain outcome.  Never starts a Host."
  (let ((output (generate-new-buffer " *dsh-host-shutdown*"))
        (errors (generate-new-buffer " *dsh-host-shutdown-errors*"))
        done timer process)
    (cl-labels
        ((finish (state failure)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when (buffer-live-p output) (kill-buffer output))
             (when (buffer-live-p errors) (kill-buffer errors))
             (funcall callback state failure))))
      (condition-case nil
          (progn
            (setq process
                  (make-process
                   :name "emacs-dsh-host-shutdown" :buffer output :stderr errors
                   :command (emacs-dsh-runtime-command "shutdown")
                   :connection-type 'pipe :coding 'utf-8-unix :noquery t
                   :sentinel
                   (lambda (child _event)
                     (when (and (not done) (memq (process-status child) '(exit signal)))
                       (let ((state
                              (and (zerop (process-exit-status child))
                                   (buffer-live-p output)
                                   (with-current-buffer output
                                     (goto-char (point-min))
                                     (ignore-errors
                                       (json-parse-buffer :object-type 'alist
                                                          :null-object nil :false-object nil))))))
                         (if (member (alist-get 'status state) '("exited" "absent"))
                             (finish state nil)
                           (finish nil "Managed Host exit not confirmed; inspect runtime before retrying")))))))
            (setq timer (run-at-time
                         15 nil (lambda ()
                                  (finish nil "Managed Host shutdown timed out; outcome unknown")
                                  (when (process-live-p process) (delete-process process)))))
            process)
        (error (finish nil "Unable to start the managed Host shutdown client"))))))

(provide 'emacs-dsh-runtime)
;;; emacs-dsh-runtime.el ends here
