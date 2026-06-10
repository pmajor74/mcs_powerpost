# Auth.ps1 — turn an auth config into request headers, plus OAuth2 token acquisition.

function ConvertTo-PPBase64Url {
    param([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-PPCodeVerifier {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (ConvertTo-PPBase64Url $bytes)
}

function Get-PPCodeChallenge {
    param([string]$Verifier)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Verifier))
    } finally { $sha.Dispose() }
    return (ConvertTo-PPBase64Url $hash)
}

function Test-PPTokenValid {
    param($Auth)
    if ([string]::IsNullOrEmpty($Auth.accessToken)) { return $false }
    if ([string]::IsNullOrEmpty($Auth.tokenExpiry)) { return $true }  # no known expiry -> assume good
    try {
        $exp = [DateTime]::Parse($Auth.tokenExpiry, $null,
            ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
        return ((Get-Date).ToUniversalTime() -lt $exp)
    } catch { return $true }
}

# Parse a token endpoint response, store access_token + computed expiry on $Auth.
function Set-PPTokenFromResponse {
    param($Auth, $Resp)
    if (-not $Resp.ok) { return @{ ok = $false; error = $Resp.error } }
    if ($Resp.statusCode -ge 400) { return @{ ok = $false; error = "HTTP $($Resp.statusCode): $($Resp.body)" } }
    try { $data = $Resp.body | ConvertFrom-Json -ErrorAction Stop } catch { return @{ ok = $false; error = "Token response was not JSON: $($Resp.body)" } }
    $token = [string](Get-PPProp $data 'access_token' '')
    if ([string]::IsNullOrEmpty($token)) { return @{ ok = $false; error = "No access_token in response: $($Resp.body)" } }
    $Auth.accessToken = $token
    $exp = Get-PPProp $data 'expires_in' $null
    if ($null -ne $exp) {
        $Auth.tokenExpiry = ((Get-Date).ToUniversalTime().AddSeconds([int]$exp - 30)).ToString('o')
    } else {
        $Auth.tokenExpiry = ''
    }
    return @{ ok = $true; token = $token }
}

function Get-PPClientCredentialsToken {
    param($Auth, [int]$TimeoutSec = 100)
    if ([string]::IsNullOrEmpty($Auth.tokenUrl)) { return @{ ok = $false; error = 'Token URL is empty.' } }
    $form = @( (New-PPKv $true 'grant_type' 'client_credentials') )
    if ($Auth.scope) { $form += (New-PPKv $true 'scope' $Auth.scope) }
    $headers = @()
    if ($Auth.clientAuthStyle -eq 'header') {
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Auth.clientId):$($Auth.clientSecret)"))
        $headers += @{ key = 'Authorization'; value = "Basic $basic" }
    } else {
        $form += (New-PPKv $true 'client_id' $Auth.clientId)
        $form += (New-PPKv $true 'client_secret' $Auth.clientSecret)
    }
    $resp = Invoke-PPRequest -Method 'POST' -Url $Auth.tokenUrl -AuthHeaders $headers -BodyType 'form' -Form $form -TimeoutSec $TimeoutSec
    return (Set-PPTokenFromResponse $Auth $resp)
}

# Authorization-code flow (+ optional PKCE). Blocks until the browser redirects or times out.
function Get-PPAuthCodeToken {
    param($Auth, [int]$TimeoutSec = 100)
    if ([string]::IsNullOrEmpty($Auth.authUrl))  { return @{ ok = $false; error = 'Authorize URL is empty.' } }
    if ([string]::IsNullOrEmpty($Auth.tokenUrl)) { return @{ ok = $false; error = 'Token URL is empty.' } }

    $port = [int]$Auth.redirectPort
    $redirect = "http://localhost:$port/"
    $stateVal = (New-PPCodeVerifier)
    $verifier = $null
    $challenge = $null

    $q = @(
        'response_type=code',
        ('client_id=' + [Uri]::EscapeDataString($Auth.clientId)),
        ('redirect_uri=' + [Uri]::EscapeDataString($redirect)),
        ('state=' + [Uri]::EscapeDataString($stateVal))
    )
    if ($Auth.scope) { $q += ('scope=' + [Uri]::EscapeDataString($Auth.scope)) }
    if ($Auth.usePkce) {
        $verifier = New-PPCodeVerifier
        $challenge = Get-PPCodeChallenge $verifier
        $q += "code_challenge=$challenge"
        $q += 'code_challenge_method=S256'
    }
    $sep = '?'; if ($Auth.authUrl -match '\?') { $sep = '&' }
    $authorizeUrl = $Auth.authUrl + $sep + ($q -join '&')

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($redirect)
    try { $listener.Start() } catch { return @{ ok = $false; error = "Cannot listen on $redirect - $($_.Exception.Message)" } }

    try {
        Start-Process $authorizeUrl | Out-Null
        $ctxTask = $listener.GetContextAsync()
        if (-not $ctxTask.Wait([TimeSpan]::FromSeconds(180))) {
            return @{ ok = $false; error = 'Timed out waiting for the browser redirect (180s).' }
        }
        $ctx = $ctxTask.Result
        $code      = $ctx.Request.QueryString['code']
        $retState  = $ctx.Request.QueryString['state']
        $errParam  = $ctx.Request.QueryString['error']

        $html = "<html><body style='font-family:Segoe UI,sans-serif;padding:2em'><h2>PowerPost</h2><p>Authentication complete. You can close this tab and return to PowerPost.</p></body></html>"
        $buf = [Text.Encoding]::UTF8.GetBytes($html)
        $ctx.Response.ContentType = 'text/html'
        $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
        $ctx.Response.OutputStream.Close()
    } finally {
        $listener.Stop()
        $listener.Close()
    }

    if ($errParam)            { return @{ ok = $false; error = "Authorization error: $errParam" } }
    if ($retState -ne $stateVal) { return @{ ok = $false; error = 'State mismatch (possible CSRF); aborted.' } }
    if ([string]::IsNullOrEmpty($code)) { return @{ ok = $false; error = 'No authorization code was returned.' } }

    $form = @(
        (New-PPKv $true 'grant_type' 'authorization_code'),
        (New-PPKv $true 'code' $code),
        (New-PPKv $true 'redirect_uri' $redirect),
        (New-PPKv $true 'client_id' $Auth.clientId)
    )
    if ($Auth.usePkce)      { $form += (New-PPKv $true 'code_verifier' $verifier) }
    if ($Auth.clientSecret) { $form += (New-PPKv $true 'client_secret' $Auth.clientSecret) }

    $resp = Invoke-PPRequest -Method 'POST' -Url $Auth.tokenUrl -BodyType 'form' -Form $form -TimeoutSec $TimeoutSec
    return (Set-PPTokenFromResponse $Auth $resp)
}

# Build the Authorization header(s) to attach to an outgoing request.
# For client-credentials, auto-fetches/refreshes the token when missing or expired.
function Resolve-PPAuthHeaders {
    param($Auth, [int]$TimeoutSec = 100)
    switch ($Auth.type) {
        'bearer' {
            if ($Auth.bearerToken) { return @{ ok = $true; headers = @(@{ key = 'Authorization'; value = "Bearer $($Auth.bearerToken)" }) } }
            return @{ ok = $true; headers = @() }
        }
        'basic' {
            $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Auth.basicUser):$($Auth.basicPass)"))
            return @{ ok = $true; headers = @(@{ key = 'Authorization'; value = "Basic $b" }) }
        }
        'clientcreds' {
            if (-not (Test-PPTokenValid $Auth)) {
                $r = Get-PPClientCredentialsToken $Auth $TimeoutSec
                if (-not $r.ok) { return @{ ok = $false; error = $r.error; headers = @() } }
            }
            return @{ ok = $true; headers = @(@{ key = 'Authorization'; value = "Bearer $($Auth.accessToken)" }) }
        }
        'authcode' {
            if ([string]::IsNullOrEmpty($Auth.accessToken)) {
                return @{ ok = $false; error = "No token yet - click 'Get Token' in the Auth tab."; headers = @() }
            }
            return @{ ok = $true; headers = @(@{ key = 'Authorization'; value = "Bearer $($Auth.accessToken)" }) }
        }
        'vertex' {
            # Google service account: RS256-sign a JWT, exchange it for a cloud-platform token.
            # Get-PPVertexToken (Llm.ps1) caches accessToken/tokenExpiry on $Auth, like clientcreds.
            if (-not (Test-PPTokenValid $Auth)) {
                $r = Get-PPVertexToken $Auth $TimeoutSec
                if (-not $r.ok) { return @{ ok = $false; error = $r.error; headers = @() } }
            }
            return @{ ok = $true; headers = @(@{ key = 'Authorization'; value = "Bearer $($Auth.accessToken)" }) }
        }
        'inherit' {
            # Resolved to the collection's auth when opened from a collection; standalone -> none.
            return @{ ok = $true; headers = @() }
        }
        default { return @{ ok = $true; headers = @() } }
    }
}
