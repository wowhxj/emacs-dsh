;;; ashub-compat-tests.el --- Optional ashub integration tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with ashub and emacs-dsh on load-path; no real Host is contacted.

;;; Code:
(require 'ert)
(require 'emacs-dsh)
(require 'ashub)
(require 'ashub-reference)

(ert-deftest emacs-dsh-ashub-restores-original-directory-with-current-worktree ()
  "Exercise real ashub restore and DSH snapshot handling across a cwd change."
  (let* ((root (file-truename (make-temp-file "dsh-ashub-root-" t)))
         (worktree (file-truename (make-temp-file "dsh-ashub-worktree-" t)))
         (buffer (generate-new-buffer " *dsh-ashub-restore*"))
         (source '("http://localhost:1/" "test-generation" desktop))
         (emacs-dsh--chats (make-hash-table :test #'equal))
         (ashub--opening (make-hash-table :test #'equal))
         (ashub--directory-overrides (make-hash-table :test #'equal))
         shown calls)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-dsh--source-identity) (lambda () source))
                  ((symbol-function 'emacs-dsh--ensure-auth) (lambda (callback) (funcall callback nil)))
                  ((symbol-function 'websocket-openp) (lambda (_) t))
                  ((symbol-function 'emacs-dsh--call)
                   (lambda (&rest args) (push args calls) (ert-fail "Restore issued a management write")))
                  ((symbol-function 'pop-to-buffer) (lambda (value &rest _) (setq shown value)))
                  ((symbol-function 'delete-other-windows) #'ignore)
                  ((symbol-function 'emacs-dsh--show)
                   (lambda (id directory display)
                     (should (equal id "selected-session"))
                     (should (eq display 'none))
                     (with-current-buffer buffer
                       (emacs-dsh-chat-mode)
                       (setq-local emacs-dsh--session-id id
                                   emacs-dsh--source source
                                   emacs-dsh--socket 'test-socket
                                   emacs-dsh--root directory
                                   default-directory directory)
                       (emacs-dsh--compose)
                       (emacs-dsh--on-frame
                        buffer 'test-socket
                        (make-websocket-frame
                         :payload
                         (json-serialize
                          `((type . "item") (streamId . ,id)
                            (value . ((type . "snapshot")
                                      (header . ((id . ,id) (cwd . ,root)))
                                      (cursor . 10) (records . [])
                                      (projections . ((asOfSeq . 10)
                                                      (values . ((workingDirectory . ,worktree))))))))))))
                     buffer)))
          (ashub-open-session
           (ashub-session-create :agent 'dsh :id "selected-session" :cwd root
                                 :source '(:agent dsh :root "configured-host")
                                 :metadata (list :native-source source)))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not shown) (> (hash-table-count ashub--opening) 0)
                        (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should (eq shown buffer))
          (should-not calls)
          (with-current-buffer buffer
            (should (equal emacs-dsh--verified-session (list "selected-session" root)))
            (should (file-equal-p emacs-dsh--root worktree))
            (should (file-equal-p default-directory worktree))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (setq emacs-dsh--socket nil))
        (kill-buffer buffer))
      (delete-directory root)
      (delete-directory worktree))))

(ert-deftest emacs-dsh-ashub-reference-provider-keeps-explicit-export-path ()
  "Ashub exports an absolute reference path independently of the chat cwd."
  (let* ((path (expand-file-name "ashub-test-reference.md" temporary-file-directory))
         (session (ashub-session-create :agent 'dsh :id "reference-session")))
    (cl-letf (((symbol-function 'ashub-reference-read-session) (lambda () session))
              ((symbol-function 'ashub-reference-markdown) (lambda (_) "saved dialogue"))
              ((symbol-function 'ashub-reference-write)
               (lambda (selected text)
                 (should (eq selected session))
                 (should (equal text "saved dialogue"))
                 path)))
      (should (equal (ashub-reference-provider "/different/worktree/") path)))))

(ert-deftest emacs-dsh-ashub-scan-keeps-enumerated-directory ()
  "A current worktree projection must not replace ashub's restore directory."
  (let ((source '("http://localhost:1/" "test-generation" desktop)) result)
    (cl-letf (((symbol-function 'emacs-dsh-list-sessions)
               (lambda (callback &rest _)
                 (funcall callback
                          (list :source source
                                :items '(((sessionId . "selected-session")
                                          (cwd . "/original-project")
                                          (firstUserMessage . "hello")
                                          (projections .
                                                       ((values .
                                                                ((workingDirectory . "/wt")))))))))
                 #'ignore)))
      (ashub--scan-dsh '(:agent dsh :root "configured-host")
                       (lambda (items _diagnostics) (setq result items))
                       (lambda (failure) (ert-fail failure)))
      (should (= (length result) 1))
      (should (equal (ashub-session-cwd (car result)) "/original-project")))))

(provide 'ashub-compat-tests)
;;; ashub-compat-tests.el ends here
