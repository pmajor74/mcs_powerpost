# Vars.ps1 — environment variable substitution ({{name}} -> value).
# Pure, UI-free logic so it can be exercised by -SelfTest.

# Build a name->value lookup from an environment's enabled variable rows.
function Get-PPVarMap {
    param($Environment)
    $map = @{}
    if ($null -eq $Environment) { return $map }
    foreach ($r in @($Environment.variables)) {
        if ($null -eq $r) { continue }
        if (-not $r.enabled) { continue }
        $k = [string]$r.key
        if ([string]::IsNullOrEmpty($k)) { continue }
        $map[$k] = [string]$r.value
    }
    return $map
}

# Replace {{name}} tokens in a string using the map. Unknown tokens (and tokens whose
# variable is disabled/absent) are left exactly as-is. Inner whitespace is tolerated:
# {{ name }} matches the "name" variable.
function Expand-PPVars {
    param([string]$Text, $Map)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($null -eq $Map -or $Map.Count -eq 0) { return $Text }
    $rx = [regex]'\{\{\s*([^{}\s]+)\s*\}\}'
    $ms = $rx.Matches($Text)
    if ($ms.Count -eq 0) { return $Text }
    # Build the result manually (no MatchEvaluator delegate) to avoid closure-scope issues.
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in $ms) {
        [void]$sb.Append($Text.Substring($pos, $m.Index - $pos))
        $name = $m.Groups[1].Value
        if ($Map.ContainsKey($name)) { [void]$sb.Append([string]$Map[$name]) }
        else { [void]$sb.Append($m.Value) }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($Text.Substring($pos))
    return $sb.ToString()
}

# Expand {{name}} in the key and value of each key/value row, preserving enabled state.
function Expand-PPKvList {
    param($Rows, $Map)
    $list = @()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $list += @{
            enabled = [bool]$r.enabled
            key     = (Expand-PPVars ([string]$r.key) $Map)
            value   = (Expand-PPVars ([string]$r.value) $Map)
        }
    }
    return , $list
}

# Expand {{name}} in multipart rows (key + value/path), preserving enabled state and kind.
function Expand-PPMultipartList {
    param($Rows, $Map)
    $list = @()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $list += @{
            enabled = [bool]$r.enabled
            key     = (Expand-PPVars ([string]$r.key) $Map)
            kind    = [string]$r.kind
            value   = (Expand-PPVars ([string]$r.value) $Map)
        }
    }
    return , $list
}

# Return a copy of an auth hashtable with its string fields variable-expanded.
# Cached-token fields (accessToken/tokenExpiry) are copied verbatim so the caller can
# carry a freshly fetched token back to the persisted model.
function Expand-PPAuth {
    param($Auth, $Map)
    $a = $Auth.Clone()
    foreach ($f in @('bearerToken', 'basicUser', 'basicPass', 'tokenUrl', 'clientId', 'clientSecret', 'scope', 'authUrl')) {
        $a[$f] = Expand-PPVars ([string]$Auth[$f]) $Map
    }
    return $a
}
