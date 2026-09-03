# netbox.el

> Browse, search and navigate your [NetBox](https://netbox.dev/) instance
> directly from Emacs — no external packages required.

**Requires Emacs 28.1+** · Only built-in libraries (`url.el`, `json.el`,
`tabulated-list-mode`, `auth-source`) · GPL-3.0-or-later


### This Package was created by using AI! 
---

## Features

- 📋 **Tabulated list views** for every major NetBox resource type
- 🔍 **Full-text search** across any resource via the `?q=` API parameter
- 🔎 **Super search** — query ALL resource types at once from a single prompt
- 🎨 **Status colour-coding** — Active/Connected in green, Planned in yellow,
  Failed/Decommissioned in red, and more
- 📐 **Auto-sized columns** — column widths expand to fit the widest value
- 🔗 **Cross-resource navigation** — related objects in detail buffers are
  rendered as clickable links; press `RET` or click to jump straight to them
- 🌐 **Open in browser** — press `o` to open any object's NetBox URL directly in your default browser
- 🔎 **Live filter indicator** — active `?q=` filter shown in the mode-line;
  press `F` to edit the current filter without retyping
- ⚡ **Response caching** — configurable TTL (default 5 min) eliminates
  redundant API round-trips; `g r` always fetches live data
- 🔒 **Secure token storage** via `auth-source` / `~/.authinfo.gpg`
- 🛡️ **Optional pre-fetch connectivity check** for fast, clear error messages
- 🌍 **Per-request proxy support** — never touches global Emacs proxy state
- 😈 **Evil mode integration** — opt-in normal-state bindings via `netbox-evil-integration`

---

## Installation

### `straight.el` + `use-package`

```elisp
(use-package netbox
  :straight (:host github :repo "sraupach/netbox.el")
  :config
  (setq netbox-url   "https://netbox.example.com"
        netbox-token "your-api-token-here"))
```

### Manually

```elisp
(add-to-list 'load-path "/path/to/netbox.el")
(require 'netbox)
```

---

## Quick start

```
M-x netbox
```

Opens a `completing-read` prompt — pick a resource type and you're in.
Use `C-u M-x netbox` to pre-filter with a search query.

```
M-x netbox-super-search
```

Searches ALL resource types at once — results are merged into a single list
showing Type, Name, Description, and URL.

```
M-x netbox-jump
```

Fetches all objects of a chosen resource type and presents them in a
`completing-read` prompt — pick any object by name and jump straight to its
detail view.  Works with any completion framework (Vertico, Consult, Ivy, or
the built-in default).  Typed shortcuts: `netbox-jump-to-device`,
`netbox-jump-to-address`, `netbox-jump-to-vm`.

```
M-x netbox-check-config
```

Validates your configuration and tests live connectivity before you dig in.

---

## Usage

### Direct resource commands

| Command                         | Resource                      |
|---------------------------------|-------------------------------|
| `M-x netbox-dcim-sites`         | DCIM → Sites                  |
| `M-x netbox-dcim-racks`         | DCIM → Racks                  |
| `M-x netbox-dcim-devices`       | DCIM → Devices                |
| `M-x netbox-dcim-interfaces`    | DCIM → Interfaces             |
| `M-x netbox-dcim-cables`        | DCIM → Cables                 |
| `M-x netbox-dcim-locations`     | DCIM → Locations              |
| `M-x netbox-ipam-prefixes`      | IPAM → Prefixes               |
| `M-x netbox-ipam-addresses`     | IPAM → IP Addresses           |
| `M-x netbox-ipam-vlans`         | IPAM → VLANs                  |
| `M-x netbox-ipam-vrfs`          | IPAM → VRFs                   |
| `M-x netbox-ipam-ranges`        | IPAM → IP Ranges              |
| `M-x netbox-virt-clusters`      | Virtualization → Clusters     |
| `M-x netbox-virt-vms`           | Virtualization → VMs          |
| `M-x netbox-virt-interfaces`    | Virtualization → VM Interfaces|
| `M-x netbox-circuits`           | Circuits                      |
| `M-x netbox-circuits-providers` | Circuit Providers             |
| `M-x netbox-tenancy-tenants`    | Tenancy → Tenants             |
| `M-x netbox-tenancy-contacts`   | Tenancy → Contacts            |
| `M-x netbox-super-search`      | Search ALL types at once       |
| `M-x netbox-search`            | Search a specific resource     |
| `M-x netbox-jump`              | Jump to any object by name     |
| `M-x netbox-jump-to-device`    | Jump directly to a Device      |
| `M-x netbox-jump-to-address`   | Jump directly to an IP Address |
| `M-x netbox-jump-to-vm`        | Jump directly to a VM          |

### Key bindings — list buffers

| Key   | Action                                  |
|-------|-----------------------------------------|
| `RET` | Open detail view for the selected row   |
| `g r` | Refresh from API (bypasses cache)       |
| `o`   | Open object's URL in default browser    |
| `/`   | Set a new filter query (uses `?q=`)     |
| `F`   | Edit the current filter (pre-filled)    |
| `q`   | Close buffer                            |
| `?`   | Show key binding help                   |

### Key bindings — detail buffers

| Key         | Action                                      |
|-------------|---------------------------------------------|
| `RET`       | Follow link to a related object             |
| `g r`       | Reload from API                             |
| `o`         | Open object's URL in default browser        |
| `y`         | Copy field value at point to kill ring      |
| `TAB`       | Move to next link                           |
| `S-TAB`     | Move to previous link                       |
| `q`         | Close buffer                                |
| `?`         | Show key binding help                       |

### Key bindings — super search buffer

| Key   | Action                                      |
|-------|---------------------------------------------|
| `RET` | Open detail view for the selected result    |
| `g r` | Re-run the current search                   |
| `o`   | Open object's URL in default browser        |
| `/`   | Run a new search query                      |
| `F`   | Edit the current query (pre-filled)         |
| `q`   | Close buffer                                |
| `?`   | Show key binding help                       |

> **Tip:** In a detail buffer, any related object (Site, Device, Tenant, …)
> that NetBox returns with a URL is rendered as a clickable link.
> Press `RET` on it or click with the mouse to navigate directly to that
> object's own detail view.

### Opening objects in the browser

Press `o` in either list or detail buffers to open the NetBox URL for any object
in your default web browser. This is useful for:

- Viewing the full object page in NetBox with all related data, tags, and custom fields
- Inspecting or editing objects that require browser-based interaction
- Switching context between the Emacs CLI and the web interface

In list and detail buffers, `o` works instantly without another API call. The
web UI URL is derived from the configured endpoint and the selected object ID.

---

## Configuration

All settings live under the `netbox` customization group
(`M-x customize-group RET netbox`).

| Variable                      | Default  | Description                                                    |
|-------------------------------|----------|----------------------------------------------------------------|
| `netbox-url`                  | `""`     | Base URL of your NetBox instance (no trailing slash)           |
| `netbox-token`                | `""`     | API token — leave empty to use `auth-source` (see below)       |
| `netbox-api-prefix`           | `"/api"` | API path prefix (change for reverse-proxy installs)            |
| `netbox-default-page-size`    | `50`     | Results per page for paginated fetches                         |
| `netbox-tls-verify`           | `t`      | Set to `nil` to skip TLS certificate verification              |
| `netbox-timeout`              | `30`     | Request timeout in seconds for data fetches                    |
| `netbox-proxy`                | `nil`    | Proxy URL, `"direct"`, or `nil` to inherit global proxy        |
| `netbox-reuse-window`         | `t`      | `t` = current window · `nil` = new window                      |
| `netbox-pre-fetch-check`      | `nil`    | Optionally ping NetBox before each fetch for fast error reporting |
| `netbox-connectivity-timeout` | `5`      | Timeout in seconds for the pre-fetch ping                      |
| `netbox-cache-ttl`            | `300`    | Seconds to cache list responses · `0` disables caching         |
| `netbox-precache-resources`   | `'("Devices" "IP Addresses" "Virtual Machines")` | Resources to pre-fetch for `netbox-jump` |
| `netbox-precache-after-idle`  | `nil`    | Idle seconds before auto-pre-caching; `nil` disables           |
| `netbox-super-search-concurrency` | `4` | Maximum simultaneous super-search requests                     |
| `netbox-super-search-limit`   | `50`     | Maximum results requested from each resource                   |
| `netbox-evil-integration`     | `nil`    | Set to `t` to auto-configure evil keybindings when evil is loaded |

### Example configuration

```elisp
(use-package netbox
  :straight (:host github :repo "sraupach/netbox.el")
  :config
  (setq netbox-url   "https://netbox.example.com"
        netbox-token "your-api-token-here"  ; or use ~/.authinfo (see below)

        ;; Open each NetBox buffer beside the current window
        netbox-reuse-window nil

        ;; Cache responses for 10 minutes
        netbox-cache-ttl 600

        ;; Fetch more rows per page
        netbox-default-page-size 100

        ;; Route API traffic through a proxy (optional)
        ;; netbox-proxy "http://proxy.corp:8080"

        ;; Skip TLS verification for self-signed certs (not recommended)
        ;; netbox-tls-verify nil
        ))
```

### Storing your token with auth-source *(recommended)*

Keep your token out of `init.el` by adding an entry to `~/.authinfo`
(or `~/.authinfo.gpg` for GPG-encrypted storage):

```
machine netbox.example.com login apitoken password <your-token>
```

Then only set `netbox-url` — the token is looked up automatically.

### Response caching

`netbox-cache-ttl` controls how long list responses are cached in memory:

| Value        | Behaviour                                      |
|--------------|------------------------------------------------|
| `300` (default) | Cache each endpoint+query for 5 minutes     |
| `0`          | Disable caching entirely                       |
| any integer  | Cache for that many seconds                    |

`g r` in a list buffer **always** bypasses the cache and fetches live data.
`M-x netbox-cache-clear` flushes the entire in-memory cache immediately.

### Pre-caching for instant `netbox-jump`

`netbox-jump` fetches objects asynchronously — Emacs stays responsive, but there
is a short delay on the **first** call while the data loads.  Pre-caching
eliminates that delay.

**On-demand:** call `M-x netbox-precache` at any time to warm the cache for
the resources listed in `netbox-precache-resources` (background, non-blocking).

**Automatic on idle:** set `netbox-precache-after-idle` to a number of idle
seconds and the pre-cache runs whenever Emacs has been idle that long:

```elisp
;; Pre-cache Devices, IP Addresses and VMs after 10 s of idle time
(setq netbox-precache-after-idle 10)

;; Customise which resources are pre-cached
(setq netbox-precache-resources '("Devices" "IP Addresses" "Prefixes"))
```

### Window display behaviour

| `netbox-reuse-window` | Behaviour                                      |
|-----------------------|------------------------------------------------|
| `t` (default)         | Replace the current window (`switch-to-buffer`) |
| `nil`                 | Open in a new window (`switch-to-buffer-other-window`) |

### Pre-fetch connectivity check

When `netbox-pre-fetch-check` is `t`, a quick ping to
`<netbox-url>/api/` is made before every data fetch using
`netbox-connectivity-timeout` as the deadline.  Unreachable instances
are reported immediately with a `g r` retry hint rather than silently
hanging for the full `netbox-timeout`.  It defaults to `nil` because enabling
it adds an extra network round trip to every operation.

```elisp
;; Enable on unreliable networks for a short preflight timeout
(setq netbox-pre-fetch-check t)
```

### Proxy configuration

`netbox-proxy` applies **only** to NetBox requests and never alters the
global `url-proxy-services` value.

| Value                     | Behaviour                                           |
|---------------------------|-----------------------------------------------------|
| `nil` (default)           | Inherit Emacs' global proxy (or go direct)          |
| `"direct"`                | Force a direct connection, bypassing any global proxy |
| `"http://host:port"`      | Route all NetBox requests through this proxy        |

```elisp
(setq netbox-proxy "http://proxy.corp:8080")
(setq netbox-proxy "http://user:password@proxy.corp:8080")
(setq netbox-proxy "direct")
```

### Overriding individual endpoint paths

Each API endpoint is a `defvar` you can override for non-standard installs:

```elisp
(setq netbox-endpoint-dcim-devices "/custom-prefix/api/dcim/devices/")
```

Available endpoint variables:

- `netbox-endpoint-dcim-sites`, `-racks`, `-devices`, `-interfaces`, `-cables`, `-locations`
- `netbox-endpoint-ipam-prefixes`, `-addresses`, `-vlans`, `-vrfs`, `-ranges`
- `netbox-endpoint-virt-clusters`, `-vms`, `-interfaces`
- `netbox-endpoint-circuits-circuits`, `-providers`
- `netbox-endpoint-tenancy-tenants`, `-contacts`

---

## Customizing columns

Each resource has a `defvar` controlling which columns appear in its list view:

```elisp
(setq netbox-columns-dcim-devices
      '(("Name"       30 "name")
        ("Site"       20 "site" "name")
        ("Primary IP" 20 "primary_ip" "address")))
```

Each entry is `(HEADER WIDTH KEY...)` where `KEY...` is the path into the
JSON object.  The `WIDTH` value is a **minimum** — columns automatically
expand to fit the widest value after data loads.  Any column with the header
`"Status"` automatically receives semantic colour-coding.

---

## Evil mode integration

Evil normal-state keybindings are **not** active by default. Set
`netbox-evil-integration` to `t` **before** loading netbox.el to enable them:

```elisp
(setq netbox-evil-integration t)
(require 'netbox)
```

Or with `use-package`:

```elisp
(use-package netbox
  :init
  (setq netbox-evil-integration t)
  :config
  (setq netbox-url "https://netbox.example.com"
        netbox-token "your-api-token-here"))
```

To **apply the setup manually** without the variable:

```elisp
(with-eval-after-load 'evil
  (netbox-evil-setup))
```

---

## License

GPL-3.0-or-later
