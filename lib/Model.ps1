# Model.ps1 — default data model + normalization of loaded JSON.
# The whole app state is plain hashtables/arrays so it serializes cleanly to JSON.

# Safe property read from a PSCustomObject (what ConvertFrom-Json returns) with a default.
function Get-PPProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# A single key/value row (used by params, headers, form body).
function New-PPKv {
    param([bool]$Enabled = $true, [string]$Key = '', [string]$Value = '')
    return @{ enabled = $Enabled; key = $Key; value = $Value }
}

# A multipart/form-data field: a text value or a file (value holds the file path).
function New-PPMultipartRow {
    param([bool]$Enabled = $true, [string]$Key = '', [string]$Kind = 'text', [string]$Value = '')
    return @{ enabled = $Enabled; key = $Key; kind = $Kind; value = $Value }   # kind: text | file
}

# A post-response assertion. source: status|time|header|body|rawBody;
# op: equals|notEquals|contains|notContains|lessThan|greaterThan|exists|notExists|matches.
# path = JSON dotted path (body) or header name (header); value = expected.
function New-PPTest {
    param([bool]$Enabled = $true, [string]$Source = 'status', [string]$Path = '', [string]$Op = 'equals', [string]$Value = '')
    return @{ enabled = $Enabled; source = $Source; path = $Path; op = $Op; value = $Value }
}

# A saved response example: a snapshot of a response kept on a request for reference.
function New-PPExample {
    return @{ name = ''; method = 'GET'; url = ''; statusCode = 0; reason = ''; contentType = ''; elapsedMs = 0; sizeBytes = 0; body = ''; headers = @() }
}

function New-PPAuth {
    return @{
        type            = 'none'        # none | bearer | basic | clientcreds | authcode | vertex
        bearerToken     = ''
        basicUser       = ''
        basicPass       = ''
        # OAuth2 (shared)
        tokenUrl        = ''
        clientId        = ''
        clientSecret    = ''
        scope           = ''
        clientAuthStyle = 'body'        # body | header  (how client id/secret are sent)
        # OAuth2 authorization code
        authUrl         = ''
        redirectPort    = 8080
        usePkce         = $true
        # Google service-account (Vertex) — RS256-signs a JWT to mint a cloud-platform token
        clientEmail     = ''
        privateKey      = ''            # PKCS#8 PEM ("-----BEGIN PRIVATE KEY-----")
        # cached token (OAuth flows + vertex)
        accessToken     = ''
        tokenExpiry     = ''            # ISO-8601 UTC string, '' when none
    }
}

function New-PPTab {
    param([string]$Name = 'New Request')
    return @{
        name      = $Name
        method    = 'GET'
        url       = ''
        params    = @()                 # query-string rows
        headers   = @()
        bodyType  = 'none'              # none | json | text | form | multipart | graphql
        body      = ''                  # raw text for json/text; the query for graphql
        form      = @()                 # rows for x-www-form-urlencoded
        multipart = @()                 # rows for multipart/form-data (New-PPMultipartRow)
        graphqlVars = ''                # JSON variables for graphql
        auth      = (New-PPAuth)
        tests     = @()                 # post-response assertions (New-PPTest)
        examples  = @()                 # saved response snapshots (New-PPExample)
    }
}

# An environment is a named bag of {{variable}} substitutions (key/value rows).
function New-PPEnvironment {
    param([string]$Name = 'Default')
    return @{ name = $Name; variables = @() }   # variables: rows from New-PPKv
}

# A collection is a named, saved group of requests (each request is a New-PPTab-shaped model).
# `auth` is the collection default that requests with auth.type='inherit' resolve to on open.
function New-PPCollection {
    param([string]$Name = 'New Collection')
    return @{ name = $Name; requests = @(); auth = (New-PPAuth) }
}

# If a request's auth is 'inherit', return a deep copy of the collection's auth; else its own auth.
function Resolve-PPInheritedAuth {
    param($Auth, $CollectionAuth)
    if ($null -ne $Auth -and $Auth.type -eq 'inherit' -and $null -ne $CollectionAuth) {
        return (Resolve-PPAuth ($CollectionAuth | ConvertTo-Json -Depth 20 | ConvertFrom-Json))
    }
    return $Auth
}

# An LLM provider entry. One shape covers every auth type; unused fields stay empty.
function New-PPLlmProvider {
    param(
        [string]$Name = '', [string]$Dialect = 'openai', [string]$Auth = 'bearer',
        [string]$BaseUrl = '', [string]$Model = '', $Models = @(),
        [string]$ApiKey = '', [string]$ClientEmail = '', [string]$PrivateKey = '', [int]$MaxRetries = 0
    )
    return @{
        name = $Name; dialect = $Dialect; auth = $Auth       # dialect: openai|anthropic|gemini ; auth: bearer|anthropic|googleApiKey|vertex
        baseUrl = $BaseUrl; model = $Model; models = $Models
        apiKey = $ApiKey                                      # bearer/anthropic/googleApiKey
        clientEmail = $ClientEmail; privateKey = $PrivateKey  # vertex (service account)
        maxRetries = $MaxRetries
        accessToken = ''; tokenExpiry = ''                    # cached vertex OAuth token
    }
}

# A saved LLM Playground tab: provider/model/system/params + full conversation.
function New-PPLlmTab {
    param([string]$Name = 'LLM Chat')
    return @{
        name = $Name; provider = ''; model = ''; system = ''
        maxTokens = '4096'; temperature = ''   # generous default — thinking models spend budget on reasoning
        thinking = ''               # '' = auto (pick the model's lowest supported on first load); else Default|Off|Low|Medium|High
        attachments = @()           # pending (not-yet-sent) image paths
        conversation = @()          # rows of @{ role; text; images=@(paths) }
    }
}

# Default LLM config — ships the big providers with NO secrets (keys entered at runtime).
function New-PPLlmConfig {
    $openai = New-PPLlmProvider 'OpenAI' 'openai' 'bearer' 'https://api.openai.com/v1' 'gpt-4o' @('gpt-4o', 'gpt-4o-mini')
    $anthropic = New-PPLlmProvider 'Anthropic' 'anthropic' 'anthropic' 'https://api.anthropic.com/v1' 'claude-opus-4-8' @('claude-opus-4-8', 'claude-sonnet-4-6', 'claude-haiku-4-5')
    $gemini = New-PPLlmProvider 'Gemini (AI Studio)' 'gemini' 'googleApiKey' 'https://generativelanguage.googleapis.com/v1beta' 'gemini-2.0-flash' @('gemini-2.0-flash', 'gemini-1.5-pro')
    return @{ providers = @($openai, $anthropic, $gemini); activeProvider = ''; activeModel = ''; tabs = @((New-PPLlmTab)); activeTab = 0 }
}

function New-PPState {
    return @{
        version      = 1
        window       = @{ width = 1100; height = 780; x = -1; y = -1; maximized = $false }
        activeTab    = 0
        ignoreSsl    = $false
        timeout      = 100
        followRedirects = $true         # follow 3xx redirects
        proxy        = ''               # HTTP proxy URL ('' = none)
        cookiesEnabled = $true          # use a shared cookie jar across requests
        cookies      = @()              # persisted cookies (Resolve-PPCookie shape)
        history      = @()              # recent sends (New-PPHistoryEntry shape)
        tabs         = @((New-PPTab))
        environments = @()              # list of New-PPEnvironment
        activeEnv    = ''               # name of the active environment; '' = none
        collections  = @()              # list of New-PPCollection (saved request library)
        llm          = (New-PPLlmConfig)# LLM Playground provider catalog + last selection
    }
}

# --- normalization: turn parsed JSON (PSCustomObject) into our hashtable model ---

# Serialize key/value rows to bulk-edit text ("key: value" per line; "//" prefix = disabled).
function ConvertTo-PPKvText {
    param($Rows)
    $lines = @()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ([string]::IsNullOrEmpty([string]$r.key) -and [string]::IsNullOrEmpty([string]$r.value)) { continue }
        $prefix = if ($r.enabled) { '' } else { '//' }
        $lines += ($prefix + [string]$r.key + ': ' + [string]$r.value)
    }
    return ($lines -join "`r`n")
}

# Parse bulk-edit text back into key/value rows.
function ConvertFrom-PPKvText {
    param([string]$Text)
    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $enabled = $true
        $t = $line.TrimStart()
        if ($t.StartsWith('//')) { $enabled = $false; $t = $t.Substring(2) }
        $idx = $t.IndexOf(':')
        if ($idx -lt 0) { $k = $t.Trim(); $v = '' } else { $k = $t.Substring(0, $idx).Trim(); $v = $t.Substring($idx + 1).Trim() }
        if ([string]::IsNullOrEmpty($k) -and [string]::IsNullOrEmpty($v)) { continue }
        $rows += (New-PPKv $enabled $k $v)
    }
    return , $rows
}

function Resolve-PPKv {
    param($Raw)
    return @{
        enabled = [bool](Get-PPProp $Raw 'enabled' $true)
        key     = [string](Get-PPProp $Raw 'key' '')
        value   = [string](Get-PPProp $Raw 'value' '')
    }
}

function Resolve-PPKvList {
    param($Raw)
    $list = @()
    foreach ($r in @($Raw)) { if ($null -ne $r) { $list += (Resolve-PPKv $r) } }
    return , $list
}

function Resolve-PPMultipartRow {
    param($Raw)
    return @{
        enabled = [bool](Get-PPProp $Raw 'enabled' $true)
        key     = [string](Get-PPProp $Raw 'key' '')
        kind    = [string](Get-PPProp $Raw 'kind' 'text')
        value   = [string](Get-PPProp $Raw 'value' '')
    }
}

function Resolve-PPMultipartList {
    param($Raw)
    $list = @()
    foreach ($r in @($Raw)) { if ($null -ne $r) { $list += (Resolve-PPMultipartRow $r) } }
    return , $list
}

function Resolve-PPAuth {
    param($Raw)
    $a = New-PPAuth
    if ($null -eq $Raw) { return $a }
    $a.type            = [string](Get-PPProp $Raw 'type' $a.type)
    $a.bearerToken     = [string](Get-PPProp $Raw 'bearerToken' '')
    $a.basicUser       = [string](Get-PPProp $Raw 'basicUser' '')
    $a.basicPass       = [string](Get-PPProp $Raw 'basicPass' '')
    $a.tokenUrl        = [string](Get-PPProp $Raw 'tokenUrl' '')
    $a.clientId        = [string](Get-PPProp $Raw 'clientId' '')
    $a.clientSecret    = [string](Get-PPProp $Raw 'clientSecret' '')
    $a.scope           = [string](Get-PPProp $Raw 'scope' '')
    $a.clientAuthStyle = [string](Get-PPProp $Raw 'clientAuthStyle' 'body')
    $a.authUrl         = [string](Get-PPProp $Raw 'authUrl' '')
    $a.redirectPort    = [int](Get-PPProp $Raw 'redirectPort' 8080)
    $a.usePkce         = [bool](Get-PPProp $Raw 'usePkce' $true)
    $a.clientEmail     = [string](Get-PPProp $Raw 'clientEmail' '')
    $a.privateKey      = [string](Get-PPProp $Raw 'privateKey' '')
    $a.accessToken     = [string](Get-PPProp $Raw 'accessToken' '')
    $a.tokenExpiry     = [string](Get-PPProp $Raw 'tokenExpiry' '')
    return $a
}

function Resolve-PPTab {
    param($Raw)
    $t = New-PPTab
    if ($null -eq $Raw) { return $t }
    $t.name     = [string](Get-PPProp $Raw 'name' 'New Request')
    $t.method   = [string](Get-PPProp $Raw 'method' 'GET')
    $t.url      = [string](Get-PPProp $Raw 'url' '')
    $t.params   = Resolve-PPKvList (Get-PPProp $Raw 'params' @())
    $t.headers  = Resolve-PPKvList (Get-PPProp $Raw 'headers' @())
    $t.bodyType  = [string](Get-PPProp $Raw 'bodyType' 'none')
    $t.body      = [string](Get-PPProp $Raw 'body' '')
    $t.form      = Resolve-PPKvList (Get-PPProp $Raw 'form' @())
    $t.multipart = Resolve-PPMultipartList (Get-PPProp $Raw 'multipart' @())
    $t.graphqlVars = [string](Get-PPProp $Raw 'graphqlVars' '')
    $t.auth      = Resolve-PPAuth (Get-PPProp $Raw 'auth' $null)
    $t.tests     = Resolve-PPTestList (Get-PPProp $Raw 'tests' @())
    $t.examples  = Resolve-PPExampleList (Get-PPProp $Raw 'examples' @())
    return $t
}

function Resolve-PPTest {
    param($Raw)
    return @{
        enabled = [bool](Get-PPProp $Raw 'enabled' $true)
        source  = [string](Get-PPProp $Raw 'source' 'status')
        path    = [string](Get-PPProp $Raw 'path' '')
        op      = [string](Get-PPProp $Raw 'op' 'equals')
        value   = [string](Get-PPProp $Raw 'value' '')
    }
}
function Resolve-PPTestList {
    param($Raw)
    $list = @()
    foreach ($r in @($Raw)) { if ($null -ne $r) { $list += (Resolve-PPTest $r) } }
    return , $list
}

function Resolve-PPExample {
    param($Raw)
    $e = New-PPExample
    if ($null -eq $Raw) { return $e }
    $e.name        = [string](Get-PPProp $Raw 'name' '')
    $e.method      = [string](Get-PPProp $Raw 'method' 'GET')
    $e.url         = [string](Get-PPProp $Raw 'url' '')
    $e.statusCode  = [int](Get-PPProp $Raw 'statusCode' 0)
    $e.reason      = [string](Get-PPProp $Raw 'reason' '')
    $e.contentType = [string](Get-PPProp $Raw 'contentType' '')
    $e.elapsedMs   = [int](Get-PPProp $Raw 'elapsedMs' 0)
    $e.sizeBytes   = [int](Get-PPProp $Raw 'sizeBytes' 0)
    $e.body        = [string](Get-PPProp $Raw 'body' '')
    $e.headers     = Resolve-PPKvList (Get-PPProp $Raw 'headers' @())
    return $e
}
function Resolve-PPExampleList {
    param($Raw)
    $list = @()
    foreach ($r in @($Raw)) { if ($null -ne $r) { $list += (Resolve-PPExample $r) } }
    return , $list
}

function Resolve-PPEnvironment {
    param($Raw)
    $e = New-PPEnvironment
    if ($null -eq $Raw) { return $e }
    $e.name      = [string](Get-PPProp $Raw 'name' 'Default')
    $e.variables = Resolve-PPKvList (Get-PPProp $Raw 'variables' @())
    return $e
}

function Resolve-PPCollection {
    param($Raw)
    $c = New-PPCollection
    if ($null -eq $Raw) { return $c }
    $c.name = [string](Get-PPProp $Raw 'name' 'New Collection')
    $reqs = @()
    foreach ($rr in @(Get-PPProp $Raw 'requests' @())) { $reqs += (Resolve-PPTab $rr) }
    $c.requests = $reqs
    $c.auth = Resolve-PPAuth (Get-PPProp $Raw 'auth' $null)
    return $c
}

function Resolve-PPLlmProvider {
    param($Raw)
    $p = New-PPLlmProvider
    if ($null -eq $Raw) { return $p }
    $p.name        = [string](Get-PPProp $Raw 'name' '')
    $p.dialect     = [string](Get-PPProp $Raw 'dialect' 'openai')
    $p.auth        = [string](Get-PPProp $Raw 'auth' 'bearer')
    $p.baseUrl     = [string](Get-PPProp $Raw 'baseUrl' '')
    $p.model       = [string](Get-PPProp $Raw 'model' '')
    $mlist = @()
    foreach ($m in @(Get-PPProp $Raw 'models' @())) { if ($null -ne $m) { $mlist += [string]$m } }
    $p.models      = $mlist
    $p.apiKey      = [string](Get-PPProp $Raw 'apiKey' '')
    $p.clientEmail = [string](Get-PPProp $Raw 'clientEmail' '')
    $p.privateKey  = [string](Get-PPProp $Raw 'privateKey' '')
    $p.maxRetries  = [int](Get-PPProp $Raw 'maxRetries' 0)
    $p.accessToken = [string](Get-PPProp $Raw 'accessToken' '')
    $p.tokenExpiry = [string](Get-PPProp $Raw 'tokenExpiry' '')
    return $p
}

function Resolve-PPLlmConvTurn {
    param($Raw)
    $imgs = @()
    foreach ($i in @(Get-PPProp $Raw 'images' @())) { if ($null -ne $i) { $imgs += [string]$i } }
    return @{
        role   = [string](Get-PPProp $Raw 'role' 'user')
        text   = [string](Get-PPProp $Raw 'text' '')
        images = $imgs
    }
}

function Resolve-PPLlmTab {
    param($Raw)
    $t = New-PPLlmTab
    if ($null -eq $Raw) { return $t }
    $t.name        = [string](Get-PPProp $Raw 'name' 'LLM Chat')
    $t.provider    = [string](Get-PPProp $Raw 'provider' '')
    $t.model       = [string](Get-PPProp $Raw 'model' '')
    $t.system      = [string](Get-PPProp $Raw 'system' '')
    $t.maxTokens   = [string](Get-PPProp $Raw 'maxTokens' '4096')
    $t.temperature = [string](Get-PPProp $Raw 'temperature' '')
    $t.thinking    = [string](Get-PPProp $Raw 'thinking' '')
    $att = @()
    foreach ($a in @(Get-PPProp $Raw 'attachments' @())) { if ($null -ne $a) { $att += [string]$a } }
    $t.attachments = $att
    $conv = @()
    foreach ($c in @(Get-PPProp $Raw 'conversation' @())) { if ($null -ne $c) { $conv += (Resolve-PPLlmConvTurn $c) } }
    $t.conversation = $conv
    return $t
}

function Resolve-PPLlmConfig {
    param($Raw)
    if ($null -eq $Raw) { return (New-PPLlmConfig) }
    $provsRaw = Get-PPProp $Raw 'providers' $null
    $provs = @()
    foreach ($rp in @($provsRaw)) { if ($null -ne $rp) { $provs += (Resolve-PPLlmProvider $rp) } }
    # Empty/absent providers -> seed defaults so first run is usable.
    if ($provs.Count -eq 0) { return (New-PPLlmConfig) }
    $tabs = @()
    foreach ($rt in @(Get-PPProp $Raw 'tabs' @())) { if ($null -ne $rt) { $tabs += (Resolve-PPLlmTab $rt) } }
    if ($tabs.Count -eq 0) { $tabs = @((New-PPLlmTab)) }
    $active = [int](Get-PPProp $Raw 'activeTab' 0)
    if ($active -lt 0 -or $active -ge $tabs.Count) { $active = 0 }
    return @{
        providers      = $provs
        activeProvider = [string](Get-PPProp $Raw 'activeProvider' '')
        activeModel    = [string](Get-PPProp $Raw 'activeModel' '')
        tabs           = $tabs
        activeTab      = $active
    }
}

function Resolve-PPCookie {
    param($Raw)
    return @{
        name     = [string](Get-PPProp $Raw 'name' '')
        value    = [string](Get-PPProp $Raw 'value' '')
        domain   = [string](Get-PPProp $Raw 'domain' '')
        path     = [string](Get-PPProp $Raw 'path' '/')
        expires  = [string](Get-PPProp $Raw 'expires' '')
        secure   = [bool](Get-PPProp $Raw 'secure' $false)
        httpOnly = [bool](Get-PPProp $Raw 'httpOnly' $false)
    }
}

# A request-history entry: summary fields + a re-runnable copy of the request model.
function New-PPHistoryEntry {
    return @{ when = ''; method = 'GET'; url = ''; statusCode = 0; elapsedMs = 0; ok = $false; request = (New-PPTab) }
}

function Resolve-PPHistoryEntry {
    param($Raw)
    $e = New-PPHistoryEntry
    if ($null -eq $Raw) { return $e }
    $e.when       = [string](Get-PPProp $Raw 'when' '')
    $e.method     = [string](Get-PPProp $Raw 'method' 'GET')
    $e.url        = [string](Get-PPProp $Raw 'url' '')
    $e.statusCode = [int](Get-PPProp $Raw 'statusCode' 0)
    $e.elapsedMs  = [int](Get-PPProp $Raw 'elapsedMs' 0)
    $e.ok         = [bool](Get-PPProp $Raw 'ok' $false)
    $e.request    = Resolve-PPTab (Get-PPProp $Raw 'request' $null)
    return $e
}

function Resolve-PPState {
    param($Raw)
    $s = New-PPState
    if ($null -eq $Raw) { return $s }
    $s.version   = [int](Get-PPProp $Raw 'version' 1)
    $s.activeTab = [int](Get-PPProp $Raw 'activeTab' 0)
    $s.ignoreSsl = [bool](Get-PPProp $Raw 'ignoreSsl' $false)
    $s.timeout   = [int](Get-PPProp $Raw 'timeout' 100)
    $s.followRedirects = [bool](Get-PPProp $Raw 'followRedirects' $true)
    $s.proxy     = [string](Get-PPProp $Raw 'proxy' '')
    $s.cookiesEnabled = [bool](Get-PPProp $Raw 'cookiesEnabled' $true)
    $s.activeEnv = [string](Get-PPProp $Raw 'activeEnv' '')

    $w = Get-PPProp $Raw 'window' $null
    $s.window = @{
        width     = [int](Get-PPProp $w 'width' 1100)
        height    = [int](Get-PPProp $w 'height' 780)
        x         = [int](Get-PPProp $w 'x' -1)
        y         = [int](Get-PPProp $w 'y' -1)
        maximized = [bool](Get-PPProp $w 'maximized' $false)
    }

    $tabs = @()
    foreach ($rt in @(Get-PPProp $Raw 'tabs' @())) { $tabs += (Resolve-PPTab $rt) }
    if ($tabs.Count -eq 0) { $tabs = @((New-PPTab)) }
    $s.tabs = $tabs
    if ($s.activeTab -lt 0 -or $s.activeTab -ge $s.tabs.Count) { $s.activeTab = 0 }

    $envs = @()
    foreach ($re in @(Get-PPProp $Raw 'environments' @())) { $envs += (Resolve-PPEnvironment $re) }
    $s.environments = $envs
    # Drop a stale active-env reference that no longer matches any environment.
    if ($s.activeEnv -and (@($envs | ForEach-Object { $_.name }) -notcontains $s.activeEnv)) { $s.activeEnv = '' }

    $cols = @()
    foreach ($rc in @(Get-PPProp $Raw 'collections' @())) { $cols += (Resolve-PPCollection $rc) }
    $s.collections = $cols

    $s.llm = Resolve-PPLlmConfig (Get-PPProp $Raw 'llm' $null)

    $hist = @()
    foreach ($rh in @(Get-PPProp $Raw 'history' @())) { if ($null -ne $rh) { $hist += (Resolve-PPHistoryEntry $rh) } }
    $s.history = $hist

    $cks = @()
    foreach ($rc in @(Get-PPProp $Raw 'cookies' @())) { if ($null -ne $rc) { $cks += (Resolve-PPCookie $rc) } }
    $s.cookies = $cks
    return $s
}
