;;; netbox.el --- Browse and search NetBox via its REST API -*- lexical-binding: t -*-

;; Copyright (C) 2026 sraupach
;; Author: sraupach <info@gehma.eu>
;; Assisted-by: GITHub-Copilot:Claude-Sonnet-4.6
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, network, netbox
;; URL: https://github.com/sraupach/netbox.el

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;;; Commentary:

;; netbox.el provides an Emacs interface for browsing, searching and
;; reading a self-hosted NetBox network documentation system via its
;; REST API.
;;
;; Quick start:
;;
;;   (setq netbox-url   "https://netbox.example.com"
;;         netbox-token "your-api-token-here")
;;   (netbox)
;;
;; Or store your token in ~/.authinfo / ~/.authinfo.gpg:
;;
;;   machine netbox.example.com login apitoken password <token>
;;
;; Then in your config:
;;
;;   (setq netbox-url "https://netbox.example.com")
;;   ;; netbox.el will look up the token via auth-source automatically.
;;
;; Key bindings inside netbox buffers:
;;
;;   RET   Open detail view / follow link
;;   g     Refresh current list
;;   q     Close buffer
;;   /     Search / filter current resource type
;;   ?     Show this help

;;; Code:

(require 'url)
(require 'url-http)
(require 'json)
(require 'auth-source)
(require 'tabulated-list)
(require 'browse-url)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; Silence byte-compiler warnings for optional evil functions.
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-normalize-keymaps "evil-core" (&optional arg))

(defmacro netbox--evil-define-key (state keymap &rest bindings)
  "Bind BINDINGS for STATE in KEYMAP using Evil's `evil-define-key'.
STATE, KEYMAP and BINDINGS are passed through to `evil-define-key'
exactly as written, unevaluated, just like a direct call to it would.

`evil-define-key' is a macro, not a function.  If Evil is not loaded
while this file is byte-compiled (the normal case, since Evil is an
optional dependency), the byte-compiler cannot know that and instead
compiles the call as an ordinary function call — which fails at run
time with \"Invalid function: evil-define-key\" once Evil actually
defines it as a macro.  Routing the call through `eval' defers macro
expansion to call time, when the real Evil macro definition (if any)
is in effect, regardless of what was known at compile time.

Note: the arguments must stay unevaluated forms (e.g. KEYMAP must
remain the bare symbol naming the keymap variable, not its value)
because `evil-define-key' itself relies on seeing that literal syntax
to resolve and track the keymap correctly."
  (declare (indent 2))
  `(eval '(evil-define-key ,state ,keymap ,@bindings) t))


;;;; ──────────────────────────────────────────────────────────
;;;; Endpoint paths
;;
;; These variables are initialised from `netbox-api-prefix' and are
;; reset automatically when that custom variable is changed.
;; Override an individual variable after loading if your installation
;; uses non-standard endpoint paths.

(defvar netbox-endpoint-dcim-sites            nil)
(defvar netbox-endpoint-dcim-racks            nil)
(defvar netbox-endpoint-dcim-devices          nil)
(defvar netbox-endpoint-dcim-interfaces       nil)
(defvar netbox-endpoint-dcim-cables           nil)
(defvar netbox-endpoint-dcim-locations        nil)
(defvar netbox-endpoint-ipam-prefixes         nil)
(defvar netbox-endpoint-ipam-addresses        nil)
(defvar netbox-endpoint-ipam-vlans            nil)
(defvar netbox-endpoint-ipam-vrfs             nil)
(defvar netbox-endpoint-ipam-ranges           nil)
(defvar netbox-endpoint-virt-clusters         nil)
(defvar netbox-endpoint-virt-vms              nil)
(defvar netbox-endpoint-virt-interfaces       nil)
(defvar netbox-endpoint-circuits-circuits     nil)
(defvar netbox-endpoint-circuits-providers    nil)
(defvar netbox-endpoint-tenancy-tenants       nil)
(defvar netbox-endpoint-tenancy-contacts      nil)

(defconst netbox--endpoint-specs
  '((netbox-endpoint-dcim-sites            . "/dcim/sites/")
    (netbox-endpoint-dcim-racks            . "/dcim/racks/")
    (netbox-endpoint-dcim-devices          . "/dcim/devices/")
    (netbox-endpoint-dcim-interfaces       . "/dcim/interfaces/")
    (netbox-endpoint-dcim-cables           . "/dcim/cables/")
    (netbox-endpoint-dcim-locations        . "/dcim/locations/")
    (netbox-endpoint-ipam-prefixes         . "/ipam/prefixes/")
    (netbox-endpoint-ipam-addresses        . "/ipam/ip-addresses/")
    (netbox-endpoint-ipam-vlans            . "/ipam/vlans/")
    (netbox-endpoint-ipam-vrfs             . "/ipam/vrfs/")
    (netbox-endpoint-ipam-ranges           . "/ipam/ip-ranges/")
    (netbox-endpoint-virt-clusters         . "/virtualization/clusters/")
    (netbox-endpoint-virt-vms              . "/virtualization/virtual-machines/")
    (netbox-endpoint-virt-interfaces       . "/virtualization/interfaces/")
    (netbox-endpoint-circuits-circuits     . "/circuits/circuits/")
    (netbox-endpoint-circuits-providers    . "/circuits/providers/")
    (netbox-endpoint-tenancy-tenants       . "/tenancy/tenants/")
    (netbox-endpoint-tenancy-contacts      . "/tenancy/contacts/"))
  "Endpoint variables and their paths relative to `netbox-api-prefix'.")

(defun netbox--reset-endpoints (prefix &optional old-prefix)
  "Set all `netbox-endpoint-*' variables using PREFIX as the API path prefix.
PREFIX should be a string like \"/api\" (no trailing slash).
When OLD-PREFIX is non-nil, update only endpoints which still use the
corresponding old default, preserving individually customized values."
  (let ((new-prefix (string-trim-right prefix "/"))
        (old-prefix (and old-prefix (string-trim-right old-prefix "/"))))
    (dolist (spec netbox--endpoint-specs)
      (let* ((variable (car spec))
             (suffix (cdr spec))
             (current (and (boundp variable) (symbol-value variable)))
             (old-default (and old-prefix (concat old-prefix suffix))))
        (when (or (null current)
                  (and old-default (equal current old-default)))
          (set variable (concat new-prefix suffix)))))))


;;;; ──────────────────────────────────────────────────────────
;;;; Customization

(defgroup netbox nil
  "Emacs interface to a NetBox instance."
  :group 'tools
  :prefix "netbox-")

(defcustom netbox-url ""
  "Base URL of your NetBox instance, e.g. \"https://netbox.example.com\".
No trailing slash."
  :type 'string
  :group 'netbox)

(defcustom netbox-token ""
  "NetBox API token.
If left empty, netbox.el will attempt to retrieve it via `auth-source'
using `netbox-url' as the host.  Store the token in ~/.authinfo as:

  machine netbox.example.com login apitoken password <token>"
  :type 'string
  :group 'netbox)

(defcustom netbox-api-prefix "/api"
  "Path prefix for the NetBox REST API.
Change this only if your installation serves the API under a non-standard
path (e.g. a reverse proxy strips or adds a prefix).
Changing this value resets all `netbox-endpoint-*' variables to use the
new prefix, unless you have already overridden them individually."
  :type 'string
  :group 'netbox
  :set (lambda (sym val)
         (let ((old-value (and (boundp sym) (default-value sym))))
           (set-default sym val)
           (netbox--reset-endpoints val old-value))))

(defcustom netbox-default-page-size 50
  "Number of results to request per API page."
  :type 'integer
  :group 'netbox)

(defcustom netbox-tls-verify t
  "Whether to verify TLS certificates when connecting to NetBox.
Set to nil to disable verification, e.g. for self-signed internal CAs."
  :type 'boolean
  :group 'netbox)

(defcustom netbox-timeout 30
  "Seconds before an API request times out."
  :type 'integer
  :group 'netbox)

(defcustom netbox-reuse-window t
  "When non-nil (default), open NetBox buffers in the selected window.
When nil, the first NetBox buffer opens in a new window that is then
reused for all subsequent NetBox navigation.  Quitting the initial
buffer also closes that window."
  :type 'boolean
  :group 'netbox)

(defvar netbox--managed-window nil
  "Window created for NetBox when `netbox-reuse-window' is nil.
Set on first display; cleared when the root buffer is quit.")

(defvar-local netbox--is-root-buffer nil
  "Non-nil in the buffer that opened the managed NetBox window.
Quitting this buffer also deletes `netbox--managed-window'.
Declared permanent-local so it survives major-mode re-initialisation.")
(put 'netbox--is-root-buffer 'permanent-local t)

(defcustom netbox-pre-fetch-check nil
  "When non-nil, verify NetBox is reachable before each API fetch.
This adds an extra network request before each operation.  Enable it when a
short preflight failure is preferable to waiting for `netbox-timeout'."
  :type 'boolean
  :group 'netbox)

(defcustom netbox-connectivity-timeout 5
  "Seconds to wait for the optional pre-fetch connectivity check.
Kept deliberately short so unreachable hosts are reported quickly."
  :type 'integer
  :group 'netbox)

(defcustom netbox-proxy nil
  "Proxy URL for NetBox API requests, or nil to inherit global settings.

Possible values:

  nil            Inherit Emacs\\=' global `url-proxy-services' (default).
                 If no global proxy is configured, requests go direct.

  \"direct\"       Force a direct connection, bypassing any globally
                 configured proxy.

  \"http://host:port\"
                 Route all NetBox requests through this proxy.
                 Credentials may be embedded in the URL:
                 \"http://user:password@proxy.corp:8080\"

The proxy is applied locally per request and never alters the global
`url-proxy-services' value."
  :type '(choice (const  :tag "Inherit global proxy settings" nil)
                 (const  :tag "Force direct connection"       "direct")
                 (string :tag "Proxy URL (http://host:port)"))
  :group 'netbox)

(defcustom netbox-cache-ttl 300
  "Seconds to cache list API responses.  Set to 0 to disable caching.
When non-zero, repeated calls to the same list endpoint with identical
query parameters reuse the cached result until TTL seconds have elapsed.
Manual refresh (\\[netbox-list-refresh]) always bypasses the cache."
  :type 'integer
  :group 'netbox)

(defcustom netbox-evil-integration nil
  "When non-nil, automatically configure evil keybindings for netbox.
Evil normal-state bindings are set up via `netbox-evil-setup' as soon as evil
is loaded.  Set this to t before or after loading netbox.el:

  (setq netbox-evil-integration t)"
  :type 'boolean
  :group 'netbox)

(defcustom netbox-precache-resources '("Devices" "IP Addresses" "Virtual Machines")
  "Resource types to pre-fetch into the cache for fast `netbox-jump'.
Each entry must be a key present in `netbox--resource-alist'.
Pre-fetching populates `netbox--cache' in the background so that the first
call to `netbox-jump' for these resources shows the prompt without delay."
  :type '(repeat string)
  :group 'netbox)

(defcustom netbox-precache-after-idle nil
  "Idle seconds after which to automatically pre-cache `netbox-precache-resources'.
Set to a positive integer (e.g. 10) to trigger `netbox-precache' once Emacs
has been idle for that many seconds.  nil disables automatic pre-caching."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'netbox)



;;;; ──────────────────────────────────────────────────────────
;;;; API client init

;; Initialise endpoints with the default prefix at load time.
;; The :set handler on netbox-api-prefix keeps them in sync thereafter.
(netbox--reset-endpoints netbox-api-prefix)

(defun netbox--endpoint (path)
  "Return the full URL for API PATH.
PATH is a relative endpoint path like \"/api/dcim/devices/\".
`netbox-url' is prepended."
  (concat (string-trim-right netbox-url "/") path))


;;;; ──────────────────────────────────────────────────────────
;;;; Auth

(defun netbox--token ()
  "Return the effective API token.
Uses `netbox-token' if non-empty, otherwise queries `auth-source'."
  (if (and netbox-token (not (string-empty-p netbox-token)))
      netbox-token
    (let* ((host (url-host (url-generic-parse-url netbox-url)))
           (found (car (auth-source-search :host host
                                           :user "apitoken"
                                           :require '(:secret)
                                           :max 1))))
      (if found
          (let ((secret (plist-get found :secret)))
            (if (functionp secret) (funcall secret) secret))
        (error "Netbox: no API token found.  Set `netbox-token' or add an \
entry to ~/.authinfo for host %s" host)))))


;;;; ──────────────────────────────────────────────────────────
;;;; API client

(defun netbox--validate-url ()
  "Signal an error if `netbox-url' is absent or malformed.
A valid value must have an http or https scheme and a non-empty host,
e.g. \"https://netbox.example.com\" or \"http://192.168.1.10:8080\"."
  (when (or (null netbox-url) (string-empty-p netbox-url))
    (error "Netbox: `netbox-url' is not set — add (setq netbox-url \"https://netbox.example.com\") to your config"))
  (let* ((parsed (url-generic-parse-url netbox-url))
         (scheme (url-type parsed))
         (host   (url-host parsed)))
    (unless (member scheme '("http" "https"))
      (error "Netbox: invalid netbox-url %S — scheme must be http or https, e.g. https://netbox.example.com"
             netbox-url))
    (when (or (null host) (string-empty-p host))
      (error "Netbox: invalid netbox-url %S — missing hostname, e.g. https://netbox.example.com"
             netbox-url))))

(defun netbox--build-url (endpoint &optional params)
  "Build a full request URL from ENDPOINT and query PARAMS alist."
  (let ((base (netbox--endpoint endpoint)))
    (if params
        (concat base "?"
                (mapconcat (lambda (p)
                             (concat (url-hexify-string (car p))
                                     "="
                                     (url-hexify-string (cdr p))))
                           params "&"))
      base)))

(defun netbox--parse-response ()
  "Parse HTTP response in current buffer; return parsed JSON or signal error."
  (goto-char (point-min))
  (let ((status (url-http-parse-response)))
    (unless (and (>= status 200) (< status 300))
      (error "netbox: HTTP %d for request" status)))
  ;; Skip headers — find the blank line separating headers from body
  (re-search-forward "\r?\n\r?\n" nil t)
  (let ((json-object-type 'alist)
        (json-array-type  'list)
        (json-key-type    'string)
        (json-false       nil)
        (json-null        nil))
    (json-read)))

(defun netbox--proxy-services ()
  "Return a `url-proxy-services' value derived from `netbox-proxy'.
Returns nil (inherit global) when `netbox-proxy' is nil,
a direct-only spec when set to \"direct\",
or an http+https proxy spec for any other string."
  (cond
   ((null netbox-proxy)            nil)
   ((equal netbox-proxy "direct")  '(("no_proxy" . ".*")))
   (t                              `(("http"  . ,netbox-proxy)
                                     ("https" . ,netbox-proxy)))))

(defun netbox--display-buffer (buf)
  "Display BUF according to `netbox-reuse-window'."
  (if netbox-reuse-window
      (switch-to-buffer buf)
    (if (and (windowp netbox--managed-window)
             (window-live-p netbox--managed-window))
        (progn
          (select-window netbox--managed-window)
          (switch-to-buffer buf))
      (switch-to-buffer-other-window buf)
      (setq netbox--managed-window (selected-window))
       (with-current-buffer buf
         (setq netbox--is-root-buffer t)))))

(defun netbox--url-retrieve-with-timeout (url callback timeout)
  "Retrieve URL asynchronously and call CALLBACK with status.
Abort the request and report an error when it exceeds TIMEOUT seconds.
The caller should dynamically bind the usual `url-request-*' variables."
  (let (request-buffer timer done)
    (setq timer
          (run-at-time
           timeout nil
           (lambda ()
             (unless done
               (setq done t)
               (when (buffer-live-p request-buffer)
                 (kill-buffer request-buffer))
               (funcall callback
                        `(:error (error timeout
                                        ,(format "Request timed out after %s seconds"
                                                 timeout))))))))
    (condition-case err
        (setq request-buffer
              (url-retrieve
               url
               (lambda (status)
                 (unless done
                   (setq done t)
                   (when (timerp timer)
                     (cancel-timer timer))
                   (funcall callback status)))
               nil t t))
      (error
       (when (timerp timer)
         (cancel-timer timer))
       (signal (car err) (cdr err))))))

(defun netbox--status-error-message (status)
  "Return a readable error message from asynchronous URL STATUS."
  (let ((err (plist-get status :error)))
    (when err
      (if (and (consp err) (eq (car err) 'error))
          (mapconcat (lambda (part) (format "%s" part)) (cddr err) ": ")
        (format "%s" err)))))

(defun netbox-quit ()
  "Quit the current NetBox buffer.
When `netbox-reuse-window' is nil and this is the root buffer (the first
one shown in the managed window), also delete that window."
  (interactive)
  (let ((is-root (and (not netbox-reuse-window)
                      netbox--is-root-buffer
                      (windowp netbox--managed-window)
                      (window-live-p netbox--managed-window)
                      (not (one-window-p))))
        (win netbox--managed-window))
    (kill-current-buffer)
    (when is-root
      (when (window-live-p win)
        (delete-window win))
      (setq netbox--managed-window nil))))

(defun netbox--check-connectivity-async (on-ok on-err)
  "Asynchronously verify NetBox is reachable, then call ON-OK or ON-ERR.
ON-OK is a zero-argument function called when the API responds successfully.
ON-ERR is a one-argument function called with an error string on failure.
Respects `netbox-pre-fetch-check' and `netbox-connectivity-timeout';
if `netbox-pre-fetch-check' is nil, ON-OK is called immediately."
  (if (not netbox-pre-fetch-check)
      (funcall on-ok)
    (condition-case err
        (let* ((ping-url (concat (string-trim-right netbox-url "/")
                                 netbox-api-prefix "/"))
               (url-request-method "GET")
               (url-request-extra-headers
                `(("Authorization" . ,(concat "Token " (netbox--token)))
                  ("Accept"        . "application/json")))
               (network-security-level (if netbox-tls-verify 'medium 'low))
               (url-proxy-services (or (netbox--proxy-services)
                                       url-proxy-services)))
          (netbox--url-retrieve-with-timeout
           ping-url
           (lambda (status)
             (let ((error-message (netbox--status-error-message status))
                   (ping-buf (current-buffer)))
               (when (buffer-live-p ping-buf)
                 (kill-buffer ping-buf))
               (if error-message
                   (funcall on-err error-message)
                 (funcall on-ok))))
           netbox-connectivity-timeout))
      (error
       (funcall on-err (error-message-string err))))))

(defun netbox--run-with-connectivity-check (buf action &optional current-p)
  "Verify NetBox is reachable, then call ACTION (a zero-argument function).
If the check fails, show an error inside BUF instead of running ACTION.
Calls ACTION directly when `netbox-pre-fetch-check' is nil.
When CURRENT-P is non-nil, call ACTION or display an error only while that
zero-argument predicate returns non-nil."
  (netbox--check-connectivity-async
   (lambda ()
     (when (or (null current-p) (funcall current-p))
       (funcall action)))
   (lambda (msg)
     (when (and (buffer-live-p buf)
                (or (null current-p) (funcall current-p)))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (propertize
                    (format "NetBox unreachable: %s\n\nCheck `netbox-url' and network connectivity.\nPress `g r' to retry."
                            msg)
                    'face 'error))))))))


(defun netbox-api-request (endpoint &optional params)
  "Perform a GET request to ENDPOINT with optional query PARAMS alist.
Returns the parsed JSON response as an alist."
  (netbox--validate-url)
  (let* ((url (netbox--build-url endpoint params))
         (url-request-method "GET")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Token " (netbox--token)))
            ("Accept"        . "application/json")
            ("Content-Type"  . "application/json")))
         (network-security-level (if netbox-tls-verify 'medium 'low))
         (url-proxy-services (or (netbox--proxy-services)
                                 url-proxy-services))
         (buf (url-retrieve-synchronously url t nil netbox-timeout)))
    (unless buf
      (error "Netbox: no response from %s" url))
    (unwind-protect
        (with-current-buffer buf
          (netbox--parse-response))
      (kill-buffer buf))))

(defun netbox-api-list (endpoint &optional params)
  "Fetch ALL results from a paginated list ENDPOINT.
PARAMS is an optional alist of extra query parameters.
Returns a flat list of result alists."
  (let* ((limit  (number-to-string netbox-default-page-size))
         (offset 0)
         (pages '())
         (done nil))
    (while (not done)
      (let* ((page-params (append params
                                  `(("limit"  . ,limit)
                                    ("offset" . ,(number-to-string offset)))))
             (response (netbox-api-request endpoint page-params))
             (count    (cdr (assoc "count" response)))
             (results  (or (cdr (assoc "results" response)) '()))
             (has-next (cdr (assoc "next" response)))
             (next-offset (+ offset (length results))))
        (push results pages)
        (cond
         ((null has-next)
          (setq done t))
         ((null results)
          (error "Netbox: pagination returned no results but advertised a next page"))
         ((and (numberp count) (>= next-offset count))
          (setq done t))
         (t
          (setq offset next-offset)))))
    (apply #'append (nreverse pages))))

(defun netbox-api-get (endpoint id)
  "Fetch a single object from ENDPOINT by integer or string ID."
  (netbox-api-request
   (concat (string-trim-right endpoint "/") "/" (format "%s" id) "/")))


;;;; ──────────────────────────────────────────────────────────
;;;; Async API client

(defun netbox-api-request-async (endpoint params callback)
  "Perform an async GET to ENDPOINT with query PARAMS alist.
CALLBACK is called as (CALLBACK RESULT ERROR-STRING) on the main thread.
RESULT is the parsed JSON alist on success, nil on failure.
ERROR-STRING is nil on success, a description string on failure."
  (condition-case err
      (progn
        (netbox--validate-url)
        (let* ((url (netbox--build-url endpoint params))
               (url-request-method "GET")
               (url-request-extra-headers
                `(("Authorization" . ,(concat "Token " (netbox--token)))
                  ("Accept"        . "application/json")
                  ("Content-Type"  . "application/json")))
               (network-security-level (if netbox-tls-verify 'medium 'low))
               (url-proxy-services (or (netbox--proxy-services)
                                       url-proxy-services)))
          (netbox--url-retrieve-with-timeout
           url
           (lambda (status)
             (let ((error-message (netbox--status-error-message status)))
               (if error-message
                   (progn
                     (when (buffer-live-p (current-buffer))
                       (kill-buffer (current-buffer)))
                     (funcall callback nil error-message))
                 (condition-case parse-err
                     (let ((result (netbox--parse-response)))
                       (kill-buffer (current-buffer))
                       (funcall callback result nil))
                   (error
                    (kill-buffer (current-buffer))
                    (funcall callback nil
                             (error-message-string parse-err)))))))
           netbox-timeout)))
    (error
     (funcall callback nil (error-message-string err)))))

(defun netbox-api-list-async (endpoint params callback &optional pages offset)
  "Async fetch of ALL results from paginated ENDPOINT using PARAMS.
Recursively fetches pages, accumulating page lists in PAGES starting at OFFSET.
Calls (CALLBACK ALL-RESULTS nil) on success or (CALLBACK nil ERROR) on failure.
Shows incremental progress in the echo area."
  (let* ((offset    (or offset 0))
         (limit-str (number-to-string netbox-default-page-size))
         (page-params (append params
                               `(("limit"  . ,limit-str)
                                 ("offset" . ,(number-to-string offset))))))
    (netbox-api-request-async
     endpoint page-params
     (lambda (response err)
       (if err
           (funcall callback nil err)
         (let* ((results (or (cdr (assoc "results" response)) '()))
                (count   (or (cdr (assoc "count"   response)) 0))
                (has-next (cdr (assoc "next" response)))
                 (pages   (cons results pages))
                 (loaded  (+ offset (length results))))
           (message "NetBox: loading… (%d/%d)" loaded count)
           (cond
            ((null has-next)
             (message "NetBox: loaded %d" loaded)
              (funcall callback (apply #'append (nreverse pages)) nil))
            ((null results)
             (funcall callback nil
                      "Pagination returned no results but advertised a next page"))
            ((and (numberp count) (>= loaded count))
             (message "NetBox: loaded %d" loaded)
              (funcall callback (apply #'append (nreverse pages)) nil))
            (t
             (netbox-api-list-async
               endpoint params callback pages loaded)))))))))

(defun netbox-api-get-async (endpoint id callback)
  "Async fetch of a single object from ENDPOINT by ID.
Calls (CALLBACK RESULT nil) on success or (CALLBACK nil ERROR) on failure."
  (netbox-api-request-async
   (concat (string-trim-right endpoint "/") "/" (format "%s" id) "/")
   nil callback))


;;;; ──────────────────────────────────────────────────────────
;;;; Response cache

(defvar netbox--cache (make-hash-table :test #'equal)
  "Cache for list API responses.
Keys contain the NetBox URL, endpoint, and query parameters.
Values are (TIMESTAMP . RESULTS) cons cells.")

(defconst netbox--cache-miss (make-symbol "netbox-cache-miss")
  "Sentinel returned when no live cache entry exists.")

(defun netbox--cache-key (endpoint params)
  "Return the cache key for ENDPOINT and PARAMS alist."
  (list (string-trim-right netbox-url "/")
        endpoint
        (mapconcat (lambda (p) (concat (car p) "=" (cdr p))) params "&")))

(defun netbox--cache-get (key)
  "Return cached results for KEY, or `netbox--cache-miss' when unavailable."
  (if (<= netbox-cache-ttl 0)
      netbox--cache-miss
    (let ((entry (gethash key netbox--cache netbox--cache-miss)))
      (if (or (eq entry netbox--cache-miss)
              (>= (- (float-time) (car entry)) netbox-cache-ttl))
          (progn
            (unless (eq entry netbox--cache-miss)
              (remhash key netbox--cache))
            netbox--cache-miss)
        (cdr entry)))))

(defun netbox--cache-put (key results)
  "Store RESULTS in the cache under KEY with the current timestamp."
  (when (> netbox-cache-ttl 0)
    (puthash key (cons (float-time) results) netbox--cache)))

(defun netbox--cache-evict (endpoint params)
  "Remove the cache entry for ENDPOINT and PARAMS."
  (remhash (netbox--cache-key endpoint params) netbox--cache))

;;;###autoload
(defun netbox-cache-clear ()
  "Flush the entire NetBox response cache."
  (interactive)
  (clrhash netbox--cache)
  (message "NetBox cache cleared."))

(defun netbox-api-list-async-cached (endpoint params callback)
  "Like `netbox-api-list-async' but serves results from cache when fresh.
If the cache has a live entry for ENDPOINT+PARAMS, CALLBACK is invoked
immediately with the cached data.  Otherwise fetches from the API and
populates the cache on success."
  (let* ((key    (netbox--cache-key endpoint params))
         (cached (netbox--cache-get key)))
    (if (not (eq cached netbox--cache-miss))
        (progn
          (message "NetBox: serving %d results from cache" (length cached))
          (funcall callback cached nil))
      (netbox-api-list-async
       endpoint params
       (lambda (results err)
         (unless err
           (netbox--cache-put key results))
         (funcall callback results err))))))

(defun netbox--alist-str (alist key)
  "Return string value for KEY in ALIST, or empty string if absent/nil."
  (let ((val (cdr (assoc key alist))))
    (cond
     ((null val)    "")
     ((stringp val) val)
     ((numberp val) (number-to-string val))
     ((listp val)   (or (cdr (assoc "label" val))
                        (cdr (assoc "display" val))
                        (cdr (assoc "name" val))
                        ""))
     (t             (format "%s" val)))))

(defun netbox--nested-str (alist &rest keys)
  "Walk nested ALIST via KEYS, returning the final value as a string."
  (let ((node alist))
    (dolist (k keys)
      (setq node (cdr (assoc k node))))
    (cond
     ((null node)    "")
     ((stringp node) node)
     ((numberp node) (number-to-string node))
     (t              (format "%s" node)))))

(defun netbox--status-face (status)
  "Return a face for STATUS string based on NetBox status semantics."
  (pcase (downcase (or status ""))
    ((or "active" "connected" "reachable" "completed" "online")
     '(:foreground "green"))
    ((or "planned" "staged")
     '(:foreground "yellow"))
    ((or "reserved" "available")
     '(:foreground "cyan"))
    ((or "decommissioning" "maintenance")
     '(:foreground "orange"))
    ((or "decommissioned" "failed" "offline" "container")
     '(:foreground "red"))
    (_
     'default)))

(defun netbox--list-make-entry (obj columns)
  "Convert OBJ alist into a tabulated-list entry using COLUMNS spec.
COLUMNS is a list of (HEADER WIDTH KEY...) where KEY... are alist keys
to walk into the nested alist (see `netbox--nested-str').
Status columns (header \"Status\") are propertized with a semantic face."
  (let ((id (or (cdr (assoc "id" obj)) 0))
        (vals (mapcar (lambda (col)
                        (let ((text (apply #'netbox--nested-str obj (cddr col))))
                          (if (equal (car col) "Status")
                              (propertize text 'face (netbox--status-face text))
                            text)))
                      columns)))
    (list id (vconcat vals))))


;;;; ──────────────────────────────────────────────────────────
;;;; Detail view

(defvar netbox-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q")         #'netbox-quit)
    (define-key map (kbd "g r")       #'netbox-detail-refresh)
    (define-key map (kbd "o")         #'netbox-detail-open-url)
    (define-key map (kbd "?")         #'netbox-help)
    (define-key map (kbd "TAB")       #'netbox-detail-next-button)
    (define-key map (kbd "<tab>")     #'netbox-detail-next-button)
    (define-key map (kbd "<backtab>") #'netbox-detail-prev-button)
    (define-key map (kbd "S-TAB")     #'netbox-detail-prev-button)
    (define-key map (kbd "y")         #'netbox-detail-yank-value)
    map)
  "Keymap for `netbox-detail-mode'.")

(define-derived-mode netbox-detail-mode special-mode "NetBox-Detail"
  "Major mode for viewing a single NetBox object.

\\{netbox-detail-mode-map}")

(defvar-local netbox-detail--endpoint nil "Endpoint used to load this object.")
(defvar-local netbox-detail--id       nil "ID of the displayed object.")
(defvar-local netbox-detail--obj      nil "Full alist of the displayed object.")
(put 'netbox-detail--endpoint 'permanent-local t)
(put 'netbox-detail--id 'permanent-local t)

(defun netbox--detail-loading-buffer-name (endpoint id)
  "Return a unique loading buffer name for ENDPOINT and ID."
  (format "*NetBox: loading %s #%s…*" (string-trim-right endpoint "/") id))

(defun netbox--render-detail (obj)
  "Insert a human-readable representation of alist OBJ into current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (dolist (pair obj)
      (let ((key (car pair))
            (val (cdr pair)))
        (insert (propertize (format "%-30s" key) 'face 'font-lock-keyword-face))
        (netbox--insert-value val)
        (insert "\n")))
    (goto-char (point-min))))

(defun netbox--insert-value (val)
  "Insert a formatted representation of VAL into the current buffer.
Navigable nested objects are rendered as clickable buttons."
  (cond
   ((null val)
    (insert (propertize "—" 'face 'font-lock-comment-face)))
   ((eq val t)
    (insert (propertize "true" 'face 'font-lock-builtin-face)))
   ((stringp val)
    (insert val))
   ((numberp val)
    (insert (number-to-string val)))
   ((listp val)
    (let* ((display  (or (cdr (assoc "display" val))
                         (cdr (assoc "name"    val))
                         (cdr (assoc "label"   val))))
           (api-url  (netbox--object-api-url val))
           (nav      (and api-url (netbox--parse-api-url api-url))))
      (cond
       ((and nav display)
        (insert-button
         display
         'face        'font-lock-string-face
         'action      (let ((ep (car nav)) (id (cdr nav)))
                        (lambda (_btn) (netbox-show-detail ep id)))
         'follow-link t
         'help-echo   "RET or click to open detail view"))
       (display
        (insert (propertize display 'face 'font-lock-string-face)))
       (t
        (insert (format "%S" val))))))
   (t
    (insert (format "%S" val)))))

(defun netbox--object-api-url (val)
  "Return the API URL string from nested object VAL alist, or nil."
  (when (listp val)
    (let ((u (cdr (assoc "url" val))))
      (when (and u (stringp u)) u))))

(defun netbox--parse-api-url (api-url)
  "Parse API-URL into (ENDPOINT . ID) suitable for `netbox-show-detail'.
API-URL is a full URL like https://netbox.example.com/api/dcim/devices/42/.
Returns nil when the URL cannot be parsed."
  (when (and api-url (stringp api-url))
    (let* ((parsed  (url-generic-parse-url api-url))
           (path    (url-filename parsed))
           (prefix  (regexp-quote (string-trim-right netbox-api-prefix "/")))
           ;; path looks like /api/dcim/devices/42/ (prefix may differ)
           (match   (string-match (concat "\\(" prefix "/.*/\\)\\([0-9]+\\)/?$") path)))
      (when match
        (cons (match-string 1 path)
              (string-to-number (match-string 2 path)))))))

(defun netbox--object-title (obj endpoint id)
  "Return a non-empty display title for OBJ from ENDPOINT with ID."
  (let ((display (netbox--alist-str obj "display"))
        (name (netbox--alist-str obj "name")))
    (cond
     ((not (string-empty-p display)) display)
     ((not (string-empty-p name)) name)
     (t (format "%s #%s" endpoint id)))))

(defun netbox-show-detail (endpoint id)
  "Display detail view for object at ENDPOINT with ID (async)."
  (let* ((buf-name (netbox--detail-loading-buffer-name endpoint id))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (netbox-detail-mode)
      (setq netbox-detail--endpoint endpoint
            netbox-detail--id       id)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Loading…" 'face 'font-lock-comment-face))))
    (netbox--display-buffer buf)
    (netbox--run-with-connectivity-check
     buf
     (lambda ()
       (netbox-api-get-async
        endpoint id
         (lambda (obj err)
           (if (or (null buf)
                   (not (buffer-live-p buf))
                   (not (equal endpoint
                               (buffer-local-value 'netbox-detail--endpoint buf)))
                   (not (equal id
                               (buffer-local-value 'netbox-detail--id buf))))
               nil
            (if err
                (with-current-buffer buf
                  (let ((inhibit-read-only t))
                    (rename-buffer
                     (format "*NetBox: %s #%s*"
                             (string-trim-right endpoint "/") id)
                     t)
                    (erase-buffer)
                    (insert (propertize
                             (format "Unable to load this object: %s\n\nPress `g r' to retry."
                                     err)
                             'face 'error))))
              (let* ((display (netbox--object-title obj endpoint id))
                     (new-name (format "*NetBox: %s*" display)))
                (with-current-buffer buf
                  (rename-buffer new-name t)
                  (setq netbox-detail--obj obj)
                   (netbox--render-detail obj))))))))
     (lambda ()
       (and (buffer-live-p buf)
            (equal endpoint
                   (buffer-local-value 'netbox-detail--endpoint buf))
            (equal id
                   (buffer-local-value 'netbox-detail--id buf)))))))

(defun netbox--api-path-to-ui-path (api-path)
  "Convert API-PATH to the corresponding NetBox web UI path.
Strips the leading `netbox-api-prefix' component, e.g.
\"/api/dcim/devices\" → \"/dcim/devices\"."
  (let ((prefix (string-trim-right netbox-api-prefix "/")))
    (if (string-prefix-p prefix api-path)
        (substring api-path (length prefix))
      api-path)))

(defun netbox-detail-open-url ()
  "Open the NetBox web UI URL of the current object in the default browser."
  (interactive)
  (if (and netbox-detail--endpoint netbox-detail--id)
      (let* ((api-path (string-trim-right netbox-detail--endpoint "/"))
             (ui-path  (netbox--api-path-to-ui-path api-path)))
        (browse-url (concat (string-trim-right netbox-url "/") ui-path "/"
                            (format "%s" netbox-detail--id) "/")))
    (user-error "No endpoint/ID for this detail buffer")))

(defun netbox-detail-next-button ()
  "Move point to the next clickable button, wrapping around if needed."
  (interactive)
  (forward-button 1 t nil t))

(defun netbox-detail-prev-button ()
  "Move point to the previous clickable button, wrapping around if needed."
  (interactive)
  (backward-button 1 t nil t))

(defun netbox-detail-yank-value ()
  "Copy the field value on the current line to the kill ring.
Each line in a detail buffer is laid out as a 30-character key followed
by the value.  The value is copied as a plain string (no text properties)."
  (interactive)
  (let* ((bol (line-beginning-position))
         (eol (line-end-position))
         (val-start (min (+ bol 30) eol))
         (str (substring-no-properties (buffer-substring val-start eol))))
    (if (string-empty-p str)
        (user-error "No value on this line")
      (kill-new str)
      (message "Copied: %s" str))))

(defvar-local netbox-list--endpoint nil
  "API endpoint for this list buffer.")
(defvar-local netbox-list--columns nil
  "Column spec for this list buffer.")
(defvar-local netbox-list--search-q nil
  "Active search query, or nil.")
(defvar-local netbox-list--title nil
  "Base display title without filter suffix.")
(defvar-local netbox-list--request-generation 0
  "Generation number of the latest list request in this buffer.")
(put 'netbox-list--request-generation 'permanent-local t)

(defun netbox-list-open-url ()
  "Open the NetBox web UI URL of the object on the current line in browser."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id
        (let* ((api-path (string-trim-right netbox-list--endpoint "/"))
               (ui-path  (netbox--api-path-to-ui-path api-path)))
          (browse-url (concat (string-trim-right netbox-url "/") ui-path "/"
                              (format "%s" id) "/")))
      (user-error "No object on this line"))))

(defun netbox-detail-refresh ()
  "Reload the current detail view from the API."
  (interactive)
  (netbox-show-detail netbox-detail--endpoint netbox-detail--id))


;;;; ──────────────────────────────────────────────────────────
;;;; List mode (tabulated-list-mode derivative)

(defvar netbox-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'netbox-list-open-detail)
    (define-key map (kbd "g r") #'netbox-list-refresh)
    (define-key map (kbd "o")   #'netbox-list-open-url)
    (define-key map (kbd "q")   #'netbox-quit)
    (define-key map (kbd "/")   #'netbox-list-search)
    (define-key map (kbd "F")   #'netbox-list-edit-filter)
    (define-key map (kbd "?")   #'netbox-help)
    map)
  "Keymap for `netbox-list-mode'.")

(define-derived-mode netbox-list-mode tabulated-list-mode "NetBox"
  "Major mode for browsing a list of NetBox objects.

\\{netbox-list-mode-map}")

(defun netbox--auto-size-columns (entries columns)
  "Return COLUMNS with widths expanded to fit the widest value in ENTRIES.
Each column width is the max of its declared width and the widest rendered
string in that column across all ENTRIES.  A padding of 2 is added."
  (let* ((ncols  (length columns))
         (widths (mapcar (lambda (c) (max (cadr c) (length (car c)))) columns)))
    (dolist (entry entries)
      (let ((vals (cadr entry)))
        (dotimes (i ncols)
          (when (< i (length vals))
            (let* ((cell (aref vals i))
                   (w    (length (if (stringp cell)
                                     cell
                                   (substring-no-properties cell)))))
              (when (> w (nth i widths))
                (setf (nth i widths) w)))))))
    (cl-mapcar (lambda (col w)
                 (cons (car col) (cons (+ w 2) (cddr col))))
               columns widths)))

(defun netbox--list-update-display ()
  "Sync buffer name and mode-line with the current filter state."
  (let* ((base (or netbox-list--title "NetBox"))
         (q    netbox-list--search-q))
    (rename-buffer (format "*NetBox: %s*" base) t)
    (setq mode-name (if q
                        (concat "NetBox[" (propertize q 'face 'font-lock-string-face) "]")
                      "NetBox"))
    (force-mode-line-update)))

(defun netbox--list-show-error (message-text)
  "Replace the current list contents with MESSAGE-TEXT as an error row."
  (let* ((columns netbox-list--columns)
         (cells (cons (propertize (concat "Error: " message-text) 'face 'error)
                      (make-list (max 0 (1- (length columns))) "")))
         (inhibit-read-only t))
    (setq tabulated-list-entries (list (list nil (vconcat cells))))
    (tabulated-list-print t)
    (message "NetBox: error: %s" message-text)))

(defun netbox-list-populate ()
  "Async fetch data from the API and repopulate the current list buffer."
  (let* ((buf      (current-buffer))
         (generation (cl-incf netbox-list--request-generation))
         (endpoint netbox-list--endpoint)
         (columns  netbox-list--columns)
         (params   (when netbox-list--search-q
                     `(("q" . ,netbox-list--search-q)))))
    ;; Show placeholder immediately so the buffer feels responsive
    (let ((inhibit-read-only t))
      (setq tabulated-list-entries
            (list (list nil
                        (vconcat
                         (mapcar
                          (lambda (_)
                            (propertize "Loading…" 'face 'font-lock-comment-face))
                          columns)))))
      (tabulated-list-print t))
    (netbox--run-with-connectivity-check
     buf
     (lambda ()
       (netbox-api-list-async-cached
        endpoint params
        (lambda (objects err)
           (when (and (buffer-live-p buf)
                      (= generation
                         (buffer-local-value 'netbox-list--request-generation buf)))
            (with-current-buffer buf
              (if err
                  (netbox--list-show-error err)
                (let* ((entries (mapcar (lambda (o)
                                          (netbox--list-make-entry o columns))
                                        objects))
                       (sized-columns (netbox--auto-size-columns entries columns)))
                  (setq tabulated-list-entries entries
                        netbox-list--columns   sized-columns
                        tabulated-list-format
                        (vconcat (mapcar (lambda (c) (list (car c) (cadr c) t))
                                         sized-columns)))
                  (let ((inhibit-read-only t))
                     (tabulated-list-init-header)
                     (tabulated-list-print)))))))))
     (lambda ()
       (and (buffer-live-p buf)
            (= generation
               (buffer-local-value 'netbox-list--request-generation buf)))))))

(defun netbox-list-setup (endpoint columns title &optional search-q)
  "Set up current buffer as a netbox list for ENDPOINT.
COLUMNS is a list of (HEADER WIDTH KEY...).  TITLE is the buffer name.
Optional SEARCH-Q pre-fills the search filter before the first fetch."
  (netbox-list-mode)
  (setq netbox-list--endpoint endpoint
        netbox-list--columns  columns
        netbox-list--title    title
        netbox-list--search-q search-q
        tabulated-list-format
        (vconcat (mapcar (lambda (c) (list (car c) (cadr c) t)) columns))
        tabulated-list-sort-key nil)
  (tabulated-list-init-header)
  (netbox--list-update-display)
  (netbox-list-populate))

(defun netbox-list-open-detail ()
  "Open the detail view for the object on the current line."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id
        (netbox-show-detail netbox-list--endpoint id)
      (user-error "No object on this line"))))

(defun netbox-list-refresh ()
  "Refresh the current list from the API, bypassing the cache."
  (interactive)
  (netbox--cache-evict netbox-list--endpoint
                       (when netbox-list--search-q
                         `(("q" . ,netbox-list--search-q))))
  (netbox-list-populate))

(defun netbox-list-search (query)
  "Filter the current list by QUERY using the NetBox ?q= parameter.
An empty QUERY clears the filter and shows all objects."
  (interactive "sSearch query: ")
  (setq netbox-list--search-q (if (string-empty-p query) nil query))
  (netbox--list-update-display)
  (netbox-list-populate))

(defun netbox-list-edit-filter ()
  "Edit the active filter query, pre-filled with the current value.
Press RET to apply; clear the prompt and press RET to remove the filter."
  (interactive)
  (let* ((current (or netbox-list--search-q ""))
         (query   (read-string "Filter query (empty to clear): " current)))
    (setq netbox-list--search-q (if (string-empty-p query) nil query))
    (netbox--list-update-display)
    (netbox-list-populate)))


;;;; ──────────────────────────────────────────────────────────
;;;; Help buffer

(defun netbox-help ()
  "Show a help buffer listing all netbox key bindings and commands."
  (interactive)
  (let ((buf (get-buffer-create "*NetBox Help*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "NetBox — Key Bindings & Commands\n" 'face '(bold (:height 1.2))))
        (insert (make-string 50 ?─) "\n\n")

        (insert (propertize "List buffer  (*NetBox: <Resource>*)\n" 'face 'bold))
        (netbox--help-row "RET"            "Open detail view for selected row")
        (netbox--help-row "g r"            "Refresh list from API")
        (netbox--help-row "o"              "Open object URL in browser")
        (netbox--help-row "/"              "Set new filter query (uses ?q=)")
        (netbox--help-row "F"              "Edit current filter query (pre-filled)")
        (netbox--help-row "q"              "Close buffer")
        (netbox--help-row "?"              "Show this help")
        (netbox--help-row "↑ / ↓"          "Move between rows")
        (insert "\n")

        (insert (propertize "Detail buffer  (*NetBox: <Name>*)\n" 'face 'bold))
        (netbox--help-row "RET"          "Follow link to a related object")
        (netbox--help-row "g r"          "Reload object from API")
        (netbox--help-row "o"            "Open object URL in browser")
        (netbox--help-row "y"            "Copy field value at point to kill ring")
        (netbox--help-row "TAB / S-TAB"  "Move to next / previous link")
        (netbox--help-row "q"            "Close buffer")
        (netbox--help-row "?"            "Show this help")
        (insert "\n")

        (insert (propertize "Global M-x commands\n" 'face 'bold))
        (netbox--help-row "M-x netbox"                    "Open resource picker (main entry point)")
        (netbox--help-row "M-x netbox-super-search"       "Search ALL resource types at once")
        (netbox--help-row "M-x netbox-search"             "Search a specific resource type")
        (netbox--help-row "M-x netbox-jump"               "Jump to any object by name (completing-read)")
        (netbox--help-row "M-x netbox-precache"           "Pre-fetch resources into cache in background")
        (netbox--help-row "M-x netbox-check-config"       "Validate config & test connectivity")
        (netbox--help-row "M-x netbox-cache-clear"        "Flush the entire response cache")
        (netbox--help-row "M-x netbox-dcim-sites"         "Browse DCIM → Sites")
        (netbox--help-row "M-x netbox-dcim-racks"         "Browse DCIM → Racks")
        (netbox--help-row "M-x netbox-dcim-devices"       "Browse DCIM → Devices")
        (netbox--help-row "M-x netbox-dcim-interfaces"    "Browse DCIM → Interfaces")
        (netbox--help-row "M-x netbox-dcim-cables"        "Browse DCIM → Cables")
        (netbox--help-row "M-x netbox-dcim-locations"     "Browse DCIM → Locations")
        (netbox--help-row "M-x netbox-ipam-prefixes"      "Browse IPAM → Prefixes")
        (netbox--help-row "M-x netbox-ipam-addresses"     "Browse IPAM → IP Addresses")
        (netbox--help-row "M-x netbox-ipam-vlans"         "Browse IPAM → VLANs")
        (netbox--help-row "M-x netbox-ipam-vrfs"          "Browse IPAM → VRFs")
        (netbox--help-row "M-x netbox-ipam-ranges"        "Browse IPAM → IP Ranges")
        (netbox--help-row "M-x netbox-virt-clusters"      "Browse Virtualization → Clusters")
        (netbox--help-row "M-x netbox-virt-vms"           "Browse Virtualization → VMs")
        (netbox--help-row "M-x netbox-virt-interfaces"    "Browse Virtualization → VM Interfaces")
        (netbox--help-row "M-x netbox-circuits"           "Browse Circuits")
        (netbox--help-row "M-x netbox-circuits-providers" "Browse Circuit Providers")
        (netbox--help-row "M-x netbox-tenancy-tenants"    "Browse Tenancy → Tenants")
        (netbox--help-row "M-x netbox-tenancy-contacts"   "Browse Tenancy → Contacts")
        (insert "\n")

        (insert (propertize "Configuration  (setq in init.el or M-x customize-group RET netbox)\n"
                            'face 'bold))
        (netbox--help-row "netbox-url"               "Base URL of your NetBox instance")
        (netbox--help-row "netbox-token"             "API token (or leave empty for auth-source)")
        (netbox--help-row "netbox-api-prefix"        "API path prefix (default \"/api\")")
        (netbox--help-row "netbox-proxy"             "Proxy URL, \"direct\", or nil")
        (netbox--help-row "netbox-tls-verify"        "nil to disable TLS verification")
        (netbox--help-row "netbox-default-page-size" "Results per page (default 50)")
        (netbox--help-row "netbox-precache-resources" "Resources to pre-fetch for netbox-jump")
        (netbox--help-row "netbox-precache-after-idle" "Idle seconds before auto-pre-caching (nil=off)")
        (insert "\n"))
      (special-mode)
      (goto-char (point-min)))
    (display-buffer buf)))

(defun netbox--help-row (key desc)
  "Insert a single help row with KEY left-aligned and DESC."
  (insert (propertize (format "  %-36s" key) 'face 'font-lock-keyword-face)
          desc "\n"))


;;;; ──────────────────────────────────────────────────────────
;;;; Resource column specs

(defvar netbox-columns-dcim-sites
  '(("Name"        25 "name")
    ("Slug"        20 "slug")
    ("Status"      12 "status" "label")
    ("Region"      20 "region" "name")
    ("Description" 40 "description"))
  "Column spec for DCIM Sites list.")

(defvar netbox-columns-dcim-racks
  '(("Name"        10 "name")
    ("Site"        20 "site" "name")
    ("Location"    20 "location" "name")
    ("Status"      12 "status" "label")
    ("U height"     8 "u_height")
    ("Device Count" 3 "device_count"))
  "Column spec for DCIM Racks list.")

(defvar netbox-columns-dcim-devices
  '(("Name"        25 "name")
    ("Site"        20 "site" "name")
    ("Rack"        15 "rack" "name")
    ("Type"        25 "device_type" "display")
    ("Status"      12 "status" "label")
    ("Primary IP"  18 "primary_ip" "address"))
  "Column spec for DCIM Devices list.")

(defvar netbox-columns-dcim-interfaces
  '(("Name"        25 "name")
    ("Device"      20 "device" "name")
    ("Type"        20 "type" "label")
    ("MAC"         18 "mac_address")
    ("Description" 35 "description"))
  "Column spec for DCIM Interfaces list.")

(defvar netbox-columns-dcim-cables
  '(("ID"           6 "id")
    ("A Termination" 30 "a_terminations")
    ("B Termination" 30 "b_terminations")
    ("Status"        12 "status" "label")
    ("Label"         20 "label"))
  "Column spec for DCIM Cables list.")

(defvar netbox-columns-ipam-prefixes
  '(("Prefix"      25 "prefix")
    ("VRF"         15 "vrf" "name")
    ("Description" 30 "description")
    ("Scope"       15 "scope")
    ("Status"      12 "status" "label")
    ("Tenant"      15 "tenant" "name"))
  "Column spec for IPAM Prefixes list.")

(defvar netbox-columns-ipam-addresses
  '(("Address"     25 "address")
    ("VRF"         15 "vrf" "name")
    ("Status"      12 "status" "label")
    ("DNS Name"    30 "dns_name")
    ("Assigned To" 25 "assigned_object" "display")
    ("Description" 30 "description"))
  "Column spec for IPAM IP Addresses list.")

(defvar netbox-columns-ipam-vlans
  '(("VID"          6 "vid")
    ("Name"         25 "name")
    ("Site"         20 "site" "name")
    ("Group"        20 "group" "name")
    ("Status"       12 "status" "label")
    ("Description"  30 "description"))
  "Column spec for IPAM VLANs list.")

(defvar netbox-columns-ipam-vrfs
  '(("Name"        25 "name")
    ("RD"          20 "rd")
    ("Tenant"      20 "tenant" "name")
    ("Description" 40 "description"))
  "Column spec for IPAM VRFs list.")

(defvar netbox-columns-virt-clusters
  '(("Name"        25 "name")
    ("Type"        20 "type" "name")
    ("Group"       20 "group" "name")
    ("Site"        20 "site" "name")
    ("Status"      12 "status" "label"))
  "Column spec for Virtualization Clusters list.")

(defvar netbox-columns-virt-vms
  '(("Name"        20 "name")
    ("Cluster"     15 "cluster" "name")
    ("Status"      12 "status" "label")
    ("vCPUs"        6 "vcpus")
    ("Memory"       8 "memory")
    ("Primary IP"  18 "primary_ip" "address"))
  "Column spec for Virtualization Virtual Machines list.")

(defvar netbox-columns-circuits-circuits
  '(("CID"         15 "cid")
    ("Provider"    20 "provider" "name")
    ("Type"        20 "type" "name")
    ("Status"      12 "status" "label")
    ("Tenant"      20 "tenant" "name")
    ("Description" 35 "description"))
  "Column spec for Circuits list.")

(defvar netbox-columns-circuits-providers
  '(("Name"        25 "name")
    ("Slug"        20 "slug")
    ("ASN"         10 "asn")
    ("Account"     20 "account")
    ("Comments"    35 "comments"))
  "Column spec for Circuit Providers list.")

(defvar netbox-columns-tenancy-tenants
  '(("Name"        25 "name")
    ("Slug"        20 "slug")
    ("Group"       20 "group" "name")
    ("Description" 45 "description"))
  "Column spec for Tenancy Tenants list.")

(defvar netbox-columns-dcim-locations
  '(("Name"        25 "name")
    ("Site"        20 "site" "name")
    ("Parent"      20 "parent" "name")
    ("Status"      12 "status" "label")
    ("Description" 40 "description"))
  "Column spec for DCIM Locations list.")

(defvar netbox-columns-ipam-ranges
  '(("Start Address" 20 "start_address")
    ("End Address"   20 "end_address")
    ("VRF"           15 "vrf" "name")
    ("Status"        12 "status" "label")
    ("Tenant"        15 "tenant" "name")
    ("Description"   35 "description"))
  "Column spec for IPAM IP Ranges list.")

(defvar netbox-columns-tenancy-contacts
  '(("Name"        25 "name")
    ("Title"       20 "title")
    ("Phone"       18 "phone")
    ("Email"       30 "email")
    ("Group"       20 "group" "name"))
  "Column spec for Tenancy Contacts list.")

(defvar netbox-columns-virt-interfaces
  '(("Name"        25 "name")
    ("VM"          25 "virtual_machine" "name")
    ("MAC"         18 "mac_address")
    ("Enabled"      8 "enabled")
    ("Description" 35 "description"))
  "Column spec for Virtualization VM Interfaces list.")


;;;; ──────────────────────────────────────────────────────────
;;;; Public list commands

;;;###autoload
(defun netbox-dcim-sites ()
  "Browse NetBox DCIM Sites."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Sites*")
    (netbox-list-setup netbox-endpoint-dcim-sites
                       netbox-columns-dcim-sites "Sites")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-dcim-racks ()
  "Browse NetBox DCIM Racks."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Racks*")
    (netbox-list-setup netbox-endpoint-dcim-racks
                       netbox-columns-dcim-racks "Racks")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-dcim-devices ()
  "Browse NetBox DCIM Devices."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Devices*")
    (netbox-list-setup netbox-endpoint-dcim-devices
                       netbox-columns-dcim-devices "Devices")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-dcim-interfaces ()
  "Browse NetBox DCIM Interfaces."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Interfaces*")
    (netbox-list-setup netbox-endpoint-dcim-interfaces
                       netbox-columns-dcim-interfaces "Interfaces")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-dcim-cables ()
  "Browse NetBox DCIM Cables."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Cables*")
    (netbox-list-setup netbox-endpoint-dcim-cables
                       netbox-columns-dcim-cables "Cables")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-ipam-prefixes ()
  "Browse NetBox IPAM Prefixes."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Prefixes*")
    (netbox-list-setup netbox-endpoint-ipam-prefixes
                       netbox-columns-ipam-prefixes "Prefixes")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-ipam-addresses ()
  "Browse NetBox IPAM IP Addresses."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: IP Addresses*")
    (netbox-list-setup netbox-endpoint-ipam-addresses
                       netbox-columns-ipam-addresses "IP Addresses")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-ipam-vlans ()
  "Browse NetBox IPAM VLANs."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: VLANs*")
    (netbox-list-setup netbox-endpoint-ipam-vlans
                       netbox-columns-ipam-vlans "VLANs")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-ipam-vrfs ()
  "Browse NetBox IPAM VRFs."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: VRFs*")
    (netbox-list-setup netbox-endpoint-ipam-vrfs
                       netbox-columns-ipam-vrfs "VRFs")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-virt-clusters ()
  "Browse NetBox Virtualization Clusters."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Clusters*")
    (netbox-list-setup netbox-endpoint-virt-clusters
                       netbox-columns-virt-clusters "Clusters")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-virt-vms ()
  "Browse NetBox Virtualization Virtual Machines."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Virtual Machines*")
    (netbox-list-setup netbox-endpoint-virt-vms
                       netbox-columns-virt-vms "Virtual Machines")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-circuits ()
  "Browse NetBox Circuits."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Circuits*")
    (netbox-list-setup netbox-endpoint-circuits-circuits
                       netbox-columns-circuits-circuits "Circuits")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-circuits-providers ()
  "Browse NetBox Circuit Providers."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Providers*")
    (netbox-list-setup netbox-endpoint-circuits-providers
                       netbox-columns-circuits-providers "Providers")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-tenancy-tenants ()
  "Browse NetBox Tenancy Tenants."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Tenants*")
    (netbox-list-setup netbox-endpoint-tenancy-tenants
                       netbox-columns-tenancy-tenants "Tenants")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-dcim-locations ()
  "Browse NetBox DCIM Locations."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Locations*")
    (netbox-list-setup netbox-endpoint-dcim-locations
                       netbox-columns-dcim-locations "Locations")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-ipam-ranges ()
  "Browse NetBox IPAM IP Ranges."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: IP Ranges*")
    (netbox-list-setup netbox-endpoint-ipam-ranges
                       netbox-columns-ipam-ranges "IP Ranges")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-tenancy-contacts ()
  "Browse NetBox Tenancy Contacts."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: Contacts*")
    (netbox-list-setup netbox-endpoint-tenancy-contacts
                       netbox-columns-tenancy-contacts "Contacts")
    (netbox--display-buffer (current-buffer))))

;;;###autoload
(defun netbox-virt-interfaces ()
  "Browse NetBox Virtualization VM Interfaces."
  (interactive)
  (with-current-buffer (get-buffer-create "*NetBox: VM Interfaces*")
    (netbox-list-setup netbox-endpoint-virt-interfaces
                       netbox-columns-virt-interfaces "VM Interfaces")
    (netbox--display-buffer (current-buffer))))


;;;; ──────────────────────────────────────────────────────────
;;;; Search

(defconst netbox--resource-alist
  '(("Sites"            . (netbox-endpoint-dcim-sites          . netbox-columns-dcim-sites))
    ("Racks"            . (netbox-endpoint-dcim-racks          . netbox-columns-dcim-racks))
    ("Devices"          . (netbox-endpoint-dcim-devices        . netbox-columns-dcim-devices))
    ("Interfaces"       . (netbox-endpoint-dcim-interfaces     . netbox-columns-dcim-interfaces))
    ("Cables"           . (netbox-endpoint-dcim-cables         . netbox-columns-dcim-cables))
    ("Locations"        . (netbox-endpoint-dcim-locations      . netbox-columns-dcim-locations))
    ("Prefixes"         . (netbox-endpoint-ipam-prefixes       . netbox-columns-ipam-prefixes))
    ("IP Addresses"     . (netbox-endpoint-ipam-addresses      . netbox-columns-ipam-addresses))
    ("VLANs"            . (netbox-endpoint-ipam-vlans          . netbox-columns-ipam-vlans))
    ("VRFs"             . (netbox-endpoint-ipam-vrfs           . netbox-columns-ipam-vrfs))
    ("IP Ranges"        . (netbox-endpoint-ipam-ranges         . netbox-columns-ipam-ranges))
    ("Clusters"         . (netbox-endpoint-virt-clusters       . netbox-columns-virt-clusters))
    ("Virtual Machines" . (netbox-endpoint-virt-vms            . netbox-columns-virt-vms))
    ("VM Interfaces"    . (netbox-endpoint-virt-interfaces     . netbox-columns-virt-interfaces))
    ("Circuits"         . (netbox-endpoint-circuits-circuits   . netbox-columns-circuits-circuits))
    ("Providers"        . (netbox-endpoint-circuits-providers  . netbox-columns-circuits-providers))
    ("Tenants"          . (netbox-endpoint-tenancy-tenants     . netbox-columns-tenancy-tenants))
    ("Contacts"         . (netbox-endpoint-tenancy-contacts    . netbox-columns-tenancy-contacts)))
  "Alist mapping resource display names to (ENDPOINT-VAR . COLUMNS-VAR) pairs.")

;;;###autoload
(defun netbox-search (resource query)
  "Search NetBox RESOURCE (chosen via `completing-read') for QUERY string.
Opens a list buffer filtered by the ?q= API parameter."
  (interactive
   (list (completing-read "Resource: " (mapcar #'car netbox--resource-alist) nil t)
         (read-string "Query: ")))
  (let ((entry (cdr (assoc resource netbox--resource-alist))))
    (unless entry
      (user-error "Unknown NetBox resource: %s" resource))
    (let* ((query (and query (not (string-empty-p query)) query))
           (endpoint (symbol-value (car entry)))
           (columns (symbol-value (cdr entry))))
      (with-current-buffer (get-buffer-create (format "*NetBox: %s*" resource))
        (netbox-list-setup endpoint columns resource query)
        (netbox--display-buffer (current-buffer))))))


;;;; ──────────────────────────────────────────────────────────
;;;; Super search (cross-resource)

(defvar netbox-columns-super-search
  '(("Type"        18 "object_type")
    ("Name"        30 "display")
    ("Description" 40 "description")
    ("URL"         45 "url"))
  "Column spec for the super search results list.")

(defun netbox--super-search-make-entry (obj)
  "Convert a search result OBJ into a tabulated-list entry.
OBJ is an alist with an injected \"object_type\" key (the human-readable
resource name) prepended during the parallel fetch."
  (let* ((object-id (or (cdr (assoc "id" obj)) (sxhash obj)))
         (obj-type (or (cdr (assoc "object_type" obj)) ""))
         (display  (or (cdr (assoc "display" obj))
                       (cdr (assoc "name" obj)) ""))
         (desc     (or (cdr (assoc "description" obj)) ""))
         (url      (or (cdr (assoc "url" obj)) ""))
         (row-id   (if (string-empty-p url)
                       (cons obj-type object-id)
                     url)))
    (list row-id (vector obj-type display desc url))))

(defun netbox--super-search-open-detail ()
  "Open the detail view for the search result on the current line.
Parses the object's API URL to determine the endpoint and ID."
  (interactive)
  (let* ((id  (tabulated-list-get-id))
         (entry (and id (assoc id tabulated-list-entries)))
         (cols  (and entry (cadr entry)))
         (url   (and cols (aref cols 3))))
    (if (and url (not (string-empty-p url)))
        (let ((nav (netbox--parse-api-url url)))
          (if nav
              (netbox-show-detail (car nav) (cdr nav))
            (user-error "Cannot parse API URL: %s" url)))
      (user-error "No URL for this result"))))

(defvar netbox-super-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'netbox--super-search-open-detail)
    (define-key map (kbd "g r") #'netbox-super-search-refresh)
    (define-key map (kbd "o")   #'netbox--super-search-open-browser-url)
    (define-key map (kbd "q")   #'netbox-quit)
    (define-key map (kbd "/")   #'netbox-super-search-requery)
    (define-key map (kbd "F")   #'netbox-super-search-edit-query)
    (define-key map (kbd "?")   #'netbox-help)
    map)
  "Keymap for `netbox-super-search-mode'.")

(define-derived-mode netbox-super-search-mode tabulated-list-mode "NetBox-Search"
  "Major mode for displaying cross-resource NetBox search results.

\\{netbox-super-search-mode-map}")

(defvar-local netbox-super-search--query nil "Active super search query.")
(defvar-local netbox-super-search--request-generation 0
  "Generation number of the latest super-search request in this buffer.")
(put 'netbox-super-search--request-generation 'permanent-local t)

(defun netbox--super-search-open-browser-url ()
  "Open the NetBox web UI URL for the result on the current line."
  (interactive)
  (let* ((id  (tabulated-list-get-id))
         (entry (and id (assoc id tabulated-list-entries)))
         (cols  (and entry (cadr entry)))
         (api-url (and cols (aref cols 3))))
    (if (and api-url (not (string-empty-p api-url)))
        (let ((nav (netbox--parse-api-url api-url)))
          (if nav
              (let ((ui-path (netbox--api-path-to-ui-path
                              (string-trim-right (car nav) "/"))))
                (browse-url (concat (string-trim-right netbox-url "/") ui-path "/"
                                    (format "%s" (cdr nav)) "/")))
            (user-error "Cannot parse URL: %s" api-url)))
      (user-error "No URL for this result"))))

(defun netbox-super-search-refresh ()
  "Re-run the current super search query."
  (interactive)
  (when netbox-super-search--query
    (netbox--super-search-populate netbox-super-search--query)))

(defun netbox-super-search-requery (query)
  "Run a new super search QUERY, replacing the current results."
  (interactive "sSuper search: ")
  (setq netbox-super-search--query (if (string-empty-p query) nil query))
  (unless netbox-super-search--query
    (cl-incf netbox-super-search--request-generation))
  (setq mode-name (if netbox-super-search--query
                      (concat "NetBox-Search["
                              (propertize netbox-super-search--query
                                          'face 'font-lock-string-face)
                              "]")
                    "NetBox-Search"))
  (force-mode-line-update)
  (if netbox-super-search--query
      (netbox--super-search-populate netbox-super-search--query)
    (let ((inhibit-read-only t))
      (setq tabulated-list-entries nil)
      (tabulated-list-print t))))

(defun netbox-super-search-edit-query ()
  "Edit the current super search query (pre-filled)."
  (interactive)
  (let ((query (read-string "Super search (empty to clear): "
                            (or netbox-super-search--query ""))))
    (netbox-super-search-requery query)))

(defun netbox--super-search-populate (query)
  "Fetch search results for QUERY across all resource types.
Queries each known resource endpoint with ?q= in parallel and merges
results into a single list."
  (let ((buf (current-buffer))
        (generation (cl-incf netbox-super-search--request-generation))
        (columns netbox-columns-super-search)
        (endpoints (mapcar (lambda (entry)
                             (cons (car entry)
                                   (symbol-value (car (cdr entry)))))
                           netbox--resource-alist))
        (all-results '())
        (pending 0)
        (had-error nil))
    (let ((inhibit-read-only t))
      (setq tabulated-list-entries
            (list (list 0 (vconcat
                           (mapcar (lambda (_) (propertize "Searching…" 'face 'font-lock-comment-face))
                                   columns)))))
      (tabulated-list-print t))
    (netbox--run-with-connectivity-check
     buf
     (lambda ()
       (setq pending (length endpoints))
       (dolist (ep-entry endpoints)
         (let ((type-name (car ep-entry))
               (endpoint  (cdr ep-entry)))
           (netbox-api-request-async
            endpoint
            `(("q" . ,query) ("limit" . "50") ("brief" . "1"))
            (lambda (response err)
              (if err
                  (setq had-error t)
                (let ((results (or (cdr (assoc "results" response)) '())))
                  (dolist (obj results)
                    (push (cons (cons "object_type" type-name) obj) all-results))))
              (cl-decf pending)
              (when (and (zerop pending)
                         (buffer-live-p buf)
                         (= generation
                            (buffer-local-value
                             'netbox-super-search--request-generation buf)))
                (with-current-buffer buf
                  (let* ((entries (mapcar #'netbox--super-search-make-entry all-results))
                         (display-entries
                          (if (and had-error (null entries))
                              (list
                               (list nil
                                     (vector
                                      (propertize "Error" 'face 'error)
                                      "All resource requests failed"
                                      ""
                                      "")))
                            entries))
                         (sized (netbox--auto-size-columns display-entries columns)))
                    (setq tabulated-list-entries display-entries
                          tabulated-list-format
                          (vconcat (mapcar (lambda (c) (list (car c) (cadr c) t))
                                           sized)))
                    (let ((inhibit-read-only t))
                      (tabulated-list-init-header)
                      (tabulated-list-print))
                    (message "NetBox: %d results for \"%s\"%s"
                              (length entries) query
                              (if had-error " (some endpoints failed)" ""))))))))))
     (lambda ()
       (and (buffer-live-p buf)
            (= generation
               (buffer-local-value
                'netbox-super-search--request-generation buf)))))))

;;;###autoload
(defun netbox-super-search (query)
  "Search across ALL NetBox resource types for QUERY.
Queries every known resource endpoint with ?q= in parallel and merges
results into a single list.  Columns show Type, Name, Description and
API URL.  Press RET to open the detail view for any result."
  (interactive "sSuper search: ")
  (when (string-empty-p query)
    (user-error "Search query cannot be empty"))
  (let* ((buf (get-buffer-create "*NetBox: Super Search*"))
         (columns netbox-columns-super-search))
    (with-current-buffer buf
      (netbox-super-search-mode)
      (setq netbox-super-search--query query
            tabulated-list-format
            (vconcat (mapcar (lambda (c) (list (car c) (cadr c) t)) columns))
            tabulated-list-sort-key nil)
      (tabulated-list-init-header)
      (setq mode-name (concat "NetBox-Search["
                              (propertize query 'face 'font-lock-string-face) "]"))
      (force-mode-line-update)
      (rename-buffer "*NetBox: Super Search*" t)
      (netbox--super-search-populate query))
    (netbox--display-buffer buf)))

;;;###autoload
(defun netbox (&optional search-query)
  "Open the NetBox dashboard — choose a resource to browse.
With a prefix argument (\\[universal-argument]), prompt for a search
query to pre-filter the list.  SEARCH-QUERY may also be supplied
programmatically."
  (interactive
   (list (when current-prefix-arg
           (read-string "Search query: "))))
  (let* ((resource (completing-read "NetBox resource: "
                                    (mapcar #'car netbox--resource-alist)
                                    nil t))
         (entry    (cdr (assoc resource netbox--resource-alist)))
         (endpoint (symbol-value (car entry)))
         (columns  (symbol-value (cdr entry)))
         (query    (and search-query (not (string-empty-p search-query))
                        search-query)))
    (with-current-buffer (get-buffer-create (format "*NetBox: %s*" resource))
      (netbox-list-setup endpoint columns resource query)
      (netbox--display-buffer (current-buffer)))))


;;;; ──────────────────────────────────────────────────────────
;;;; Configuration check

(defvar netbox-config-check-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'netbox-quit)
    map)
  "Keymap for `netbox-config-check-mode'.")

(define-derived-mode netbox-config-check-mode special-mode "NetBox-Config"
  "Major mode for the NetBox configuration check buffer.

\\{netbox-config-check-mode-map}")

;;;###autoload
(defun netbox-check-config ()
  "Validate configuration and test connectivity to the NetBox instance.
Displays a diagnostic report in the *NetBox config check* buffer."
  (interactive)
  (let ((buf (get-buffer-create "*NetBox config check*"))
        (checks '()))
    ;; 1. netbox-url present and well-formed
    (push (cons "netbox-url set"
                (and netbox-url (not (string-empty-p netbox-url))))
          checks)
    (let* ((parsed (and netbox-url
                        (not (string-empty-p netbox-url))
                        (url-generic-parse-url netbox-url)))
           (scheme (and parsed (url-type parsed)))
           (host   (and parsed (url-host parsed))))
      (push (cons "netbox-url scheme (http/https)"
                  (member scheme '("http" "https")))
            checks)
      (push (cons "netbox-url has hostname"
                  (and host (not (string-empty-p host))))
            checks))
    ;; 2. token available
    (push (cons "API token configured"
                (or (and netbox-token (not (string-empty-p netbox-token)))
                    (and netbox-url
                         (not (string-empty-p netbox-url))
                         (let ((host (url-host (url-generic-parse-url netbox-url))))
                           (car (auth-source-search :host host
                                                    :user "apitoken"
                                                    :max 1))))))
          checks)
    ;; 4. precache sanity: cache must be enabled for precaching to be useful
    (when netbox-precache-after-idle
      (push (cons "Cache enabled (required for netbox-precache-after-idle)"
                  (> netbox-cache-ttl 0))
            checks))
    ;; 3. live connectivity — GET /api/
    (let ((api-ok nil) (api-msg ""))
      (condition-case err
          (progn
            (netbox--validate-url)
            (let* ((ping-url (concat (string-trim-right netbox-url "/")
                                     netbox-api-prefix "/"))
                   (url-request-method "GET")
                   (url-request-extra-headers
                    `(("Authorization" . ,(concat "Token " (netbox--token)))
                      ("Accept"        . "application/json")))
                   (network-security-level (if netbox-tls-verify 'medium 'low))
                   (url-proxy-services (or (netbox--proxy-services)
                                           url-proxy-services))
                   (resp-buf (url-retrieve-synchronously
                              ping-url t nil netbox-timeout)))
              (if resp-buf
                  (unwind-protect
                      (with-current-buffer resp-buf
                        (goto-char (point-min))
                        (let ((status (url-http-parse-response)))
                          (if (and (>= status 200) (< status 300))
                              (setq api-ok t
                                    api-msg (format "HTTP %d OK" status))
                            (setq api-msg (format "HTTP %d" status)))))
                    (kill-buffer resp-buf))
                (setq api-msg "no response"))))
        (error (setq api-msg (error-message-string err))))
      (push (cons (format "API reachable (%s)" api-msg) api-ok) checks))
    ;; Render report
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "NetBox configuration check\n" 'face 'bold))
        (insert (make-string 50 ?─) "\n\n")
        (insert (propertize "Settings\n" 'face 'bold))
        (insert (make-string 50 ?─) "\n")
        (insert (format "  %-35s %s\n" "netbox-url"
                        (if (and netbox-url (not (string-empty-p netbox-url)))
                            netbox-url "(not set)")))
        (insert (format "  %-35s %s\n" "netbox-token"
                        (cond
                         ((and netbox-token (not (string-empty-p netbox-token))) "(set)")
                         ((and netbox-url (not (string-empty-p netbox-url))
                               (car (auth-source-search
                                     :host (url-host (url-generic-parse-url netbox-url))
                                     :user "apitoken" :max 1)))
                          "(from auth-source)")
                         (t "(not set)"))))
        (insert (format "  %-35s %s\n" "netbox-api-prefix" netbox-api-prefix))
        (insert (format "  %-35s %s\n" "netbox-default-page-size"
                        (number-to-string netbox-default-page-size)))
        (insert (format "  %-35s %s\n" "netbox-tls-verify"
                        (if netbox-tls-verify "t" "nil (disabled)")))
        (insert (format "  %-35s %s\n" "netbox-timeout"
                        (format "%ds" netbox-timeout)))
        (insert (format "  %-35s %s\n" "netbox-proxy"
                        (or netbox-proxy "nil (inherit global)")))
        (insert (format "  %-35s %s\n" "netbox-reuse-window"
                        (if netbox-reuse-window "t (current window)" "nil (new window)")))
        (insert (format "  %-35s %s\n" "netbox-pre-fetch-check"
                        (if netbox-pre-fetch-check "t" "nil (disabled)")))
        (insert (format "  %-35s %s\n" "netbox-connectivity-timeout"
                        (format "%ds" netbox-connectivity-timeout)))
        (insert (format "  %-35s %s\n" "netbox-cache-ttl"
                        (if (zerop netbox-cache-ttl)
                            "0 (disabled)"
                          (format "%ds" netbox-cache-ttl))))
        (insert (format "  %-35s %s\n" "netbox-precache-resources"
                        (if netbox-precache-resources
                            (mapconcat #'identity netbox-precache-resources ", ")
                          "(none)")))
        (insert (format "  %-35s %s\n" "netbox-precache-after-idle"
                        (if netbox-precache-after-idle
                            (format "%ds" netbox-precache-after-idle)
                          "nil (disabled)")))
        (insert (format "  %-35s %s\n\n" "netbox-evil-integration"
                        (if netbox-evil-integration "t" "nil")))
        (insert (propertize "Checks\n" 'face 'bold))
        (insert (make-string 50 ?─) "\n")
        (dolist (c (nreverse checks))
          (let* ((label (car c))
                 (ok    (cdr c))
                 (mark  (if ok
                            (propertize "  ✓ " 'face '(:foreground "green"))
                          (propertize "  ✗ " 'face '(:foreground "red"))))
                 (face  (if ok 'default '(:foreground "red"))))
            (insert mark (propertize label 'face face) "\n")))
        (insert "\n")
        (netbox-config-check-mode)))
    (netbox--display-buffer buf)))


;;;; ──────────────────────────────────────────────────────────
;;;; Jump / completing-read integration

(defun netbox--object-display-string (obj columns)
  "Build a compact display string for OBJ using the first few COLUMNS.
Returns a string of the form \"<col1>  <col2>  …\" using up to three columns,
skipping any empty values.  Used as completion candidates in `netbox-jump'."
  (let ((parts nil))
    (dolist (col (seq-take columns 3))
      (let ((text (apply #'netbox--nested-str obj (cddr col))))
        (unless (string-empty-p text)
          (push text parts))))
    (mapconcat #'identity (nreverse parts) "  ")))

(defun netbox--build-candidates (objects columns)
  "Convert OBJECTS list into an alist of (DISPLAY . OBJ) pairs.
DISPLAY is built via `netbox--object-display-string' using COLUMNS.
Pure function — no side effects, no API calls."
  (mapcar (lambda (obj)
            (cons (netbox--object-display-string obj columns) obj))
          objects))

(defun netbox--jump-open-prompt (resource candidates)
  "Open a `completing-read' prompt for RESOURCE over CANDIDATES.
CANDIDATES is an alist of (DISPLAY . OBJ).  Navigates to the detail view
of the selected object.  Called from within an async fetch callback."
  (let* ((table (lambda (str pred action)
                  (if (eq action 'metadata)
                      '(metadata (category . netbox-object))
                    (complete-with-action action candidates str pred))))
         (choice (completing-read (format "NetBox %s: " resource) table nil t))
         (obj    (cdr (assoc choice candidates)))
         (url    (and obj (cdr (assoc "url" obj))))
         (nav    (and url (netbox--parse-api-url url))))
    (if nav
        (netbox-show-detail (car nav) (cdr nav))
      (user-error "Cannot determine endpoint for selected object"))))

;;;###autoload
(defun netbox-jump (&optional resource)
  "Jump directly to a NetBox object by name using `completing-read'.
Prompts for a RESOURCE type (if not supplied), fetches all objects of that
type asynchronously, then opens a `completing-read' prompt.  The cache is
used on repeat calls so the prompt appears instantly.

Works with any completion framework (Vertico, Consult, Ivy, default).
See also `netbox-precache' to warm the cache ahead of time."
  (interactive
   (list (completing-read "NetBox resource: "
                          (mapcar #'car netbox--resource-alist)
                          nil t)))
  (when (or (null resource) (string-empty-p resource))
    (user-error "No resource selected"))
  (let* ((entry    (cdr (assoc resource netbox--resource-alist)))
         (endpoint (and entry (symbol-value (car entry))))
         (columns  (and entry (symbol-value (cdr entry)))))
    (unless entry
      (user-error "Unknown NetBox resource: %s" resource))
    (message "NetBox: checking connectivity…")
    (netbox--check-connectivity-async
     (lambda ()
       (message "NetBox: fetching %s…" resource)
       (netbox-api-list-async-cached
        endpoint nil
        (lambda (objects err)
          (if err
              (message "NetBox: error fetching %s: %s" resource err)
            (netbox--jump-open-prompt resource
                                      (netbox--build-candidates objects columns))))))
     (lambda (msg)
       (message "NetBox: API unreachable — %s" msg)))))

;;;###autoload
(defun netbox-jump-to-device ()
  "Jump directly to a NetBox Device by name using `completing-read'."
  (interactive)
  (netbox-jump "Devices"))

;;;###autoload
(defun netbox-jump-to-address ()
  "Jump directly to a NetBox IP Address using `completing-read'."
  (interactive)
  (netbox-jump "IP Addresses"))

;;;###autoload
(defun netbox-jump-to-vm ()
  "Jump directly to a NetBox Virtual Machine by name using `completing-read'."
  (interactive)
  (netbox-jump "Virtual Machines"))


;;;; ──────────────────────────────────────────────────────────
;;;; Pre-cache

(defvar netbox--precache-idle-timer nil
  "Timer used for idle-triggered pre-caching, or nil if not scheduled.")

;;;###autoload
(defun netbox-precache ()
  "Pre-fetch `netbox-precache-resources' into the cache in the background.
Each resource is fetched asynchronously; Emacs remains fully responsive.
Call this from your init file (or bind it) to warm the cache so that
`netbox-jump' shows its prompt instantly for common resource types."
  (interactive)
  (if (or (null netbox-url) (string-empty-p netbox-url))
      (when (called-interactively-p 'any)
        (user-error "netbox-url is not configured"))
    (let ((interactive-p (called-interactively-p 'any)))
      (netbox--check-connectivity-async
       (lambda ()
         (dolist (resource netbox-precache-resources)
           (let* ((entry    (cdr (assoc resource netbox--resource-alist)))
                  (endpoint (and entry (symbol-value (car entry)))))
             (when endpoint
               (netbox-api-list-async-cached
                endpoint nil
                (lambda (objects err)
                  (if err
                      (message "NetBox pre-cache: error for %s: %s" resource err)
                    (message "NetBox pre-cache: %d %s cached"
                             (length objects) resource))))))))
       (lambda (msg)
         (when interactive-p
           (message "NetBox pre-cache: API not reachable — %s" msg)))))))

(defun netbox--precache-reschedule ()
  "Cancel any existing idle pre-cache timer and start a new one if appropriate.
Called automatically when `netbox-precache-after-idle' changes."
  (when (timerp netbox--precache-idle-timer)
    (cancel-timer netbox--precache-idle-timer)
    (setq netbox--precache-idle-timer nil))
  (when (and (boundp 'netbox-precache-after-idle)
             netbox-precache-after-idle
             (integerp netbox-precache-after-idle))
    (setq netbox--precache-idle-timer
          (run-with-idle-timer netbox-precache-after-idle t #'netbox-precache))))

(add-variable-watcher
 'netbox-precache-after-idle
 (lambda (_sym _val _op _where)
   (run-at-time 0 nil #'netbox--precache-reschedule)))


;;;; ──────────────────────────────────────────────────────────
;;;; Evil mode integration (optional)

(defun netbox-evil-setup ()
  "Configure evil keybindings for netbox modes.
This is called automatically when evil is loaded and
`netbox-evil-integration' is non-nil.  To call it manually instead:

  (setq netbox-evil-integration nil)
  (with-eval-after-load \\='evil
    (netbox-evil-setup))"
  (evil-set-initial-state 'netbox-list-mode         'normal)
  (evil-set-initial-state 'netbox-detail-mode       'normal)
  (evil-set-initial-state 'netbox-super-search-mode 'normal)
  (evil-set-initial-state 'netbox-config-check-mode 'normal)
  (netbox--evil-define-key 'normal netbox-list-mode-map
    (kbd "RET") #'netbox-list-open-detail
    (kbd "g r") #'netbox-list-refresh
    (kbd "o")   #'netbox-list-open-url
    (kbd "q")   #'netbox-quit
    (kbd "/")   #'netbox-list-search
    (kbd "F")   #'netbox-list-edit-filter
    (kbd "?")   #'netbox-help)
  (netbox--evil-define-key 'normal netbox-super-search-mode-map
    (kbd "RET") #'netbox--super-search-open-detail
    (kbd "g r") #'netbox-super-search-refresh
    (kbd "o")   #'netbox--super-search-open-browser-url
    (kbd "q")   #'netbox-quit
    (kbd "/")   #'netbox-super-search-requery
    (kbd "F")   #'netbox-super-search-edit-query
    (kbd "?")   #'netbox-help)
  (netbox--evil-define-key 'normal netbox-detail-mode-map
    (kbd "g r")       #'netbox-detail-refresh
    (kbd "o")         #'netbox-detail-open-url
    (kbd "q")         #'netbox-quit
    (kbd "y")         #'netbox-detail-yank-value
    (kbd "?")         #'netbox-help
    (kbd "TAB")       #'netbox-detail-next-button
    (kbd "<tab>")     #'netbox-detail-next-button
    (kbd "<backtab>") #'netbox-detail-prev-button
    (kbd "S-TAB")     #'netbox-detail-prev-button)
  (netbox--evil-define-key 'normal netbox-config-check-mode-map
    (kbd "q")   #'netbox-quit)
  ;; Remove the regular define-key bindings to avoid conflicts
  ;; since evil-define-key above now handles all states
  (evil-normalize-keymaps))

(defun netbox--maybe-setup-evil ()
  "Configure Evil integration when it is enabled and Evil is available."
  (when (and netbox-evil-integration
             (featurep 'evil)
             (bound-and-true-p evil-mode))
    (netbox-evil-setup)))

(add-hook 'evil-mode-hook #'netbox--maybe-setup-evil)
(netbox--maybe-setup-evil)

(add-variable-watcher
 'netbox-evil-integration
 (lambda (_sym value operation _where)
   (when (and (eq operation 'set) value (featurep 'evil))
     (netbox-evil-setup))))


;;;; ──────────────────────────────────────────────────────────

(provide 'netbox)
;;; netbox.el ends here
