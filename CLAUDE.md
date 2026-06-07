# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PowerPost is a single-folder, dependency-free Postman replacement for Windows, written in
**Windows PowerShell 5.1 + WinForms**. There is no build step, no package manager, no .NET
project — the app is the `.ps1` files, loaded and run in place. Target runtime is the
in-box `powershell.exe` (5.1), *not* PowerShell 7+ (WinForms support and behavior differ).

## Commands

Run the GUI:
```powershell
powershell -STA -ExecutionPolicy Bypass -File .\PowerPost.ps1
```
`PowerPost.ps1` auto-relaunches itself under `-STA` if not already (STA is mandatory for
WinForms). `Run-PowerPost.cmd` is the double-click launcher (hidden console).

Validate the build (this is the test suite — there is no separate test runner):
```powershell
powershell -File .\PowerPost.ps1 -SelfTest
```
`-SelfTest` runs non-GUI checks (state round-trip, JSON formatter, RFC 7636 PKCE S256
vector, live GET/POST against postman-echo.com), prints PASS/FAIL per check, and
`exit 1` on any failure. **Run this after any change to the lib files.** Note it hits the
network for the HTTP checks; those report FAIL if offline.

GUI smoke test (renders the window, then auto-closes after ~1.2s):
```powershell
$env:PP_SMOKE = '1'; powershell -STA -File .\PowerPost.ps1
```
The auto-close hook lives in `Start-PowerPost`'s `Add_Shown` handler.

## Architecture

`PowerPost.ps1` is the entry point: STA guard → TLS1.2 + cert-policy setup → dot-sources
`lib\*.ps1` in dependency order → either `-SelfTest` or `Start-PowerPost`. In `-SelfTest`
mode only the non-UI libs load (`Model, Json, State, Http, Auth, Vars, Curl, Llm`); GUI libs
are skipped, so keep those free of WinForms dependencies.

Layered, leaf-first load order (`PowerPost.ps1`):
`Model → Json → State → Http → Auth → Vars → Curl → Llm` then
`Ui.Controls → Ui.Env → Ui.Collections → Ui.Code → Ui.Llm → Ui.Tab → Ui.Send → Ui.Main`.
Dependencies only point downward; don't introduce upward calls. `Vars.ps1` holds the
UI-free `{{variable}}` substitution (`Expand-PPVars`, `Get-PPVarMap`, `Expand-PPKvList`,
`Expand-PPAuth`); `Curl.ps1` holds UI-free cURL import/export; `Llm.ps1` holds the UI-free LLM
adapters + Vertex JWT; `Ui.Env.ps1` is the environment selector + manager dialog;
`Ui.Collections.ps1` is the saved-request sidebar; `Ui.Code.ps1` is the cURL import dialog +
copy-as commands; `Ui.Llm.ps1` is the LLM Playground window; `Ui.Tools.ps1` is the Settings dialog
+ Request history viewer.

Key design points to preserve:

- **State is plain hashtables/arrays, never typed objects** (`Model.ps1`), so it serializes
  cleanly via `ConvertTo-Json`. `ConvertFrom-Json` returns `PSCustomObject`, so all loaded
  state is run back through `Resolve-PP*` normalizers that rebuild hashtables and apply
  defaults via `Get-PPProp`. When you add a field: add it to the `New-PP*` factory **and**
  its `Resolve-PP*` normalizer, or it won't survive a save/load cycle.

- **The `$ctx` per-tab object** (`Ui.Tab.ps1`) is the hub: it holds the tab's `model`
  hashtable plus references to every WinForms control on that tab. `Set-PPControlsFromModel`
  pushes model→UI; `Sync-PPTabToModel` pulls UI→model. Always `Sync-PPTabToModel` before
  reading a tab's model (send, save, duplicate all do this).

- **Closure safety:** WinForms event handlers can't capture `$ctx` reliably, so each control
  stores its ctx in `control.Tag` and handlers read `$this.Tag`. Follow this pattern for new
  handlers.

- **HTTP goes through `System.Net.Http.HttpClient`** (`Http.ps1`), not `Invoke-WebRequest`,
  specifically because HttpClient returns 4xx/5xx as normal responses instead of throwing —
  an API tester must show error responses. `Invoke-PPRequest` returns a result hashtable with
  `ok`/`error` rather than throwing; callers branch on `.ok`. Content-type headers must be set
  on the content object, not the request (see the `^Content-` handling).

- **Bulk edit** (`Ui.Controls.ps1` + `Model.ps1`): Params/Headers use `New-PPKvEditor` (grid + a
  "Bulk edit" toggle that swaps to a `key: value`-per-line textbox; `//` = disabled). `Get-PPKvEditorRows`
  reads whichever view is active; `ConvertTo-PPKvText`/`ConvertFrom-PPKvText` (in `Model.ps1`, unit-tested)
  do the text↔rows conversion. Ui.Tab routes Set/Sync through the editor.

- **Body types** (`bodyType`): `none|json|text|form|multipart|graphql`. `graphql` stores the query
  in `body` and JSON variables in `graphqlVars`; `ConvertTo-PPGraphQLBody` (`Http.ps1`) builds
  `{"query":…,"variables":…}` (reused by the request preview and cURL export) and is sent as
  `application/json`. The Body tab's GraphQL card has a query box + a variables box. `form`/`multipart` use row lists
  (`form` = `New-PPKv`; `multipart` = `New-PPMultipartRow` with `kind=text|file`, `value` holding
  the text or file path). `Http.ps1` builds `multipart/form-data` via `MultipartFormDataContent`
  (`ByteArrayContent` for files, read at send time — a missing file `throw`s and surfaces as the
  request error). The Body tab swaps `bodyBox`/`formGrid`/`multipartGrid` in `Update-PPBodyCard`;
  the multipart grid (`New-PPMultipartGrid`) has a Type combo + a `...` file-picker button. cURL
  import maps `-F` to multipart rows; export emits `curl -F` (PowerShell export only notes them).

- **Cert validation is a compiled C# class** (`PPCertPolicy` in `PowerPost.ps1`), not a
  PowerShell scriptblock: the callback fires on a background thread with no runspace where a
  scriptblock would throw and break every HTTPS request. The "Ignore SSL errors" toggle flips
  `[PPCertPolicy]::IgnoreErrors`. Don't replace this with a scriptblock callback.

- **Collection-level auth** (`Model.ps1` + `Ui.Collections.ps1`): a collection has its own `auth`;
  a request's auth type can be `inherit`. `Open-PPRequestCmd` calls `Resolve-PPInheritedAuth` to copy
  the collection's auth into the opened tab (resolved at open — tabs are detached copies). The auth
  panel's load/save logic is `Set-PPAuthRefs`/`Set-PPAuthModel` (`Ui.Controls.ps1`), reused by both
  request tabs and the `Show-PPCollectionAuthCmd` dialog. Standalone `inherit` sends no auth.

- **Auth** (`Auth.ps1`): `Resolve-PPAuthHeaders` produces the outgoing `Authorization`
  header and auto-fetches/refreshes client-credentials tokens when missing/expired. Tokens
  are cached on the auth model with a computed `tokenExpiry` (expires_in minus 30s skew).
  OAuth auth-code flow uses a local `HttpListener` on `http://localhost:<port>/` to catch the
  redirect; that exact URI must be registered with the IdP.

- **Environment variables** (`Vars.ps1` + `Ui.Env.ps1`): `{{name}}` tokens are expanded at
  **send time** in `Invoke-PPSend` (and `Invoke-PPGetToken`) against the active environment's
  map. Expansion runs on *copies* (`Expand-PPKvList`/`Expand-PPAuth`) so the saved model keeps
  the literal `{{...}}` text; a freshly fetched OAuth token is copied back from the expanded
  auth clone onto `$Ctx.model.auth`. The manager dialog edits a deep copy and only commits to
  `state.environments` on OK. Keep substitution UI-free (in `Vars.ps1`) so `-SelfTest` covers it.

- **Collections** (`Ui.Collections.ps1`): a left sidebar `TreeView` of `state.collections`
  (each = `@{ name; requests = @() }`, where a request is a `New-PPTab`-shaped model). Tabs are
  the editing surface; collections are the saved library. `Build-PPTree` rebuilds the whole tree
  from state after every mutation (collections are small — simpler than node/model sync). Tree
  nodes carry a `Tag = @{ kind; col; req }` referencing the actual state hashtables, so renames
  mutate in place and deletes filter by `[object]::ReferenceEquals`. Saving/opening uses
  `Copy-PPTab` (deep copy) so the open tab and the saved request stay independent. Like the env
  manager, all handlers read `$Global:PPApp` (e.g. `$Global:PPApp.tree.SelectedNode`) rather than
  captured locals. `Build-PPStateFromUi` leaves `collections`/`environments`/`activeEnv` untouched,
  so they persist across the autosave-on-close.

- **Collection import** (`Import.ps1` + `Ui.Tools.ps1`): `ConvertFrom-PPApiSpec` sniffs the JSON
  (`openapi`/`swagger` → OpenAPI; `info`+`item` → Postman) and returns a `New-PPCollection`.
  OpenAPI builds requests from `paths`×methods (base URL from `servers`/`host+basePath`, query/header
  params as disabled rows, JSON body from a depth-limited `$ref`-resolving schema example); Postman
  flattens nested `item` folders and maps raw/urlencoded/formdata bodies + bearer/basic auth.
  `Show-PPImportCollection` appends the result to `state.collections` and calls `Build-PPTree`. UI-free
  so `-SelfTest` covers it.

- **cURL import/export** (`Curl.ps1` + `Ui.Code.ps1`): `Split-PPCommandLine` is a quote-aware
  tokenizer (handles `'`/`"` and `\`/`^`/backtick line continuations). `ConvertFrom-PPCurl`
  produces a `New-PPTab`-shaped model (mapping `-u` and `Authorization: Bearer`/`Basic` to the
  auth model, the rest to header rows); `ConvertTo-PPCurl`/`ConvertTo-PPPowerShell` go the other
  way, expanding `{{variables}}` first so output is runnable. Import opens a new tab; the copy
  commands act on the current tab via `Get-PPCurrentCtx`. Keep this UI-free so `-SelfTest` covers
  the parse/generate round-trip.

- **LLM Playground** (`Llm.ps1` + `Ui.Llm.ps1`): multi-provider chat split into a **dialect**
  (request/response body: `openai`/`anthropic`/`gemini`) and an **auth** type
  (`bearer`/`anthropic`/`googleApiKey`/`vertex`). `Build-PPLlmBody` builds the body per dialect;
  `Resolve-PPLlmAuthHeaders` builds headers per auth; `Read-PPLlmResponse` extracts text/usage;
  `Invoke-PPLlmChat` ties them together (expanding `{{vars}}` first, sending via `Invoke-PPRequest`).
  Provider catalog lives in `state.llm.providers` (JSON-editable; `ConvertFrom-PPProviderFile`
  imports the owner's `VertexAI` file shape). **Vertex** auth signs a service-account JWT via the
  `PPVertexAuth` `Add-Type` C# helper — it hand-parses the PKCS#8 PEM (no `ImportPkcs8PrivateKey`
  on net48) and signs RS256 with `RSACng`; tokens cache on the provider via `Set-PPTokenFromResponse`.
  Keep `Llm.ps1` UI-free so `-SelfTest` covers builders/parsers/JWT. The Playground
  (`$Global:PPApp.llmForm`/`llmTabs`) is a single-instance modeless window that mirrors the main
  app's tabbed-editor pattern: a `TabControl` of saved chats, each tab's `.Tag` a ctx with controls
  + `model` (a `New-PPLlmTab`: provider/model/system/params + `conversation`). Per-tab handlers
  carry ctx via `control.Tag`. `Invoke-PPLlmChat` returns `request` + full `response`
  (status/time/size/headers/raw) which `Show-PPLlmDetails` renders into the Response/Resp Headers/
  Request notebook. Tabs (incl. conversations + the pending attachment queue + `thinking`) persist
  to `state.llm.tabs` via `Save-PPLlmState` (on the Save button and on window close). The
  **Thinking** control (Default/Off/Low/Medium/High) maps per dialect in `Build-PPLlmBody`: Gemini
  3.x → `thinkingConfig.thinkingLevel`, Gemini 2.5 → `thinkingConfig.thinkingBudget`, Anthropic →
  `thinking`/`output_config.effort`, OpenAI → `reasoning_effort`. When a 200 response has no text,
  `Read-PPLlmResponse` returns a note carrying the `finishReason` instead of a blank reply.
  The Playground does **not** auto-save (no `FormClosing` save) — only the **Save** button
  (`Save-PPLlmState`) persists; `Send-PPLlmMessage` allows any of text / image / system prompt.
  `ConvertFrom-PPProviderFile` consolidates `VertexAI` entries sharing an endpoint + service account
  into one "Google Vertex" provider whose model list holds all their models. The tab strip has a
  right-click menu (New/Duplicate/Rename/Close); `Duplicate-PPLlmTabCmd` deep-copies the tab model
  (settings + conversation) via a JSON round-trip + `Resolve-PPLlmTab`.

- **Settings & history**: `state.followRedirects`/`proxy` feed `Invoke-PPRequest`
  (`-FollowRedirects`/`-Proxy` → `HttpClientHandler`); the **Tools** toolbar button drops a menu to
  `Show-PPSettings`/`Show-PPHistory`. Each send calls `Add-PPHistoryEntry` (`Ui.Send.ps1`) which
  prepends a `New-PPHistoryEntry` (summary + a `Copy-PPTab` of the request) to `state.history`,
  capped at 50; the history viewer reopens an entry via `Add-PPTabPage (Copy-PPTab …)`. Response
  search is `Find-PPResponseMatch` over the active Body/Raw/Request box (`HideSelection=$false`).

- **Cookie jar** (`Http.ps1` + `Ui.Tools.ps1`): a shared `System.Net.CookieContainer` lives at
  `$Global:PPApp.cookies` (created + `Import-PPCookies` in `Start-PowerPost`, `Export-PPCookies` in
  `Build-PPStateFromUi`). `Invoke-PPSend` passes it as `-CookieContainer` when
  `state.cookiesEnabled`. net48 has no `GetAllCookies()`, so `Get-PPAllCookies` enumerates via
  reflection over the container's private `m_domainTable`/`m_list`. `Show-PPCookies` lists/deletes
  (rebuilds the container minus the selected cookie) / clears.

- **Persistence** (`State.ps1`): state saves to `powerpost.state.json` next to the script on
  Ctrl+S and on window close (`Add_FormClosing`). Corrupt files are backed up to `.bak` and a
  fresh state is started rather than failing. Secrets are stored in **plaintext** by design
  (dev creds vs. internal APIs); the file is git-ignored.

## Conventions

- All public functions are prefixed `PP`/`-PP` (e.g. `New-PPTab`, `Invoke-PPRequest`).
- Globals: `$Global:PPRoot` (script dir, used by State), `$Global:PPApp` (live UI handles),
  `$Global:PPIgnoreSsl` / `[PPCertPolicy]::IgnoreErrors` (SSL toggle).
- Keep files under ~500 lines; the lib is already split by concern — add new concerns as new
  `lib\*.ps1` and register them in the load list in `PowerPost.ps1`.
- After editing any lib, run `-SelfTest` to confirm the build still works.
