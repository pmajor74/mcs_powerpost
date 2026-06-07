# Tests.ps1 — UI-free post-response assertions. Each test (New-PPTest) checks one facet of
# the response (status / time / header / JSON body path / raw body) with an operator.

# Navigate a dotted JSON path (e.g. "data.items.0.id") on a ConvertFrom-Json object.
# Returns @{ found = <bool>; value = <object> }.
function Get-PPJsonPathValue {
    param($Obj, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @{ found = $true; value = $Obj } }
    $cur = $Obj
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return @{ found = $false; value = $null } }
        if ($seg -match '^\d+$') {
            $arr = @($cur); $idx = [int]$seg
            if ($idx -ge 0 -and $idx -lt $arr.Count) { $cur = $arr[$idx] } else { return @{ found = $false; value = $null } }
        } elseif ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($seg)) { $cur = $cur[$seg] } else { return @{ found = $false; value = $null } }
        } else {
            $p = $cur.PSObject.Properties[$seg]
            if ($null -eq $p) { return @{ found = $false; value = $null } }
            $cur = $p.Value
        }
    }
    return @{ found = $true; value = $cur }
}

# Apply an operator. $Found indicates the actual value was present.
function Test-PPOp {
    param([string]$Op, $Actual, [string]$Expected, [bool]$Found)
    switch ($Op) {
        'exists'    { return ($Found -and ($null -ne $Actual)) }
        'notExists' { return ((-not $Found) -or ($null -eq $Actual)) }
    }
    if (-not $Found) { return $false }
    $a = "$Actual"
    $an = 0.0; $en = 0.0
    $bothNum = ([double]::TryParse($a, [ref]$an) -and [double]::TryParse($Expected, [ref]$en))
    switch ($Op) {
        'equals'      { if ($bothNum) { return ($an -eq $en) } return ($a -ceq $Expected) }
        'notEquals'   { if ($bothNum) { return ($an -ne $en) } return ($a -cne $Expected) }
        'contains'    { return ($a.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) }
        'notContains' { return ($a.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) }
        'lessThan'    { if ($bothNum) { return ($an -lt $en) } return $false }
        'greaterThan' { if ($bothNum) { return ($an -gt $en) } return $false }
        'matches'     { try { return [regex]::IsMatch($a, $Expected) } catch { return $false } }
        default       { return $false }
    }
}

function Format-PPTestName {
    param($Test)
    $label = switch ([string]$Test.source) {
        'status'  { 'status' } 'time' { 'time (ms)' } 'rawBody' { 'raw body' }
        'header'  { "header '$($Test.path)'" } 'body' { "body.$($Test.path)" } default { [string]$Test.source }
    }
    $opTxt = switch ([string]$Test.op) {
        'equals' { '==' } 'notEquals' { '!=' } 'contains' { 'contains' } 'notContains' { 'not contains' }
        'lessThan' { '<' } 'greaterThan' { '>' } 'exists' { 'exists' } 'notExists' { 'not exists' } 'matches' { 'matches' } default { [string]$Test.op }
    }
    if ($Test.op -eq 'exists' -or $Test.op -eq 'notExists') { return "$label $opTxt" }
    return "$label $opTxt $($Test.value)"
}

# Evaluate one assertion against a response (and a pre-parsed JSON body for 'body' tests).
function Test-PPAssertion {
    param($Test, $Resp, $BodyObj, [bool]$BodyOk)
    $found = $true; $actual = $null
    switch ([string]$Test.source) {
        'status'  { $actual = [int]$Resp.statusCode }
        'time'    { $actual = [int]$Resp.elapsedMs }
        'rawBody' { $actual = [string]$Resp.body }
        'header'  {
            $h = @($Resp.headers | Where-Object { [string]$_.key -ieq [string]$Test.path }) | Select-Object -First 1
            if ($h) { $actual = [string]$h.value } else { $found = $false }
        }
        'body'    {
            if (-not $BodyOk) { $found = $false }
            else { $r = Get-PPJsonPathValue $BodyObj $Test.path; $found = $r.found; $actual = $r.value }
        }
        default   { $found = $false }
    }
    $passed = Test-PPOp ([string]$Test.op) $actual ([string]$Test.value) $found
    $shown = if ($found) { "$actual" } else { '(not found)' }
    return @{ name = (Format-PPTestName $Test); passed = [bool]$passed; actual = $shown }
}

# Run all enabled tests against a response. Returns @{ results=@(...); passed; total }.
function Invoke-PPTests {
    param($Tests, $Resp)
    $bodyObj = $null; $bodyOk = $false
    if ((@($Tests | Where-Object { $_.enabled -and $_.source -eq 'body' }).Count -gt 0) -and $Resp.ok) {
        try { $bodyObj = $Resp.body | ConvertFrom-Json -ErrorAction Stop; $bodyOk = $true } catch { $bodyOk = $false }
    }
    $results = @()
    foreach ($t in @($Tests)) {
        if (-not $t.enabled) { continue }
        $results += (Test-PPAssertion $t $Resp $bodyObj $bodyOk)
    }
    $passed = @($results | Where-Object { $_.passed }).Count
    return @{ results = $results; passed = $passed; total = @($results).Count }
}
