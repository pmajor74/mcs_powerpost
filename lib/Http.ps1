# Http.ps1 — execute a request via System.Net.Http.HttpClient.
# HttpClient (unlike Invoke-WebRequest) returns 4xx/5xx responses normally instead of
# throwing, which is exactly what an API tester wants.

# Append enabled key/value rows to a URL as query-string parameters.
function Build-PPUrl {
    param([string]$Url, $Params)
    $pairs = @()
    foreach ($p in @($Params)) {
        if ($null -eq $p) { continue }
        if (-not $p.enabled) { continue }
        if ([string]::IsNullOrEmpty([string]$p.key)) { continue }
        $k = [System.Uri]::EscapeDataString([string]$p.key)
        $v = [System.Uri]::EscapeDataString([string]$p.value)
        $pairs += "$k=$v"
    }
    if ($pairs.Count -eq 0) { return $Url }
    $sep = '?'
    if ($Url -match '\?') { $sep = '&' }
    return ($Url + $sep + ($pairs -join '&'))
}

# Build an x-www-form-urlencoded string from enabled rows.
function ConvertTo-PPFormBody {
    param($Form)
    $pairs = @()
    foreach ($p in @($Form)) {
        if ($null -eq $p) { continue }
        if (-not $p.enabled) { continue }
        if ([string]::IsNullOrEmpty([string]$p.key)) { continue }
        $k = [System.Uri]::EscapeDataString([string]$p.key)
        $v = [System.Uri]::EscapeDataString([string]$p.value)
        $pairs += "$k=$v"
    }
    return ($pairs -join '&')
}

# Build a GraphQL POST body: {"query": <query>, "variables": <json>}.
# Variables text is embedded raw if it's valid JSON, else replaced with {}.
function ConvertTo-PPGraphQLBody {
    param([string]$Query, [string]$Variables)
    $vars = $Variables
    if ([string]::IsNullOrWhiteSpace($vars)) { $vars = '{}' }
    else { try { $null = $vars | ConvertFrom-Json -ErrorAction Stop } catch { $vars = '{}' } }
    $qJson = ([string]$Query | ConvertTo-Json)   # JSON-encodes the query (quotes, newlines)
    return '{"query":' + $qJson + ',"variables":' + $vars + '}'
}

function Invoke-PPRequest {
    param(
        [string]$Method = 'GET',
        [string]$Url,
        $Headers   = @(),     # array of @{enabled;key;value}
        $AuthHeaders = @(),   # array of @{key;value} from Resolve-PPAuthHeaders
        [string]$BodyType = 'none',
        [string]$Body = '',
        $Form = @(),
        $Multipart = @(),
        [int]$TimeoutSec = 100,
        [bool]$FollowRedirects = $true,
        [string]$Proxy = '',
        $CookieContainer = $null,
        [string]$GraphQLVariables = ''
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    $handler = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $FollowRedirects
        if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
            $handler.Proxy = New-Object System.Net.WebProxy($Proxy, $true)
            $handler.UseProxy = $true
        }
        if ($null -ne $CookieContainer) {
            $handler.CookieContainer = $CookieContainer   # shared jar -> cookies persist across requests
            $handler.UseCookies = $true
        }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSec))

        $verb = $Method.ToUpper()
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]$verb, $Url)
        # Don't send "Expect: 100-continue" — some servers/proxies (e.g. Google's frontend)
        # reject it with HTTP 417 on large POST bodies (such as a base64 image).
        $req.Headers.ExpectContinue = $false

        # Build content (body) first so we can attach content-type headers correctly.
        $content = $null
        if ($verb -ne 'GET' -and $verb -ne 'HEAD') {
            switch ($BodyType) {
                'json' {
                    if (-not [string]::IsNullOrEmpty($Body)) {
                        $content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
                    }
                }
                'text' {
                    if (-not [string]::IsNullOrEmpty($Body)) {
                        $content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'text/plain')
                    }
                }
                'graphql' {
                    $gb = ConvertTo-PPGraphQLBody $Body $GraphQLVariables
                    $content = New-Object System.Net.Http.StringContent($gb, [System.Text.Encoding]::UTF8, 'application/json')
                }
                'form' {
                    $fb = ConvertTo-PPFormBody $Form
                    $content = New-Object System.Net.Http.StringContent($fb, [System.Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')
                }
                'multipart' {
                    # MultipartFormDataContent sets its own Content-Type (with boundary).
                    $mp = New-Object System.Net.Http.MultipartFormDataContent
                    foreach ($row in @($Multipart)) {
                        if ($null -eq $row -or -not $row.enabled) { continue }
                        if ([string]::IsNullOrEmpty([string]$row.key)) { continue }
                        if ($row.kind -eq 'file') {
                            $path = [string]$row.value
                            if (-not (Test-Path -LiteralPath $path)) { throw "File not found for field '$($row.key)': $path" }
                            $bytes = [System.IO.File]::ReadAllBytes($path)
                            $fc = New-Object System.Net.Http.ByteArrayContent($bytes, 0, $bytes.Length)
                            $fc.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
                            $mp.Add($fc, [string]$row.key, [System.IO.Path]::GetFileName($path))
                        } else {
                            $sc = New-Object System.Net.Http.StringContent([string]$row.value, [System.Text.Encoding]::UTF8)
                            $mp.Add($sc, [string]$row.key)
                        }
                    }
                    $content = $mp
                }
                default { }
            }
        }

        $allHeaders = @()
        foreach ($h in @($Headers)) {
            if ($null -eq $h) { continue }
            if (-not $h.enabled) { continue }
            if ([string]::IsNullOrEmpty([string]$h.key)) { continue }
            $allHeaders += @{ key = [string]$h.key; value = [string]$h.value }
        }
        foreach ($h in @($AuthHeaders)) {
            if ($null -eq $h) { continue }
            $allHeaders += @{ key = [string]$h.key; value = [string]$h.value }
        }

        foreach ($h in $allHeaders) {
            $name = $h.key
            $val  = $h.value
            if ($name -ieq 'Content-Type') {
                if ($null -ne $content) {
                    try {
                        $content.Headers.Remove('Content-Type') | Out-Null
                        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($val)
                    } catch { }
                }
                continue
            }
            # Content headers must go on the content object, not the request.
            if ($name -imatch '^Content-' -and $null -ne $content) {
                [void]$content.Headers.TryAddWithoutValidation($name, $val)
            } else {
                [void]$req.Headers.TryAddWithoutValidation($name, $val)
            }
        }

        if ($null -ne $content) { $req.Content = $content }

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $sw.Stop()

        # Flatten response + content headers into key/value rows.
        $respHeaders = @()
        foreach ($hdr in $resp.Headers)         { $respHeaders += @{ key = $hdr.Key; value = ($hdr.Value -join ', ') } }
        if ($null -ne $resp.Content) {
            foreach ($hdr in $resp.Content.Headers) { $respHeaders += @{ key = $hdr.Key; value = ($hdr.Value -join ', ') } }
        }

        $ctype = ''
        if ($null -ne $resp.Content -and $null -ne $resp.Content.Headers.ContentType) {
            $ctype = $resp.Content.Headers.ContentType.ToString()
        }

        $sizeBytes = 0
        if ($text) { $sizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($text) }

        return @{
            ok          = $true
            statusCode  = [int]$resp.StatusCode
            reason      = [string]$resp.ReasonPhrase
            httpVersion = $resp.Version.ToString()
            headers     = $respHeaders
            body        = $text
            contentType = $ctype
            sizeBytes   = $sizeBytes
            elapsedMs   = [int]$sw.ElapsedMilliseconds
        }
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg += "  -->  " + $_.Exception.InnerException.Message }
        return @{ ok = $false; error = $msg; elapsedMs = [int]$sw.ElapsedMilliseconds }
    } finally {
        if ($client)  { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

# --- cookie jar helpers ---
# .NET Framework's CookieContainer has no GetAllCookies(), so enumerate via reflection
# over its private domain table. Returns an array of System.Net.Cookie.
function Get-PPAllCookies {
    param($Container)
    $out = @()
    if ($null -eq $Container) { return , $out }
    try {
        $bf = [System.Reflection.BindingFlags]'NonPublic,Instance'
        $t = $Container.GetType()
        $df = $t.GetField('m_domainTable', $bf); if ($null -eq $df) { $df = $t.GetField('_domainTable', $bf) }
        $domainTable = $df.GetValue($Container)
        foreach ($pathList in $domainTable.Values) {
            $pt = $pathList.GetType()
            $lf = $pt.GetField('m_list', $bf); if ($null -eq $lf) { $lf = $pt.GetField('_list', $bf) }
            $list = $lf.GetValue($pathList)
            foreach ($cc in $list.Values) { foreach ($ck in $cc) { $out += $ck } }
        }
    } catch { }
    return , $out
}

# Serialize a CookieContainer to plain maps for state persistence.
function Export-PPCookies {
    param($Container)
    $list = @()
    foreach ($ck in (Get-PPAllCookies $Container)) {
        $list += @{
            name     = $ck.Name; value = $ck.Value; domain = $ck.Domain; path = $ck.Path
            expires  = $(if ($ck.Expires -eq [DateTime]::MinValue) { '' } else { $ck.Expires.ToString('o') })
            secure   = [bool]$ck.Secure; httpOnly = [bool]$ck.HttpOnly
        }
    }
    return , $list
}

# Populate a CookieContainer from persisted cookie maps.
function Import-PPCookies {
    param($Container, $List)
    foreach ($e in @($List)) {
        if ($null -eq $e -or [string]::IsNullOrEmpty([string]$e.name) -or [string]::IsNullOrEmpty([string]$e.domain)) { continue }
        try {
            $path = if ($e.path) { [string]$e.path } else { '/' }
            $ck = New-Object System.Net.Cookie([string]$e.name, [string]$e.value, $path, [string]$e.domain)
            if ($e.secure) { $ck.Secure = $true }
            if ($e.httpOnly) { $ck.HttpOnly = $true }
            if ($e.expires) { try { $ck.Expires = [DateTime]::Parse($e.expires) } catch { } }
            $Container.Add($ck)
        } catch { }
    }
}
