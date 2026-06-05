# PowerPost

A lightweight, single-folder **Postman replacement** for Windows, written in Windows
PowerShell 5.1 + WinForms. No account, no cloud, no telemetry — just a GUI for hitting
your own internal APIs.

## Features

- **Tabs** — each tab is a saved request (method, URL, params, headers, body). Rename by
  double-clicking the tab header or right-click → Rename; Duplicate and Close from the
  toolbar or right-click menu.
- **Methods** — GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS.
- **Params / Headers** — enable/disable individual rows; params are merged into the query
  string at send time.
- **Body** — `No body`, `JSON`, `Text`, or `Form URL-encoded` (sets the right
  `Content-Type` automatically).
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

## Running it

Double-click `Run-PowerPost.cmd`, **or** from a terminal:

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\PowerPost.ps1
```

(The script auto-relaunches itself under `-STA` if needed — STA is required for WinForms.)

### Keyboard shortcuts
| Shortcut | Action |
| --- | --- |
| `Ctrl+Enter` / `F5` | Send the current request |
| `Ctrl+T` | New tab |
| `Ctrl+W` | Close tab |
| `Ctrl+S` | Save state |

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

## Layout

```
PowerPost.ps1        entry point: STA guard, TLS/cert setup, loads lib\, self-test, launch
Run-PowerPost.cmd    double-click launcher
lib\Model.ps1        data model + JSON normalization
lib\State.ps1        load/save powerpost.state.json
lib\Json.ps1         JSON pretty-printer
lib\Http.ps1         request execution via HttpClient
lib\Auth.ps1         auth headers + OAuth2 token acquisition (client-creds, auth-code+PKCE)
lib\Ui.Controls.ps1  reusable WinForms builders (grids, fields, auth panel)
lib\Ui.Tab.ps1       per-tab editor + response panel + model<->controls sync
lib\Ui.Send.ps1      send, render response, fetch tokens, save response
lib\Ui.Main.ps1      main window, toolbar, tab management, save/close
```
