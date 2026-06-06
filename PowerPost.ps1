#requires -Version 5
<#
.SYNOPSIS
    MCS PowerPost - a lightweight Postman-style API tester for Windows PowerShell 5.1.
    A Major Computing Systems product (https://majorcomputingsystems.ca).
.DESCRIPTION
    Tabbed request editor (method/URL/params/headers/body) with No-auth, Bearer/JWT,
    Basic, and OAuth2 (client-credentials and authorization-code + PKCE) auth. Tabs and
    UI state are saved to powerpost.state.json next to this script, on Save (Ctrl+S) and
    automatically on close.
.PARAMETER SelfTest
    Run quick non-GUI self-checks (model round-trip, JSON formatter, live HTTP, PKCE) and
    exit. Used to validate the build.
.EXAMPLE
    powershell -STA -File .\PowerPost.ps1
.EXAMPLE
    powershell -File .\PowerPost.ps1 -SelfTest
#>
param([switch]$SelfTest)

# WinForms needs STA. Relaunch ourselves under -STA if we aren't already (GUI mode only).
if (-not $SelfTest -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

$ErrorActionPreference = 'Stop'
$Global:PPRoot = $PSScriptRoot
$Global:PPIgnoreSsl = $false

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Cert validation must be a COMPILED callback, not a PowerShell scriptblock: the callback
# fires on a background thread with no runspace, and a scriptblock there throws and breaks
# every HTTPS request. This static class drives the "Ignore SSL errors" toggle thread-safely.
Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class PPCertPolicy {
    public static bool IgnoreErrors = false;
    public static void Install() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                return errors == SslPolicyErrors.None || IgnoreErrors;
            };
    }
}
"@
[PPCertPolicy]::Install()
[PPCertPolicy]::IgnoreErrors = $false

Add-Type -AssemblyName System.Net.Http
if (-not $SelfTest) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# Load the library (order: leaf dependencies first).
$libFiles = @('Model.ps1', 'Json.ps1', 'State.ps1', 'Http.ps1', 'Auth.ps1', 'Vars.ps1', 'Curl.ps1')
if (-not $SelfTest) { $libFiles += @('Ui.Controls.ps1', 'Ui.Env.ps1', 'Ui.Collections.ps1', 'Ui.Code.ps1', 'Ui.Tab.ps1', 'Ui.Send.ps1', 'Ui.Main.ps1') }
foreach ($f in $libFiles) { . (Join-Path $PSScriptRoot "lib\$f") }

function Invoke-PPSelfTest {
    $script:pass = 0; $script:fail = 0
    function Check([string]$name, [bool]$ok, [string]$detail = '') {
        if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
        else { Write-Host "FAIL  $name  $detail" -ForegroundColor Red; $script:fail++ }
    }

    # 1. state round-trip
    $tmp = Join-Path $env:TEMP ('pp_selftest_{0}.json' -f $PID)
    try {
        $s = New-PPState
        $s.tabs[0].url = 'https://example.com/x'
        $s.tabs[0].name = 'RT'
        $s.tabs += (New-PPTab 'Second')
        $envRt = New-PPEnvironment 'Dev'
        $envRt.variables = @( (New-PPKv $true 'host' 'dev.example.com') )
        $s.environments = @($envRt)
        $s.activeEnv = 'Dev'
        $colRt = New-PPCollection 'Smoke'
        $reqRt = New-PPTab 'Ping'
        $reqRt.method = 'POST'; $reqRt.url = 'https://example.com/ping'
        $colRt.requests = @($reqRt)
        $s.collections = @($colRt)
        $s.tabs[0].bodyType = 'multipart'
        $s.tabs[0].multipart = @( (New-PPMultipartRow $true 'avatar' 'file' 'C:\pics\me.png'), (New-PPMultipartRow $true 'note' 'text' 'hi') )
        Save-PPState $s $tmp | Out-Null
        $loaded = Load-PPState $tmp
        Check 'state round-trip' (($loaded.tabs.Count -eq 2) -and ($loaded.tabs[0].url -eq 'https://example.com/x') -and ($loaded.tabs[1].name -eq 'Second')) "tabs=$($loaded.tabs.Count)"
        Check 'env round-trip' (($loaded.environments.Count -eq 1) -and ($loaded.activeEnv -eq 'Dev') -and ($loaded.environments[0].variables[0].value -eq 'dev.example.com')) "envs=$($loaded.environments.Count) active=$($loaded.activeEnv)"
        Check 'collection round-trip' (($loaded.collections.Count -eq 1) -and ($loaded.collections[0].name -eq 'Smoke') -and ($loaded.collections[0].requests[0].method -eq 'POST') -and ($loaded.collections[0].requests[0].url -eq 'https://example.com/ping')) "cols=$($loaded.collections.Count)"
        Check 'multipart round-trip' (($loaded.tabs[0].bodyType -eq 'multipart') -and ($loaded.tabs[0].multipart.Count -eq 2) -and ($loaded.tabs[0].multipart[0].kind -eq 'file') -and ($loaded.tabs[0].multipart[0].value -eq 'C:\pics\me.png')) "mp=$($loaded.tabs[0].multipart.Count)"
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }

    # 2. JSON formatter
    $fmt = Format-PPJson '{"a":1,"b":[1,2]}'
    Check 'json pretty-print' ($fmt -match "`n") 'expected multiline'
    $plain = Format-PPJson 'not json at all'
    Check 'json passthrough' ($plain -eq 'not json at all')

    # 3. PKCE test vector (RFC 7636 Appendix B)
    $challenge = Get-PPCodeChallenge 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
    Check 'PKCE S256 challenge' ($challenge -eq 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM') "got $challenge"

    # 4. environment variable substitution
    $env = New-PPEnvironment 'T'
    $env.variables = @(
        (New-PPKv $true  'host' 'api.example.com'),
        (New-PPKv $true  'ver'  'v2'),
        (New-PPKv $false 'off'  'SHOULD_NOT_APPEAR')
    )
    $map = Get-PPVarMap $env
    Check 'var map skips disabled' (($map.Count -eq 2) -and (-not $map.ContainsKey('off'))) "count=$($map.Count)"
    $expanded = Expand-PPVars 'https://{{host}}/{{ ver }}/x?d={{off}}&m={{nope}}' $map
    Check 'var substitution' ($expanded -eq 'https://api.example.com/v2/x?d={{off}}&m={{nope}}') "got $expanded"

    # 5. cURL import / export
    $sampleCurl = @'
curl -X POST 'https://api.test/v1/users?team=eng' -H 'Accept: application/json' -H 'Content-Type: application/json' -H 'Authorization: Bearer abc123' --data '{"name":"Sam"}'
'@
    $cm = ConvertFrom-PPCurl $sampleCurl
    Check 'curl import method/url' (($cm.method -eq 'POST') -and ($cm.url -eq 'https://api.test/v1/users?team=eng')) "m=$($cm.method) u=$($cm.url)"
    Check 'curl import bearer' (($cm.auth.type -eq 'bearer') -and ($cm.auth.bearerToken -eq 'abc123')) "type=$($cm.auth.type)"
    Check 'curl import body' (($cm.bodyType -eq 'json') -and ($cm.body -match 'Sam')) "bt=$($cm.bodyType)"
    $authHdrCount = @($cm.headers | Where-Object { $_.key -ieq 'Authorization' }).Count
    Check 'curl import strips auth header' ($authHdrCount -eq 0) "count=$authHdrCount"
    $back = ConvertTo-PPCurl $cm @{}
    Check 'curl export' (($back -match 'curl -X POST') -and ($back -match 'Bearer abc123') -and ($back -match 'api\.test/v1/users')) 'export missing parts'
    $ps = ConvertTo-PPPowerShell $cm @{}
    Check 'powershell export' (($ps -match 'Invoke-RestMethod') -and ($ps -match "-Method POST") -and ($ps -match "ContentType 'application/json'")) 'ps export missing parts'

    # 6. multipart cURL import / export
    $mpCurl = ConvertFrom-PPCurl "curl 'https://api.test/upload' -F 'photo=@C:\a\b.png;type=image/png' -F 'name=Sam'"
    $mpFile = @($mpCurl.multipart | Where-Object { $_.kind -eq 'file' })
    Check 'curl -F import' (($mpCurl.bodyType -eq 'multipart') -and ($mpCurl.method -eq 'POST') -and ($mpFile.Count -eq 1) -and ($mpFile[0].value -eq 'C:\a\b.png')) "bt=$($mpCurl.bodyType) parts=$($mpCurl.multipart.Count)"
    $mpOut = ConvertTo-PPCurl $mpCurl @{}
    Check 'curl -F export' (($mpOut -match '-F ') -and ($mpOut -match 'photo=@C:\\a\\b\.png') -and ($mpOut -match 'name=Sam')) 'multipart export missing -F'

    # 7. live HTTP (needs network; reported as FAIL if unreachable)
    try {
        $g = Invoke-PPRequest -Method 'GET' -Url 'https://postman-echo.com/get?ping=1' -TimeoutSec 30
        Check 'HTTP GET 200' ($g.ok -and $g.statusCode -eq 200) "ok=$($g.ok) code=$($g.statusCode) err=$($g.error)"

        $body = '{"hello":"world"}'
        $p = Invoke-PPRequest -Method 'POST' -Url 'https://postman-echo.com/post' -BodyType 'json' -Body $body -TimeoutSec 30
        $echoed = $false
        if ($p.ok) { try { $echoed = (($p.body | ConvertFrom-Json).json.hello -eq 'world') } catch { } }
        Check 'HTTP POST echo' $echoed "ok=$($p.ok) code=$($p.statusCode)"

        $mp = @( @{ enabled = $true; key = 'hello'; kind = 'text'; value = 'world' } )
        $pm = Invoke-PPRequest -Method 'POST' -Url 'https://postman-echo.com/post' -BodyType 'multipart' -Multipart $mp -TimeoutSec 30
        $mpEchoed = $false
        if ($pm.ok) { try { $mpEchoed = (($pm.body | ConvertFrom-Json).form.hello -eq 'world') } catch { } }
        Check 'HTTP multipart POST' $mpEchoed "ok=$($pm.ok) code=$($pm.statusCode)"
    } catch {
        Check 'HTTP live' $false $_.Exception.Message
    }

    Write-Host ""
    Write-Host "Result: $($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
    if ($script:fail -gt 0) { exit 1 }
}

if ($SelfTest) {
    Invoke-PPSelfTest
    return
}

$state = Load-PPState
Start-PowerPost $state
