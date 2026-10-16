;;; public-api-tests.el --- Public integration seams -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-dsh)

(ert-deftest emacs-dsh-api-list-does-not-start-managed-host ()
  (let ((emacs-dsh-connection-mode 'managed)
        emacs-dsh--managed-process emacs-dsh--managed-connection failure)
    (cl-letf (((symbol-function 'emacs-dsh--managed-start)
               (lambda (&rest _) (ert-fail "Metadata started Host")))
              ((symbol-function 'emacs-dsh--request)
               (lambda (&rest _) (ert-fail "Unavailable Host was queried"))))
      (emacs-dsh-list-sessions
       (lambda (_) (ert-fail "Unavailable Host succeeded"))
       :on-error (lambda (err) (setq failure err)))
      (should (stringp failure)))))

(ert-deftest emacs-dsh-api-list-uses-only-metadata-endpoint ()
  (let ((emacs-dsh--authenticated-base "http://localhost:1/") result calls)
    (cl-letf (((symbol-function 'emacs-dsh--metadata-auth) (lambda (cb) (funcall cb nil)))
              ((symbol-function 'emacs-dsh--request)
               (lambda (endpoint _args callback)
                 (push endpoint calls)
                 (funcall callback '((items . (((sessionId . "s"))))) nil))))
      (emacs-dsh-list-sessions (lambda (value) (setq result value)))
      (should (equal calls '("session/list")))
      (should (equal (alist-get 'sessionId (car (plist-get result :items))) "s")))))

(ert-deftest emacs-dsh-api-open-verifies-snapshot-and-keeps-layout ()
  (save-window-excursion
    (delete-other-windows)
    (split-window-right)
    (let* ((emacs-dsh--chats (make-hash-table :test #'equal))
           (root (file-name-as-directory temporary-file-directory))
           (original (window-buffer))
           (buffer (generate-new-buffer " *dsh-api-test*"))
           ready failure)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-dsh--ensure-auth) (lambda (cb) (funcall cb nil)))
                    ((symbol-function 'websocket-openp) (lambda (_) t))
                    ((symbol-function 'emacs-dsh--show)
                     (lambda (id directory display)
                       (should (equal id "s"))
                       (should (eq display 'none))
                       (with-current-buffer buffer
                         (setq-local emacs-dsh--socket 'fake
                                     emacs-dsh--verified-session (list id directory)))
                       buffer)))
            (emacs-dsh-open-session "s" :directory root :display 'none
                                    :on-ready (lambda (b) (setq ready b))
                                    :on-error (lambda (e) (setq failure e)))
            (let ((deadline (+ (float-time) 1)))
              (while (and (not ready) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not failure)
            (should (eq ready buffer))
            (should (= (length (window-list)) 2))
            (should (eq original (window-buffer))))
        (kill-buffer buffer)))))

(ert-deftest emacs-dsh-api-list-transport-error-terminates-once ()
  (let ((count 0))
    (cl-letf (((symbol-function 'emacs-dsh--metadata-auth) (lambda (cb) (funcall cb nil)))
              ((symbol-function 'emacs-dsh--request) (lambda (&rest _) (error "Synthetic failure"))))
      (emacs-dsh-list-sessions
       (lambda (_) (ert-fail "Transport error succeeded"))
       :on-error (lambda (_) (cl-incf count)))
      (should (= count 1)))))

(ert-deftest emacs-dsh-api-list-cancel-suppresses-late-response ()
  (let (reply result)
    (cl-letf (((symbol-function 'emacs-dsh--metadata-auth) (lambda (cb) (funcall cb nil)))
              ((symbol-function 'emacs-dsh--request)
               (lambda (_endpoint _args cb) (setq reply cb))))
      (funcall (emacs-dsh-list-sessions (lambda (value) (setq result value))))
      (funcall reply '((items . nil)) nil)
      (should-not result))))

(provide 'public-api-tests)
;;; public-api-tests.el ends here
