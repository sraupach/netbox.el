;;; test-netbox.el --- Tests for netbox.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 sraupach

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Regression tests for the synchronous, asynchronous, cache, and UI helpers
;; provided by netbox.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'netbox)

(defmacro netbox-test--with-preserved-endpoints (&rest body)
  "Run BODY with all NetBox endpoint variables dynamically preserved."
  (declare (indent 0) (debug t))
  `(let ,(mapcar (lambda (spec)
                   (list (car spec) (car spec)))
                 netbox--endpoint-specs)
     ,@body))

(ert-deftest netbox-test-sync-pagination-rejects-empty-next-page ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'netbox-api-request)
               (lambda (_endpoint _params)
                 (cl-incf calls)
                 '(("count" . 1)
                   ("next" . "https://netbox.example/api/test/?offset=50")
                   ("results" . nil)))))
      (should-error (netbox-api-list "/api/test/")
                    :type 'error)
      (should (= calls 1)))))

(ert-deftest netbox-test-sync-pagination-loads-all-pages ()
  (let ((responses (list
                    '(("count" . 2)
                      ("next" . "https://netbox.example/api/test/?offset=1")
                      ("results" . ((("id" . 1)))))
                    '(("count" . 2)
                      ("next" . nil)
                      ("results" . ((("id" . 2))))))))
    (cl-letf (((symbol-function 'netbox-api-request)
               (lambda (_endpoint _params)
                 (pop responses))))
      (should (equal (mapcar (lambda (obj) (cdr (assoc "id" obj)))
                             (netbox-api-list "/api/test/"))
                     '(1 2))))))

(ert-deftest netbox-test-sync-pagination-stops-at-reported-count ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'netbox-api-request)
               (lambda (_endpoint _params)
                 (cl-incf calls)
                 '(("count" . 1)
                   ("next" . "https://netbox.example/api/test/?offset=1")
                   ("results" . ((("id" . 1))))))))
      (should (= (length (netbox-api-list "/api/test/")) 1))
      (should (= calls 1)))))

(ert-deftest netbox-test-async-pagination-rejects-empty-next-page ()
  (let ((calls 0)
        result
        error-text)
    (cl-letf (((symbol-function 'netbox-api-request-async)
               (lambda (_endpoint _params callback)
                 (cl-incf calls)
                 (if (= calls 1)
                     (funcall callback
                              '(("count" . 1)
                                ("next" . "https://netbox.example/api/test/?offset=50")
                                ("results" . nil))
                              nil)
                   (funcall callback nil "pagination repeated")))))
      (netbox-api-list-async
       "/api/test/" nil
       (lambda (objects err)
         (setq result objects
               error-text err))))
    (should-not result)
    (should (= calls 1))
    (should (string-match-p "no results" error-text))))

(ert-deftest netbox-test-async-pagination-loads-all-pages ()
  (let ((responses
         (list
          '(("count" . 2)
            ("next" . "https://netbox.example/api/test/?offset=1")
            ("results" . ((("id" . 1)))))
          '(("count" . 2)
            ("next" . nil)
            ("results" . ((("id" . 2)))))))
        result
        error-text)
    (cl-letf (((symbol-function 'netbox-api-request-async)
               (lambda (_endpoint _params callback)
                 (funcall callback (pop responses) nil))))
      (netbox-api-list-async
       "/api/test/" nil
       (lambda (objects err)
         (setq result objects
               error-text err))))
    (should-not error-text)
    (should (equal (mapcar (lambda (obj) (cdr (assoc "id" obj))) result)
                   '(1 2)))))

(ert-deftest netbox-test-async-pagination-stops-at-reported-count ()
  (let ((calls 0)
        result
        error-text)
    (cl-letf (((symbol-function 'netbox-api-request-async)
               (lambda (_endpoint _params callback)
                 (cl-incf calls)
                 (funcall callback
                          '(("count" . 1)
                            ("next" . "https://netbox.example/api/test/?offset=1")
                            ("results" . ((("id" . 1)))))
                          nil))))
      (netbox-api-list-async
       "/api/test/" nil
       (lambda (objects err)
         (setq result objects
               error-text err))))
    (should-not error-text)
    (should (= (length result) 1))
    (should (= calls 1))))

(ert-deftest netbox-test-empty-results-are-cacheable ()
  (let ((netbox--cache (make-hash-table :test #'equal))
        (netbox-cache-ttl 300)
        (fetch-called nil)
        callback-result
        callback-error)
    (netbox--cache-put (netbox--cache-key "/api/test/" nil) nil)
    (cl-letf (((symbol-function 'netbox-api-list-async)
               (lambda (&rest _args)
                 (setq fetch-called t))))
      (netbox-api-list-async-cached
       "/api/test/" nil
       (lambda (result err)
         (setq callback-result result
               callback-error err))))
    (should-not fetch-called)
    (should-not callback-result)
    (should-not callback-error)))

(ert-deftest netbox-test-cache-keys-include-netbox-instance ()
  (let ((netbox-url "https://first.example"))
    (should-not
     (equal (netbox--cache-key "/api/test/" nil)
            (let ((netbox-url "https://second.example"))
              (netbox--cache-key "/api/test/" nil))))))

(ert-deftest netbox-test-stale-list-response-is-ignored ()
  (let (callbacks)
    (with-temp-buffer
      (netbox-list-mode)
      (setq netbox-list--endpoint "/api/test/"
            netbox-list--columns '(("Name" 20 "name"))
            tabulated-list-format [("Name" 20 t)])
      (tabulated-list-init-header)
      (cl-letf (((symbol-function 'netbox--run-with-connectivity-check)
                 (lambda (_buffer action &optional _current-p)
                   (funcall action)))
                ((symbol-function 'netbox-api-list-async-cached)
                 (lambda (_endpoint _params callback)
                   (push callback callbacks))))
        (setq netbox-list--search-q "old")
        (netbox-list-populate)
        (setq netbox-list--search-q "new")
        (netbox-list-populate)
        (let ((new-callback (car callbacks))
              (old-callback (cadr callbacks)))
          (funcall new-callback '((("id" . 2) ("name" . "new"))) nil)
          (funcall old-callback '((("id" . 1) ("name" . "old"))) nil))
        (should (equal (mapcar #'car tabulated-list-entries) '(2)))))))

(ert-deftest netbox-test-list-generation-survives-mode-reinitialization ()
  (with-temp-buffer
    (netbox-list-mode)
    (setq netbox-list--request-generation 3)
    (netbox-list-mode)
    (should (= netbox-list--request-generation 3))))

(ert-deftest netbox-test-clearing-super-search-invalidates-in-flight-request ()
  (let ((netbox--resource-alist
         '(("Devices" . (netbox-endpoint-dcim-devices
                          . netbox-columns-dcim-devices))))
        callback)
    (with-temp-buffer
      (netbox-super-search-mode)
      (setq netbox-super-search--query "old"
            tabulated-list-format
            [("Type" 18 t) ("Name" 30 t) ("Description" 40 t) ("URL" 45 t)])
      (tabulated-list-init-header)
      (cl-letf (((symbol-function 'netbox--run-with-connectivity-check)
                 (lambda (_buffer action &optional _current-p)
                   (funcall action)))
                ((symbol-function 'netbox-api-request-async)
                 (lambda (_endpoint _params cb)
                   (setq callback cb))))
        (netbox--super-search-populate "old")
        (netbox-super-search-requery "")
        (funcall callback
                 '(("results" . ((("id" . 1)
                                   ("display" . "old")
                                   ("url" . "https://example/api/dcim/devices/1/")))))
                 nil)
        (should-not tabulated-list-entries)))))

(ert-deftest netbox-test-super-search-generation-survives-mode-reinitialization ()
  (with-temp-buffer
    (netbox-super-search-mode)
    (setq netbox-super-search--request-generation 3)
    (netbox-super-search-mode)
    (should (= netbox-super-search--request-generation 3))))

(ert-deftest netbox-test-super-search-entry-ids-include-resource-type ()
  (let* ((device '(("id" . 1)
                   ("object_type" . "Devices")
                   ("display" . "device-1")
                   ("url" . "https://netbox.example/api/dcim/devices/1/")))
         (site '(("id" . 1)
                 ("object_type" . "Sites")
                 ("display" . "site-1")
                 ("url" . "https://netbox.example/api/dcim/sites/1/")))
         (device-id (car (netbox--super-search-make-entry device)))
         (site-id (car (netbox--super-search-make-entry site))))
    (should-not (equal device-id site-id))))

(ert-deftest netbox-test-clearing-super-search-removes-old-results ()
  (with-temp-buffer
    (netbox-super-search-mode)
    (setq netbox-super-search--query "old"
          tabulated-list-entries
          '(("old-id" ["Devices" "old" "" "https://example.test/"])))
    (netbox-super-search-requery "")
    (should-not netbox-super-search--query)
    (should-not tabulated-list-entries)))

(ert-deftest netbox-test-object-title-skips-empty-display ()
  (should (equal (netbox--object-title
                  '(("display" . "") ("name" . "device-1"))
                  "/api/dcim/devices/" 1)
                 "device-1"))
  (should (equal (netbox--object-title nil "/api/dcim/devices/" 1)
                 "/api/dcim/devices/ #1")))

(ert-deftest netbox-test-list-errors-replace-loading-row ()
  (with-temp-buffer
    (netbox-list-mode)
    (setq netbox-list--columns '(("Name" 20 "name"))
          tabulated-list-format [("Name" 20 t)])
    (tabulated-list-init-header)
    (netbox--list-show-error "Request failed")
    (should (= (length tabulated-list-entries) 1))
    (should-not (caar tabulated-list-entries))
    (should (string-match-p
             "Request failed"
             (substring-no-properties
              (aref (cadar tabulated-list-entries) 0))))))

(ert-deftest netbox-test-detail-errors-replace-loading-message ()
  (let ((loading-name "*NetBox: loading /api/dcim/devices #99…*")
        (error-name "*NetBox: /api/dcim/devices #99*"))
    (unwind-protect
        (cl-letf (((symbol-function 'netbox--display-buffer) #'ignore)
                  ((symbol-function 'netbox--run-with-connectivity-check)
                   (lambda (_buffer action &optional _current-p)
                     (funcall action)))
                  ((symbol-function 'netbox-api-get-async)
                   (lambda (_endpoint _id callback)
                     (funcall callback nil "Request failed"))))
          (netbox-show-detail "/api/dcim/devices/" 99)
          (should-not (get-buffer loading-name))
          (with-current-buffer error-name
            (should (string-match-p "Request failed" (buffer-string)))
            (should-not (string-match-p "Loading" (buffer-string)))))
      (dolist (name (list loading-name error-name))
        (when (get-buffer name)
          (kill-buffer name))))))

(ert-deftest netbox-test-detail-loading-buffers-include-endpoint ()
  (let (callbacks)
    (unwind-protect
        (cl-letf (((symbol-function 'netbox--display-buffer) #'ignore)
                  ((symbol-function 'netbox--run-with-connectivity-check)
                   (lambda (_buffer action &optional _current-p)
                     (funcall action)))
                  ((symbol-function 'netbox-api-get-async)
                   (lambda (endpoint _id callback)
                     (push (cons endpoint callback) callbacks))))
          (netbox-show-detail "/api/dcim/devices/" 42)
          (netbox-show-detail "/api/dcim/sites/" 42)
          (should (= (length callbacks) 2))
          (should-not
           (eq (get-buffer "*NetBox: loading /api/dcim/devices #42…*")
               (get-buffer "*NetBox: loading /api/dcim/sites #42…*"))))
      (dolist (name '("*NetBox: loading /api/dcim/devices #42…*"
                      "*NetBox: loading /api/dcim/sites #42…*"))
        (when (get-buffer name)
          (kill-buffer name))))))

(ert-deftest netbox-test-endpoint-reset-preserves-custom-values ()
  (netbox-test--with-preserved-endpoints
    (setq netbox-endpoint-dcim-devices "/custom/devices/")
    (netbox--reset-endpoints "/new-api" "/api")
    (should (equal netbox-endpoint-dcim-devices "/custom/devices/"))))

(ert-deftest netbox-test-endpoint-reset-updates-default-values ()
  (netbox-test--with-preserved-endpoints
    (setq netbox-endpoint-dcim-devices "/api/dcim/devices/")
    (netbox--reset-endpoints "/new-api" "/api")
    (should (equal netbox-endpoint-dcim-devices
                   "/new-api/dcim/devices/"))))

(ert-deftest netbox-test-search-rejects-unknown-resource ()
  (should-error (netbox-search "Unknown" "query")
                :type 'user-error))

(ert-deftest netbox-test-evil-watcher-uses-new-value ()
  (let ((old-value netbox-evil-integration)
        (setup-called nil)
        (original-featurep (symbol-function 'featurep)))
    (unwind-protect
        (cl-letf (((symbol-function 'featurep)
                   (lambda (feature &optional subfeature)
                     (or (eq feature 'evil)
                         (funcall original-featurep feature subfeature))))
                  ((symbol-function 'netbox-evil-setup)
                   (lambda () (setq setup-called t))))
          (setq netbox-evil-integration t)
          (should setup-called))
      (setq netbox-evil-integration old-value))))

(ert-deftest netbox-test-evil-setup-works-when-evil-define-key-is-a-macro ()
  "Regression test for \"Invalid function: evil-define-key\".
`evil-define-key' is a macro in real Evil.  Since Evil is an optional
dependency, it is normally absent while netbox.el is byte-compiled, so
the byte-compiler cannot know that and would compile a direct call as
an ordinary function call.  At run time — once Evil is actually loaded
and `evil-define-key' turns out to be a macro — invoking that compiled
function call fails with \"Invalid function: evil-define-key\", because
macros cannot be funcalled.  `netbox-evil-setup' must therefore reach
`evil-define-key' only through `netbox--evil-define-key', which defers
to `eval' so the macro is expanded at call time instead.  This test
defines `evil-define-key' as a real macro (unknown to the byte-compiler
that already compiled netbox.el) and confirms setup succeeds and wires
up the keymap correctly."
  (unwind-protect
      (progn
        (defvar netbox-test--evil-recorded-bindings nil)
        (fset 'evil-set-initial-state (lambda (_mode _state) nil))
        (fset 'evil-normalize-keymaps (lambda (&optional _arg) nil))
        (eval '(defmacro evil-define-key (state keymap &rest bindings)
                 `(push (list ,state ',keymap ,@bindings)
                        netbox-test--evil-recorded-bindings))
              t)
        (should-not (netbox-evil-setup))
        (should netbox-test--evil-recorded-bindings))
    (fmakunbound 'evil-define-key)
    (fmakunbound 'evil-set-initial-state)
    (fmakunbound 'evil-normalize-keymaps)
    (makunbound 'netbox-test--evil-recorded-bindings)))

(provide 'test-netbox)
;;; test-netbox.el ends here
