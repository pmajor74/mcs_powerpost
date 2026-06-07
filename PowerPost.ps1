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
# Avoid "Expect: 100-continue" — large POSTs can otherwise draw an HTTP 417 from some servers.
[System.Net.ServicePointManager]::Expect100Continue = $false

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
$libFiles = @('Model.ps1', 'Json.ps1', 'State.ps1', 'Http.ps1', 'Auth.ps1', 'Vars.ps1', 'Curl.ps1', 'Llm.ps1', 'Import.ps1')
if (-not $SelfTest) { $libFiles += @('Ui.Controls.ps1', 'Ui.Env.ps1', 'Ui.Collections.ps1', 'Ui.Code.ps1', 'Ui.Llm.ps1', 'Ui.Tools.ps1', 'Ui.Tab.ps1', 'Ui.Send.ps1', 'Ui.Main.ps1') }
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
        $reqRt.method = 'POST'; $reqRt.url = 'https://example.com/ping'; $reqRt.auth.type = 'inherit'
        $colRt.requests = @($reqRt)
        $colRt.auth.type = 'bearer'; $colRt.auth.bearerToken = 'COL-TOKEN'
        $s.collections = @($colRt)
        $s.tabs[0].bodyType = 'multipart'
        $s.tabs[0].multipart = @( (New-PPMultipartRow $true 'avatar' 'file' 'C:\pics\me.png'), (New-PPMultipartRow $true 'note' 'text' 'hi') )
        $s.tabs[1].bodyType = 'graphql'; $s.tabs[1].body = '{ me { id } }'; $s.tabs[1].graphqlVars = '{"x":1}'
        $lt = New-PPLlmTab 'OCR chat'
        $lt.provider = 'Vertex AI'; $lt.model = 'gemini-2.5-pro'; $lt.system = 'be terse'; $lt.thinking = 'High'
        $lt.attachments = @('C:\pending\p.png')
        $lt.conversation = @( @{ role = 'user'; text = 'hello'; images = @('C:\x\a.png') }, @{ role = 'assistant'; text = 'hi'; images = @() } )
        $s.llm.tabs = @($lt)
        $s.llm.activeTab = 0
        $s.followRedirects = $false; $s.proxy = 'http://proxy.local:8080'
        $s.cookiesEnabled = $false
        $s.cookies = @( @{ name = 'sid'; value = 'abc123'; domain = 'example.com'; path = '/'; expires = ''; secure = $true; httpOnly = $true } )
        $he = New-PPHistoryEntry; $he.method = 'POST'; $he.url = 'https://h/x'; $he.statusCode = 201; $he.ok = $true
        $he.request = (New-PPTab 'Hist'); $he.request.url = 'https://h/x'
        $s.history = @($he)
        Save-PPState $s $tmp | Out-Null
        $loaded = Load-PPState $tmp
        Check 'state round-trip' (($loaded.tabs.Count -eq 2) -and ($loaded.tabs[0].url -eq 'https://example.com/x') -and ($loaded.tabs[1].name -eq 'Second')) "tabs=$($loaded.tabs.Count)"
        Check 'env round-trip' (($loaded.environments.Count -eq 1) -and ($loaded.activeEnv -eq 'Dev') -and ($loaded.environments[0].variables[0].value -eq 'dev.example.com')) "envs=$($loaded.environments.Count) active=$($loaded.activeEnv)"
        Check 'collection round-trip' (($loaded.collections.Count -eq 1) -and ($loaded.collections[0].name -eq 'Smoke') -and ($loaded.collections[0].requests[0].method -eq 'POST') -and ($loaded.collections[0].requests[0].url -eq 'https://example.com/ping')) "cols=$($loaded.collections.Count)"
        Check 'collection auth round-trip' (($loaded.collections[0].auth.type -eq 'bearer') -and ($loaded.collections[0].auth.bearerToken -eq 'COL-TOKEN') -and ($loaded.collections[0].requests[0].auth.type -eq 'inherit')) "cAuth=$($loaded.collections[0].auth.type)"
        Check 'multipart round-trip' (($loaded.tabs[0].bodyType -eq 'multipart') -and ($loaded.tabs[0].multipart.Count -eq 2) -and ($loaded.tabs[0].multipart[0].kind -eq 'file') -and ($loaded.tabs[0].multipart[0].value -eq 'C:\pics\me.png')) "mp=$($loaded.tabs[0].multipart.Count)"
        Check 'graphql round-trip' (($loaded.tabs[1].bodyType -eq 'graphql') -and ($loaded.tabs[1].body -eq '{ me { id } }') -and ($loaded.tabs[1].graphqlVars -eq '{"x":1}')) "bt=$($loaded.tabs[1].bodyType)"
        Check 'llm tab round-trip' (($loaded.llm.tabs.Count -eq 1) -and ($loaded.llm.tabs[0].name -eq 'OCR chat') -and ($loaded.llm.tabs[0].model -eq 'gemini-2.5-pro') -and ($loaded.llm.tabs[0].conversation.Count -eq 2) -and ($loaded.llm.tabs[0].conversation[0].images[0] -eq 'C:\x\a.png')) "tabs=$($loaded.llm.tabs.Count) conv=$($loaded.llm.tabs[0].conversation.Count)"
        Check 'llm tab attachments+thinking' (($loaded.llm.tabs[0].thinking -eq 'High') -and ($loaded.llm.tabs[0].attachments.Count -eq 1) -and ($loaded.llm.tabs[0].attachments[0] -eq 'C:\pending\p.png')) "think=$($loaded.llm.tabs[0].thinking) att=$($loaded.llm.tabs[0].attachments.Count)"
        Check 'settings round-trip' (($loaded.followRedirects -eq $false) -and ($loaded.proxy -eq 'http://proxy.local:8080') -and ($loaded.cookiesEnabled -eq $false)) "follow=$($loaded.followRedirects) proxy=$($loaded.proxy)"
        Check 'cookies round-trip' (($loaded.cookies.Count -eq 1) -and ($loaded.cookies[0].name -eq 'sid') -and ($loaded.cookies[0].domain -eq 'example.com') -and ($loaded.cookies[0].secure -eq $true)) "cookies=$($loaded.cookies.Count)"
        Check 'history round-trip' (($loaded.history.Count -eq 1) -and ($loaded.history[0].statusCode -eq 201) -and ($loaded.history[0].request.url -eq 'https://h/x')) "hist=$($loaded.history.Count)"
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

    # 7. LLM adapters (pure; no network)
    $llmMsgs = @( @{ role = 'user'; text = 'hi'; images = @() } )
    $oai = Build-PPLlmBody 'openai' 'gpt-4o' 'You are terse.' $llmMsgs @{ maxTokens = 256 }
    Check 'llm openai body' (($oai.urlSuffix -eq '/chat/completions') -and ($oai.body -match '"model"\s*:\s*"gpt-4o"') -and ($oai.body -match 'terse')) "suffix=$($oai.urlSuffix)"
    $ant = Build-PPLlmBody 'anthropic' 'claude-opus-4-8' 'sys' $llmMsgs @{}
    Check 'llm anthropic body' (($ant.urlSuffix -eq '/messages') -and ($ant.body -match 'max_tokens') -and ($ant.body -match 'claude-opus-4-8')) "suffix=$($ant.urlSuffix)"
    $gem = Build-PPLlmBody 'gemini' 'gemini-2.0-flash' '' $llmMsgs @{}
    Check 'llm gemini body' (($gem.urlSuffix -eq '/models/gemini-2.0-flash:generateContent') -and ($gem.body -match 'contents')) "suffix=$($gem.urlSuffix)"
    $g3 = Build-PPLlmBody 'gemini' 'gemini-3.1-pro-preview' '' $llmMsgs @{ thinking = 'High' }
    Check 'llm gemini-3 thinkingLevel' (($g3.body -match 'thinkingLevel') -and ($g3.body -match '"high"') -and ($g3.body -notmatch 'thinkingBudget')) 'gemini-3 thinking'
    $g25 = Build-PPLlmBody 'gemini' 'gemini-2.5-pro' '' $llmMsgs @{ thinking = 'Low' }
    Check 'llm gemini-2.5 thinkingBudget' (($g25.body -match 'thinkingBudget') -and ($g25.body -notmatch 'thinkingLevel')) 'gemini-2.5 thinking'
    $antOff = Build-PPLlmBody 'anthropic' 'claude-opus-4-8' '' $llmMsgs @{ thinking = 'Off' }
    Check 'llm anthropic thinking off' ($antOff.body -match 'disabled') 'anthropic off'
    $antHi = Build-PPLlmBody 'anthropic' 'claude-opus-4-8' '' $llmMsgs @{ thinking = 'Medium' }
    Check 'llm anthropic effort' (($antHi.body -match 'adaptive') -and ($antHi.body -match 'effort') -and ($antHi.body -match 'medium')) 'anthropic effort'
    Check 'llm effective thinking g3' ((Get-PPLlmEffectiveThinking 'gemini-3.1-pro-preview' 'gemini') -eq 'high') 'g3 eff'
    Check 'llm lowest thinking g3' ((Get-PPLlmLowestThinking 'gemini-3.1-pro-preview' 'gemini') -eq 'Low') 'g3 low'
    Check 'llm lowest thinking 2.5 flash' ((Get-PPLlmLowestThinking 'gemini-2.5-flash' 'gemini') -eq 'Off') 'g25flash low'
    Check 'llm lowest thinking 2.5 pro' ((Get-PPLlmLowestThinking 'gemini-2.5-pro' 'gemini') -eq 'Low') 'g25pro low'
    Check 'llm effective thinking anthropic' ((Get-PPLlmEffectiveThinking 'claude-opus-4-8' 'anthropic') -eq 'off') 'ant eff'

    $pBear = New-PPLlmProvider 'P' 'openai' 'bearer' 'https://x' 'gpt-4o' @() 'KEY123'
    $hb = Resolve-PPLlmAuthHeaders $pBear
    $authVal = (@($hb.headers | Where-Object { $_.key -eq 'Authorization' })[0]).value
    Check 'llm auth bearer' ($hb.ok -and ($authVal -eq 'Bearer KEY123')) "val=$authVal"
    $pAnt = New-PPLlmProvider 'A' 'anthropic' 'anthropic' 'https://x' 'm' @() 'AK'
    $ha = Resolve-PPLlmAuthHeaders $pAnt
    $hasVer = @($ha.headers | Where-Object { $_.key -eq 'anthropic-version' }).Count -eq 1
    $hasKey = (@($ha.headers | Where-Object { $_.key -eq 'x-api-key' })[0]).value -eq 'AK'
    Check 'llm auth anthropic' ($hasVer -and $hasKey) "ver=$hasVer key=$hasKey"

    $sample = '{"choices":[{"message":{"content":"hello world"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}'
    $ro = Read-PPLlmResponse 'openai' @{ ok = $true; statusCode = 200; body = $sample }
    Check 'llm parse openai' ($ro.ok -and ($ro.text -eq 'hello world')) "text=$($ro.text)"
    $asample = '{"content":[{"type":"text","text":"hi there"}],"usage":{"input_tokens":4,"output_tokens":2}}'
    $ra = Read-PPLlmResponse 'anthropic' @{ ok = $true; statusCode = 200; body = $asample }
    Check 'llm parse anthropic' ($ra.ok -and ($ra.text -eq 'hi there')) "text=$($ra.text)"
    $gsample = '{"candidates":[{"content":{"parts":[{"text":"gem out"}]}}]}'
    $rg = Read-PPLlmResponse 'gemini' @{ ok = $true; statusCode = 200; body = $gsample }
    Check 'llm parse gemini' ($rg.ok -and ($rg.text -eq 'gem out')) "text=$($rg.text)"
    $gMax = '{"candidates":[{"content":{"role":"model"},"finishReason":"MAX_TOKENS"}],"usageMetadata":{}}'
    $rgm = Read-PPLlmResponse 'gemini' @{ ok = $true; statusCode = 200; body = $gMax }
    Check 'llm empty-text note' ($rgm.ok -and ($rgm.text -match 'MAX_TOKENS') -and ($rgm.finishReason -eq 'MAX_TOKENS')) "text=$($rgm.text)"
    $rerr = Read-PPLlmResponse 'openai' @{ ok = $true; statusCode = 401; body = '{"error":"bad key"}' }
    Check 'llm parse error' (-not $rerr.ok) "ok=$($rerr.ok)"

    # 8. Vertex JWT signing (throwaway test RSA key embedded below; no network, no real creds)
    $testPem = @'
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnolMNfA92jqp6
7m9hsyofXn5BmfVOunwC9/MHT2bI1JLvDVZOg5TBdTssmSZbN5dQiJ0XI1BHgS5E
KX2V+WwcrgTxZDaHLu0YvJ/4RSHHuqrNxX95N1SBKPEAhzWo9gG8GeCbRY82KG/0
82yvuiSikbhCCFu8pdp9CctJll5eJbTQGuX/1oAkbYc69p4IuWE3GWP8mUd3F2mt
8R1vwZQqZPwbcVTZBHSfGiKGT0qh2QA/Y0OqWgwxjmKCxXjBQmUn45//qnrG4okj
lVjZSKo5qpjuCSjjP64Zo9BRDxqELS2B0DucbCFo1LOnxXRX7ynId3PO4UmAw0VX
eaV6FMgnAgMBAAECggEAI8+tH23X3dN3fwCN4djFEGN+5GPQAGwdTwMKM48WXaPv
6cq3G9nHPxbct9fV1lnHZQhySr2cClKCAES+0/mvS2cvniPy9CkltImjQQX/w+vQ
Tlo5M7uKvXbyGVNJNtmrIDSFA5a2E/NKi5EvMFE7P1GTA+RGOMRTqy+a8pMBgOoD
JUHjrQ8sGnKBppt8mmWXpdnKXm5gme+9jARHsywXMfqOkfR8IRWgKLaYgwJg9ei0
EwqaKDfb0ltqf9bMPs8Wg7DLDGXmr7tnEiTOYcJKESJ5FUgPIQZRn1xxqWStDAXw
aVKrGup4KUtdxAKumds4W5FJeaXUk5W69Xvhc1ldMQKBgQDn91iBgZk7IqmcIdSA
AncmMcW2n9LQbmClwh4sQI21F2RJ4x3RIMqEtzAEJWHKMh/02K/eiR07EUCcYV3j
cw9OUJIjHjQwOnEJitMB29XXWOIpBT5nY+iDzpjLOOV3jIu1JqOa8RI5tXZojSIM
BuP29Of5megKh0g5SW+xMqIMkQKBgQC5AKNv6b/GtbTi4IB95Si/3zjP+ypDpbQF
2jf45swwONkis0rRhXQD4qJ27A+O5QcTiu3sAPR6/+X450e1+ENIrAN/ZoqrGbZM
sLSnKOGuG7JanJrODsdStX9ZWtxBW6Z46Lev03xMQSjKSb3YfE85ZQZNU9L2TVbn
5r9J0lFFNwKBgAoQDdPYZmhNUaRHR2uiL78Fa7lHZ6LJFwI50ItE5aDUefJGmvWG
gaKOO9QCNyLJV9+MQtzZf94fGnluM995D1HrZtuFJOhusJakYhDzk2w7G9yBsLpV
eDG3laNDPZkZDLp4CaLgEFVWjONuM+rnpZ4B88o9JfbG9ZgemmzKcIMxAoGBAJfE
0k+JL27Qumg1TLP7PwbJFU5p+i4szhbPAoQKsxAMUvWIqKRiGt7lGer9lXXgpYF+
w9iMoAQX0o3zDn1WAbyogOYPNUtQeKFJhapse1feGN8FAmpw7UwI4URoqbBkg5lF
MQvpL1tPSStKe5gRwtyO6DCfx72PjPAJ+HuTMmDZAoGAUmI54rHLiPY+7jiy8tb3
M+Pkvxw6C6TAFQOhMf91bd/JN/OUIgh2ZjYhZhxZbIUNe1TJKdry7WM27LJ7E5SV
1xz+YZLEVyx7xdbttBsUP9ampTm/j5WCR34oTihL37tT2m+oN9KCXkZXw6N44lkR
59cQI/7AAxkKGjDQqDwMu88=
-----END PRIVATE KEY-----
'@
    try {
        $jwt = [PPVertexAuth]::MakeJwt('svc@example.iam.gserviceaccount.com', $testPem, 'https://oauth2.googleapis.com/token', 'https://www.googleapis.com/auth/cloud-platform', 1700000000, 1700003600)
        $parts = $jwt -split '\.'
        $ok = [PPVertexAuth]::VerifyJwt($testPem, $jwt)
        Check 'vertex JWT RS256' (($parts.Count -eq 3) -and $ok) "parts=$($parts.Count) ok=$ok"
    } catch { Check 'vertex JWT RS256' $false $_.Exception.Message }

    # 9. provider file import (owner's Vertex schema)
    $provFile = '[{"Name":"Vertex Pro","Provider":"VertexAI","Model":"gemini-2.5-pro","Endpoint":"https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google","ClientEmail":"svc@p.iam.gserviceaccount.com","PrivateKey":"-----BEGIN PRIVATE KEY-----\nABC\n-----END PRIVATE KEY-----\n","MaxRetries":8}]'
    $imp = ConvertFrom-PPProviderFile $provFile
    Check 'provider file import' ((@($imp).Count -eq 1) -and ($imp[0].dialect -eq 'gemini') -and ($imp[0].auth -eq 'vertex') -and ($imp[0].model -eq 'gemini-2.5-pro') -and ($imp[0].clientEmail -eq 'svc@p.iam.gserviceaccount.com')) "dialect=$($imp[0].dialect) auth=$($imp[0].auth)"
    $multiVx = '[{"Provider":"VertexAI","Model":"gemini-2.5-pro","Endpoint":"https://e/publishers/google","ClientEmail":"svc@x","PrivateKey":"k"},{"Provider":"VertexAI","Model":"gemini-3.1-pro-preview","Endpoint":"https://e/publishers/google","ClientEmail":"svc@x","PrivateKey":"k"}]'
    $cons = ConvertFrom-PPProviderFile $multiVx
    Check 'provider file consolidates vertex' ((@($cons).Count -eq 1) -and ($cons[0].name -eq 'Google Vertex') -and (@($cons[0].models).Count -eq 2) -and ($cons[0].auth -eq 'vertex')) "count=$(@($cons).Count) models=$(@($cons[0].models).Count)"

    # 10. cookie jar export/import + enumeration (no network)
    $cj = New-Object System.Net.CookieContainer
    $cj.Add((New-Object System.Net.Cookie('sid', 'abc', '/', 'example.com')))
    $cj.Add((New-Object System.Net.Cookie('tok', 'xyz', '/api', 'example.com')))
    $exp = Export-PPCookies $cj
    $cj2 = New-Object System.Net.CookieContainer
    Import-PPCookies $cj2 $exp
    $all2 = Get-PPAllCookies $cj2
    Check 'cookie export/import' ((@($exp).Count -eq 2) -and (@($all2).Count -eq 2) -and (@($all2 | Where-Object { $_.Name -eq 'sid' -and $_.Value -eq 'abc' }).Count -eq 1)) "exp=$(@($exp).Count) imp=$(@($all2).Count)"

    # 11c. bulk-edit text <-> KV rows
    $kvRows = @( (New-PPKv $true 'Accept' 'application/json'), (New-PPKv $false 'X-Debug' '1'), (New-PPKv $true 'Authorization' 'Bearer abc') )
    $kvText = ConvertTo-PPKvText $kvRows
    Check 'kv to text' (($kvText -match 'Accept: application/json') -and ($kvText -match '//X-Debug: 1')) "text=$kvText"
    $back = ConvertFrom-PPKvText $kvText
    Check 'kv from text' ((@($back).Count -eq 3) -and ($back[0].enabled) -and (-not $back[1].enabled) -and ($back[1].key -eq 'X-Debug') -and ($back[2].value -eq 'Bearer abc')) "n=$(@($back).Count)"

    # 11a. collection-level inherited auth
    $colA = New-PPCollection 'C'; $colA.auth.type = 'bearer'; $colA.auth.bearerToken = 'INHERITED'
    $reqI = New-PPTab 'r'; $reqI.auth.type = 'inherit'
    $eff = Resolve-PPInheritedAuth $reqI.auth $colA.auth
    Check 'inherited auth resolves' (($eff.type -eq 'bearer') -and ($eff.bearerToken -eq 'INHERITED')) "type=$($eff.type)"
    $reqOwn = New-PPTab 'r2'; $reqOwn.auth.type = 'basic'; $reqOwn.auth.basicUser = 'me'
    $eff2 = Resolve-PPInheritedAuth $reqOwn.auth $colA.auth
    Check 'own auth kept' (($eff2.type -eq 'basic') -and ($eff2.basicUser -eq 'me')) "type=$($eff2.type)"
    $inh = Resolve-PPAuthHeaders @{ type = 'inherit'; accessToken = ''; tokenExpiry = '' }
    Check 'inherit -> no headers' ($inh.ok -and (@($inh.headers).Count -eq 0)) "hdrs=$(@($inh.headers).Count)"

    # 11b. GraphQL body builder + cURL export
    $gqlBody = ConvertTo-PPGraphQLBody '{ user { id } }' '{"id":5}'
    $gqlObj = $gqlBody | ConvertFrom-Json
    Check 'graphql body builder' (($gqlObj.query -eq '{ user { id } }') -and ($gqlObj.variables.id -eq 5)) "body=$gqlBody"
    $gqlBadVars = ConvertTo-PPGraphQLBody '{ x }' 'not json'
    Check 'graphql bad vars -> {}' ($gqlBadVars -match '"variables":\s*\{\}') "got $gqlBadVars"
    $gqlTab = New-PPTab 'g'; $gqlTab.method = 'POST'; $gqlTab.url = 'https://api/graphql'; $gqlTab.bodyType = 'graphql'; $gqlTab.body = '{ ping }'; $gqlTab.graphqlVars = '{"a":1}'
    $gqlCurl = ConvertTo-PPCurl $gqlTab @{}
    Check 'graphql curl export' (($gqlCurl -match 'application/json') -and ($gqlCurl -match '\\"query\\"' -or $gqlCurl -match 'query') -and ($gqlCurl -match 'ping')) 'gql curl'

    # 11. collection import (OpenAPI 3 / Swagger 2 / Postman) — no network
    $oapi = @'
{ "openapi": "3.0.0", "info": { "title": "Demo API" },
  "servers": [ { "url": "https://api.demo.test/v1" } ],
  "paths": {
    "/users": {
      "get": { "operationId": "listUsers", "parameters": [ { "name": "limit", "in": "query" }, { "name": "X-Trace", "in": "header" } ] },
      "post": { "operationId": "createUser",
        "requestBody": { "content": { "application/json": { "schema": { "type": "object", "properties": { "name": { "type": "string" }, "age": { "type": "integer" } } } } } } }
    }
  } }
'@
    $oc = ConvertFrom-PPApiSpec $oapi
    $post = @($oc.requests | Where-Object { $_.method -eq 'POST' })[0]
    Check 'import openapi3' (($oc.name -eq 'Demo API') -and (@($oc.requests).Count -eq 2) -and ($post.url -eq 'https://api.demo.test/v1/users') -and ($post.bodyType -eq 'json') -and ($post.body -match 'name')) "reqs=$(@($oc.requests).Count) url=$($post.url)"

    $sw2 = '{ "swagger": "2.0", "host": "h.test", "basePath": "/api", "schemes": ["https"], "info": {"title":"S2"}, "paths": { "/ping": { "get": { "operationId": "ping" } } } }'
    $sc = ConvertFrom-PPApiSpec $sw2
    Check 'import swagger2' ((@($sc.requests).Count -eq 1) -and ($sc.requests[0].url -eq 'https://h.test/api/ping')) "url=$($sc.requests[0].url)"

    $pm = @'
{ "info": { "name": "PM Coll" },
  "item": [
    { "name": "Folder", "item": [
      { "name": "Get thing", "request": { "method": "GET", "url": { "raw": "https://x.test/thing?id=1" },
        "header": [ { "key": "Accept", "value": "application/json" } ] } },
      { "name": "Make thing", "request": { "method": "POST", "url": "https://x.test/thing",
        "body": { "mode": "raw", "raw": "{\"a\":1}", "options": { "raw": { "language": "json" } } },
        "auth": { "type": "bearer", "bearer": [ { "key": "token", "value": "T0K" } ] } } }
    ] }
  ] }
'@
    $pc = ConvertFrom-PPApiSpec $pm
    $mk = @($pc.requests | Where-Object { $_.method -eq 'POST' })[0]
    Check 'import postman' (($pc.name -eq 'PM Coll') -and (@($pc.requests).Count -eq 2) -and ($pc.requests[0].name -match 'Folder') -and ($mk.bodyType -eq 'json') -and ($mk.auth.type -eq 'bearer') -and ($mk.auth.bearerToken -eq 'T0K')) "reqs=$(@($pc.requests).Count)"

    # 12. live HTTP (needs network; reported as FAIL if unreachable)
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

        $jar = New-Object System.Net.CookieContainer
        $cset = Invoke-PPRequest -Method 'GET' -Url 'https://postman-echo.com/cookies/set?ppjar=works' -CookieContainer $jar -TimeoutSec 30
        $jarOk = (@(Get-PPAllCookies $jar | Where-Object { $_.Name -eq 'ppjar' -and $_.Value -eq 'works' }).Count -eq 1)
        Check 'HTTP cookie jar' $jarOk "ok=$($cset.ok) cookies=$(@(Get-PPAllCookies $jar).Count)"

        $gq = Invoke-PPRequest -Method 'POST' -Url 'https://postman-echo.com/post' -BodyType 'graphql' -Body '{ hello }' -GraphQLVariables '{"n":7}' -TimeoutSec 30
        $gqOk = $false
        if ($gq.ok) { try { $j = ($gq.body | ConvertFrom-Json).json; $gqOk = (($j.query -eq '{ hello }') -and ($j.variables.n -eq 7)) } catch { } }
        Check 'HTTP graphql POST' $gqOk "ok=$($gq.ok) code=$($gq.statusCode)"
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
