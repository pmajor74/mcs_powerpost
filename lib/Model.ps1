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

function New-PPAuth {
    return @{
        type            = 'none'        # none | bearer | basic | clientcreds | authcode
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
        # cached token (both OAuth flows)
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
        bodyType  = 'none'              # none | json | text | form | multipart
        body      = ''                  # raw text for json/text
        form      = @()                 # rows for x-www-form-urlencoded
        multipart = @()                 # rows for multipart/form-data (New-PPMultipartRow)
        auth      = (New-PPAuth)
    }
}

# An environment is a named bag of {{variable}} substitutions (key/value rows).
function New-PPEnvironment {
    param([string]$Name = 'Default')
    return @{ name = $Name; variables = @() }   # variables: rows from New-PPKv
}

# A collection is a named, saved group of requests (each request is a New-PPTab-shaped model).
function New-PPCollection {
    param([string]$Name = 'New Collection')
    return @{ name = $Name; requests = @() }
}

function New-PPState {
    return @{
        version      = 1
        window       = @{ width = 1100; height = 780; x = -1; y = -1; maximized = $false }
        activeTab    = 0
        ignoreSsl    = $false
        timeout      = 100
        tabs         = @((New-PPTab))
        environments = @()              # list of New-PPEnvironment
        activeEnv    = ''               # name of the active environment; '' = none
        collections  = @()              # list of New-PPCollection (saved request library)
    }
}

# --- normalization: turn parsed JSON (PSCustomObject) into our hashtable model ---

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
    $t.auth      = Resolve-PPAuth (Get-PPProp $Raw 'auth' $null)
    return $t
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
    return $c
}

function Resolve-PPState {
    param($Raw)
    $s = New-PPState
    if ($null -eq $Raw) { return $s }
    $s.version   = [int](Get-PPProp $Raw 'version' 1)
    $s.activeTab = [int](Get-PPProp $Raw 'activeTab' 0)
    $s.ignoreSsl = [bool](Get-PPProp $Raw 'ignoreSsl' $false)
    $s.timeout   = [int](Get-PPProp $Raw 'timeout' 100)
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
    return $s
}
