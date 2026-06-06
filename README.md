# MCS PowerPost

> A lightweight, single-folder **Postman replacement** for Windows — no account, no cloud, no telemetry.

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![UI](https://img.shields.io/badge/UI-WinForms-512BD4)
![License](https://img.shields.io/badge/license-proprietary-lightgrey)

**MCS PowerPost** is a tabbed API tester written in Windows PowerShell 5.1 + WinForms. It's a
single folder of scripts — nothing to install, no dependencies to restore — just a GUI for
hitting your own internal APIs. A [Major Computing Systems](https://majorcomputingsystems.ca)
product.

<!-- Add a screenshot at docs/screenshot.png to show it here -->
![MCS PowerPost](docs/screenshot.png)

## Table of contents

- [Features](#features)
- [Getting started](#getting-started)
- [Usage](#usage)
  - [Keyboard shortcuts](#keyboard-shortcuts)
  - [Collections](#collections)
  - [Environments](#environments)
  - [Import & export](#import--export)
- [OAuth notes](#oauth-notes)
- [Security](#security)
- [Validate the build](#validate-the-build)
- [Project layout](#project-layout)
- [Roadmap](#roadmap)
- [License](#license)
- [About](#about)

## Features

- **Tabs** — each tab is an open request (method, URL, params, headers, body). Rename by
  double-clicking the tab header or right-click → Rename; Duplicate and Close from the
  toolbar or right-click menu.
- **Collections** — a left sidebar tree of saved requests grouped into collections. Save the
  current tab into a collection, double-click a saved request to open it in a new tab, and
  right-click to rename, duplicate, or delete. See [Collections](#collections).
- **Methods** — GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS.
- **File uploads** — the `Multipart form-data` body lets you mix text fields and files; pick a
  file per row with the **...** button. Sent as `multipart/form-data` via `HttpClient`.
- **cURL import / export** — paste a cURL command (toolbar **Import cURL**) to build a request in
  a new tab, or right-click a tab → **Copy as cURL** / **Copy as PowerShell** to copy a runnable
  snippet of the current request. See [Import & export](#import--export).
- **Environments & variables** — define named environments of `{{variable}}` values and switch
  between them from the toolbar. Tokens like `{{baseUrl}}` / `{{token}}` are substituted into the
  URL, params, headers, body, form fields, and auth at send time (the `Request` preview shows the
  resolved values). See [Environments](#environments).
- **Params / Headers** — enable/disable individual rows; params are merged into the query
  string at send time.
- **Body** — `No body`, `JSON`, `Text`, `Form URL-encoded`, or `Multipart form-data`
  (text **and file** fields, for uploads) — the right `Content-Type` is set automatically.
- **Auth**
  - **None**
  - **Bearer / JWT** — paste a token, sent as `Authorization: Bearer <token>`.
  - **Basic** — username/password → Basic header.
  - **OAuth2 Client Credentials** — token URL, client id/secret, scope; credentials sent
    in the body or as a Basic header. `Get Token` fetches one; tokens are cached with
    their expiry and auto-refreshed on Send.
  - **OAuth2 Authorization Code (+ PKCE)** — opens your browser to sign in, captures the
    redirect on `http://localhost:<port>/`, and exchanges the code for a token.
- **Response** — status code + reason, elapsed time and size; pretty-printed JSON body,
  raw body, and a response-headers grid; Copy and Save-to-file.
- **Request preview** — a `Request` tab in the response panel shows the *exact* request
  that went on the wire after each Send (final URL with params merged, every header
  including the resolved auth header, and the body), so you can tell at a glance whether a
  failure is your request or the server.
- **Self-signed certs** — toolbar `Ignore SSL errors` checkbox for internal HTTPS.
- **State** — saved to `powerpost.state.json` **next to the script**, on `Save` (Ctrl+S)
  and automatically when you close the window. Reopens exactly where you left off.

## Getting started

**Requirements:** Windows with the in-box Windows PowerShell 5.1 (not PowerShell 7+).

1. Clone or download this repository.
2. Launch it:
   - Double-click **`Run-PowerPost.cmd`**, **or**
   - From a terminal:
     ```powershell
     powershell -STA -ExecutionPolicy Bypass -File .\PowerPost.ps1
     ```

   The script auto-relaunches itself under `-STA` if needed — STA is required for WinForms.

## Usage

Open a tab, choose a method, type a URL, fill in params/headers/body/auth as needed, and hit
**Send**. The response panel shows the status, timing, size, a pretty-printed body, the raw
body, response headers, and the exact request that was sent.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Enter` / `F5` | Send the current request |
| `Ctrl+T` | New tab |
| `Ctrl+W` | Close tab |
| `Ctrl+S` | Save state |

### Collections

Tabs are your working set; **collections** are your saved library. Use the sidebar on the left:

1. Click **+ Collection** (or right-click → New Collection) and name it.
2. With a collection (or one of its requests) selected, click **Save Request** to store a
   snapshot of the current tab into it — or right-click a collection → **Add Current Request Here**.
3. **Double-click** a saved request to open it in a new tab. It opens as a *copy*, so editing the
   tab doesn't change the saved request until you save again.
4. Right-click any node to **Rename**, **Duplicate** (requests), or **Delete**.

Collections are saved in `powerpost.state.json` alongside your open tabs, so your library persists
between sessions. Saved requests use the same format as tabs, so everything — params, headers,
body, auth, and `{{variables}}` — is preserved.

### Environments

Use environments to avoid hard-coding hosts, tokens, and other values that change between (say)
local, staging, and production.

1. Click **Environments** in the toolbar to open the manager.
2. **Add** an environment, give it a name, and fill the variable grid with `key` / `value` rows
   (disable a row to leave it out without deleting it).
3. Click **OK**, then pick the environment from the toolbar dropdown (or **No Environment** to
   send literal values).

Anywhere in a request you can then write `{{key}}` and it is replaced at send time — in the URL,
params, headers, body, form fields, and the auth fields (bearer token, basic creds, OAuth URLs/
client id/secret/scope). Inner spaces are tolerated, so `{{ key }}` works too. Unknown or disabled
variables are left untouched (e.g. `{{missing}}` is sent as-is) so you can spot mistakes. The
`Request` tab in the response panel always shows the fully-resolved request that went on the wire.

Environments and the active selection are saved in `powerpost.state.json` along with everything
else. **Note:** variable values are stored in plaintext — see [Security](#security).

### Import & export

- **Import cURL** (toolbar) — paste a cURL command and PowerPost parses it into a new tab:
  method, URL, headers, body (JSON / form / text, or `-F` → multipart with file fields), and
  `-u` or `Authorization: Bearer`/`Basic` headers become the request's auth. Common no-op flags
  (`-k`, `-L`, `-s`, …) are ignored.
- **Copy as cURL** / **Copy as PowerShell** (right-click a tab) — copies the current request to
  the clipboard as a bash-style `curl` command or an `Invoke-RestMethod` script. `{{variables}}`
  are resolved against the active environment first, so the snippet is runnable as-is. (For OAuth
  auth, the snippet includes a token only if one has already been fetched. Multipart/file bodies
  export to `curl -F`; the PowerShell snippet notes them rather than inlining file uploads.)

## OAuth notes

- **Authorization Code:** the redirect URI is `http://localhost:<Redirect Port>/` (default
  `8080`). That exact URI must be registered as an allowed redirect/callback in your
  identity provider's app/client config, or sign-in will fail. Leave **Use PKCE** on for
  public clients; add a Client Secret for confidential clients.
- **Client Credentials:** choose whether the client id/secret go in the request body or as
  a `Basic` auth header (`Credentials in` dropdown) to match what your token endpoint
  expects.

## Security

Secrets (bearer tokens, client secrets, passwords) and fetched OAuth tokens are saved in
**plaintext** in `powerpost.state.json`. This is intended for development credentials
against internal APIs. The file is git-ignored by default — don't commit it, and don't
store production secrets in it.

## Validate the build

```powershell
powershell -File .\PowerPost.ps1 -SelfTest
```

Runs quick local checks (state round-trip, JSON formatter, PKCE S256 vector, and a live
GET/POST against postman-echo.com) and prints PASS/FAIL per check.

## Project layout

```
PowerPost.ps1        entry point: STA guard, TLS/cert setup, loads lib\, self-test, launch
Run-PowerPost.cmd    double-click launcher
lib\Model.ps1        data model + JSON normalization
lib\State.ps1        load/save powerpost.state.json
lib\Json.ps1         JSON pretty-printer
lib\Http.ps1         request execution via HttpClient
lib\Auth.ps1         auth headers + OAuth2 token acquisition (client-creds, auth-code+PKCE)
lib\Vars.ps1         {{variable}} substitution (environments)
lib\Curl.ps1         cURL import + cURL/PowerShell export
lib\Ui.Controls.ps1  reusable WinForms builders (grids, fields, auth panel)
lib\Ui.Env.ps1       environment selector + manager dialog
lib\Ui.Collections.ps1  collections sidebar (tree of saved requests) + commands
lib\Ui.Code.ps1      cURL import dialog + copy-as-cURL/PowerShell commands
lib\Ui.Tab.ps1       per-tab editor + response panel + model<->controls sync
lib\Ui.Send.ps1      send, render response, fetch tokens, save response
lib\Ui.Main.ps1      main window, toolbar, tab management, save/close, About
```

## Roadmap

Planned features to bring MCS PowerPost closer to Postman, roughly in priority order:

- ~~**Environments & variables**~~ — ✅ shipped: `{{baseUrl}}` / `{{token}}` substitution with
  switchable environments.
- ~~**Collections**~~ — ✅ shipped: a saved-request sidebar tree alongside the tabs.
- ~~**cURL import / export**~~ — ✅ shipped: paste cURL to build a request; copy as cURL or PowerShell.
- ~~**multipart/form-data**~~ — ✅ shipped: text + file-upload request bodies.
- **Request history** — recent sends with one-click reload.
- **Response search** — find within large response bodies.
- **Settings UI** — timeout, follow-redirects, and proxy controls.
- Later: cookie jar, pre-request/post-response tests, OpenAPI/Postman-collection import,
  saved response examples, GraphQL bodies.

## License

Proprietary — Copyright © Major Computing Systems. No `LICENSE` file is included yet; add one
to set explicit usage terms.

## About

**MCS PowerPost** is built and maintained by **Major Computing Systems** —
[majorcomputingsystems.ca](https://majorcomputingsystems.ca).
