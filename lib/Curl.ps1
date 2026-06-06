# Curl.ps1 — import a cURL command into a request model, and export a model as cURL /
# PowerShell. Pure (UI-free) string logic so it can be exercised by -SelfTest.

# Tokenize a command line, honoring single/double quotes and line continuations
# (backslash / caret / backtick before a newline). Quotes are removed from tokens.
function Split-PPCommandLine {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $t = $Text -replace "\\\r?\n", ' '     # bash    \<newline>
    $t = $t -replace '\^\r?\n', ' '        # cmd     ^<newline>
    $t = $t -replace '`\r?\n', ' '         # ps      `<newline>
    $tokens = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inS = $false; $inD = $false; $has = $false
    for ($i = 0; $i -lt $t.Length; $i++) {
        $ch = $t[$i]
        if ($inS) {
            if ($ch -eq "'") { $inS = $false } else { [void]$sb.Append($ch) }
            continue
        }
        if ($inD) {
            if ($ch -eq '"') { $inD = $false }
            elseif ($ch -eq '\' -and ($i + 1) -lt $t.Length -and ($t[$i + 1] -eq '"' -or $t[$i + 1] -eq '\')) { $i++; [void]$sb.Append($t[$i]) }
            else { [void]$sb.Append($ch) }
            continue
        }
        if ($ch -eq "'") { $inS = $true; $has = $true }
        elseif ($ch -eq '"') { $inD = $true; $has = $true }
        elseif ($ch -eq ' ' -or $ch -eq "`t" -or $ch -eq "`r" -or $ch -eq "`n") {
            if ($has) { [void]$tokens.Add($sb.ToString()); [void]$sb.Clear(); $has = $false }
        }
        else { [void]$sb.Append($ch); $has = $true }
    }
    if ($has) { [void]$tokens.Add($sb.ToString()) }
    return $tokens.ToArray()
}

function Test-PPLooksLikeUrl {
    param([string]$S)
    if ([string]::IsNullOrEmpty($S)) { return $false }
    return ($S -match '://') -or ($S -match '^[\w.-]+\.[A-Za-z]{2,}(?:[:/?]|$)') -or ($S -match '^localhost(?:[:/]|$)')
}

# Parse "a=1&b=2" into enabled key/value rows (values URL-decoded).
function ConvertFrom-PPQueryString {
    param([string]$S)
    $rows = @()
    foreach ($pair in ($S -split '&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -lt 0) { $k = $pair; $v = '' } else { $k = $pair.Substring(0, $eq); $v = $pair.Substring($eq + 1) }
        $rows += (New-PPKv $true ([Uri]::UnescapeDataString($k)) ([Uri]::UnescapeDataString($v)))
    }
    return , $rows
}

# Parse a cURL command into a New-PPTab-shaped model.
function ConvertFrom-PPCurl {
    param([string]$Text)
    $m = New-PPTab 'Imported'
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($tk in @(Split-PPCommandLine $Text)) { [void]$list.Add($tk) }
    if ($list.Count -gt 0 -and $list[0] -ieq 'curl') { $list.RemoveAt(0) }

    $method = ''; $url = ''; $hdrRaw = @(); $dataParts = @(); $formParts = @()
    $isGet = $false; $userinfo = ''; $haveUser = $false
    $i = 0
    while ($i -lt $list.Count) {
        $a = $list[$i]
        if     ($a -match '^(-X|--request)$')          { $i++; if ($i -lt $list.Count) { $method = $list[$i].ToUpper() } }
        elseif ($a -match '^--request=(.+)$')          { $method = $matches[1].ToUpper() }
        elseif ($a -match '^(-H|--header)$')           { $i++; if ($i -lt $list.Count) { $hdrRaw += $list[$i] } }
        elseif ($a -match '^--header=(.+)$')           { $hdrRaw += $matches[1] }
        elseif ($a -match '^(-d|--data|--data-raw|--data-binary|--data-ascii)$') { $i++; if ($i -lt $list.Count) { $dataParts += $list[$i] } }
        elseif ($a -match '^--data(?:-raw|-binary|-ascii)?=(.*)$')               { $dataParts += $matches[1] }
        elseif ($a -match '^--data-urlencode$')        { $i++; if ($i -lt $list.Count) { $dataParts += $list[$i] } }
        elseif ($a -match '^--data-urlencode=(.*)$')   { $dataParts += $matches[1] }
        elseif ($a -match '^(-F|--form)$')             { $i++; if ($i -lt $list.Count) { $formParts += $list[$i] } }
        elseif ($a -match '^--form=(.+)$')             { $formParts += $matches[1] }
        elseif ($a -match '^(-u|--user)$')             { $i++; if ($i -lt $list.Count) { $userinfo = $list[$i]; $haveUser = $true } }
        elseif ($a -match '^--user=(.+)$')             { $userinfo = $matches[1]; $haveUser = $true }
        elseif ($a -match '^(-G|--get)$')              { $isGet = $true }
        elseif ($a -match '^--url=(.+)$')              { $url = $matches[1] }
        elseif ($a -match '^--url$')                   { $i++; if ($i -lt $list.Count) { $url = $list[$i] } }
        elseif ($a -match '^(-A|--user-agent|-e|--referer|-o|--output|-m|--max-time|-x|--proxy|--connect-timeout|--retry|-b|--cookie|-c|--cookie-jar|-T|--upload-file)$') { $i++ }  # consume + ignore arg
        elseif ($a -match '^-')                        { }  # ignore valueless flags (-k, -L, -s, -i, --compressed, ...)
        else   { if (-not $url -and (Test-PPLooksLikeUrl $a)) { $url = $a } }
        $i++
    }

    if ($url) { $m.url = $url }

    $hasCt = $false
    foreach ($hr in $hdrRaw) {
        $idx = $hr.IndexOf(':')
        if ($idx -lt 0) { continue }
        $k = $hr.Substring(0, $idx).Trim()
        $v = $hr.Substring($idx + 1).Trim()
        if ($k -ieq 'Authorization') {
            if ($v -match '^(?i:Bearer)\s+(.+)$') { $m.auth.type = 'bearer'; $m.auth.bearerToken = $matches[1]; continue }
            if ($v -match '^(?i:Basic)\s+(.+)$') {
                try {
                    $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[1]))
                    $c = $dec.IndexOf(':')
                    $m.auth.type = 'basic'
                    if ($c -ge 0) { $m.auth.basicUser = $dec.Substring(0, $c); $m.auth.basicPass = $dec.Substring($c + 1) }
                    else { $m.auth.basicUser = $dec }
                    continue
                } catch { }  # not decodable -> fall through and keep as a header
            }
        }
        if ($k -ieq 'Content-Type') { $hasCt = $true }
        $m.headers += (New-PPKv $true $k $v)
    }

    if ($haveUser) {
        $c = $userinfo.IndexOf(':')
        $m.auth.type = 'basic'
        if ($c -ge 0) { $m.auth.basicUser = $userinfo.Substring(0, $c); $m.auth.basicPass = $userinfo.Substring($c + 1) }
        else { $m.auth.basicUser = $userinfo }
    }

    $data = ($dataParts -join '&')
    $ctHeader = ''
    foreach ($h in $m.headers) { if ($h.key -ieq 'Content-Type') { $ctHeader = $h.value } }
    if (@($formParts).Count -gt 0) {
        $m.bodyType = 'multipart'
        foreach ($fp in $formParts) {
            $eq = $fp.IndexOf('=')
            if ($eq -lt 0) { continue }
            $k = $fp.Substring(0, $eq); $val = $fp.Substring($eq + 1)
            if ($val.StartsWith('@') -or $val.StartsWith('<')) {
                $p = $val.Substring(1)
                $sc = $p.IndexOf(';'); if ($sc -ge 0) { $p = $p.Substring(0, $sc) }  # drop ;type=/;filename=
                $m.multipart += (New-PPMultipartRow $true $k 'file' $p)
            } else {
                $m.multipart += (New-PPMultipartRow $true $k 'text' $val)
            }
        }
    } elseif ($isGet -and $data) {
        foreach ($row in (ConvertFrom-PPQueryString $data)) { $m.params += $row }
    } elseif ($data -ne '') {
        if ($ctHeader -match 'json') { $m.bodyType = 'json'; $m.body = $data }
        elseif ($ctHeader -match 'x-www-form-urlencoded') { $m.bodyType = 'form'; $m.form = (ConvertFrom-PPQueryString $data) }
        elseif ($data -match '^\s*[\{\[]') { $m.bodyType = 'json'; $m.body = $data }
        else { $m.bodyType = 'text'; $m.body = $data }
    }

    if (-not $method) {
        if ((($data -and -not $isGet)) -or (@($formParts).Count -gt 0)) { $method = 'POST' } else { $method = 'GET' }
    }
    $m.method = $method
    return $m
}

# --- export ---

# Single-quote a string for a bash-style cURL command.
function Quote-PPSh { param([string]$S) "'" + ($S -replace "'", "'\''") + "'" }
# Single-quote a string for a PowerShell literal.
function Quote-PPPs { param([string]$S) "'" + ($S -replace "'", "''") + "'" }

# Build the "Authorization: ..." header line for export, or $null if none applies.
# OAuth flows only export a header when a token has already been fetched/cached.
function Get-PPAuthHeaderForExport {
    param($Auth, $Map = @{})
    switch ($Auth.type) {
        'bearer' { $t = Expand-PPVars $Auth.bearerToken $Map; if ($t) { return "Authorization: Bearer $t" } }
        'basic'  {
            $u = Expand-PPVars $Auth.basicUser $Map; $p = Expand-PPVars $Auth.basicPass $Map
            $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $u, $p)))
            return "Authorization: Basic $b"
        }
        'clientcreds' { if ($Auth.accessToken) { return "Authorization: Bearer $($Auth.accessToken)" } }
        'authcode'    { if ($Auth.accessToken) { return "Authorization: Bearer $($Auth.accessToken)" } }
    }
    return $null
}

function ConvertTo-PPCurl {
    param($Model, $Map = @{})
    $url = Build-PPUrl (Expand-PPVars $Model.url $Map) (Expand-PPKvList $Model.params $Map)
    $parts = @("curl -X $($Model.method) " + (Quote-PPSh $url))
    $hasCt = $false
    foreach ($h in (Expand-PPKvList $Model.headers $Map)) {
        if ($h.enabled -and $h.key) {
            if ($h.key -ieq 'Content-Type') { $hasCt = $true }
            $parts += '  -H ' + (Quote-PPSh ('{0}: {1}' -f $h.key, $h.value))
        }
    }
    $ah = Get-PPAuthHeaderForExport $Model.auth $Map
    if ($ah) { $parts += '  -H ' + (Quote-PPSh $ah) }
    switch ($Model.bodyType) {
        'json' { if ($Model.body) { if (-not $hasCt) { $parts += '  -H ' + (Quote-PPSh 'Content-Type: application/json') }; $parts += '  --data ' + (Quote-PPSh (Expand-PPVars $Model.body $Map)) } }
        'text' { if ($Model.body) { $parts += '  --data ' + (Quote-PPSh (Expand-PPVars $Model.body $Map)) } }
        'form' { $fb = ConvertTo-PPFormBody (Expand-PPKvList $Model.form $Map); if ($fb) { if (-not $hasCt) { $parts += '  -H ' + (Quote-PPSh 'Content-Type: application/x-www-form-urlencoded') }; $parts += '  --data ' + (Quote-PPSh $fb) } }
        'multipart' {
            foreach ($row in (Expand-PPMultipartList $Model.multipart $Map)) {
                if ($row.enabled -and $row.key) {
                    if ($row.kind -eq 'file') { $parts += '  -F ' + (Quote-PPSh ('{0}=@{1}' -f $row.key, $row.value)) }
                    else { $parts += '  -F ' + (Quote-PPSh ('{0}={1}' -f $row.key, $row.value)) }
                }
            }
        }
    }
    if ($Global:PPIgnoreSsl) { $parts += '  --insecure' }
    return ($parts -join " \`n")
}

function ConvertTo-PPPowerShell {
    param($Model, $Map = @{})
    $url = Build-PPUrl (Expand-PPVars $Model.url $Map) (Expand-PPKvList $Model.params $Map)
    $hdrs = @()
    foreach ($h in (Expand-PPKvList $Model.headers $Map)) {
        if ($h.enabled -and $h.key -and ($h.key -inotmatch '^Content-Type$')) {
            $hdrs += ('    {0} = {1}' -f (Quote-PPPs $h.key), (Quote-PPPs $h.value))
        }
    }
    $ah = Get-PPAuthHeaderForExport $Model.auth $Map
    if ($ah) {
        $idx = $ah.IndexOf(':'); $k = $ah.Substring(0, $idx).Trim(); $v = $ah.Substring($idx + 1).Trim()
        $hdrs += ('    {0} = {1}' -f (Quote-PPPs $k), (Quote-PPPs $v))
    }
    $lines = @()
    if ($hdrs.Count) { $lines += '$headers = @{'; $lines += $hdrs; $lines += '}' }
    $argsList = @("-Method $($Model.method)", '-Uri ' + (Quote-PPPs $url))
    if ($hdrs.Count) { $argsList += '-Headers $headers' }
    $ct = ''; $body = ''; $note = ''
    switch ($Model.bodyType) {
        'json' { $ct = 'application/json'; $body = Expand-PPVars $Model.body $Map }
        'text' { $ct = 'text/plain'; $body = Expand-PPVars $Model.body $Map }
        'form' { $ct = 'application/x-www-form-urlencoded'; $body = ConvertTo-PPFormBody (Expand-PPKvList $Model.form $Map) }
        'multipart' { $note = '# Note: multipart/form-data (file upload) is omitted - use "Copy as cURL" for that.' }
    }
    if ($body) {
        $lines += ('$body = ' + (Quote-PPPs $body))
        $argsList += '-Body $body'
        if ($ct) { $argsList += "-ContentType '$ct'" }
    }
    $lines += ('Invoke-RestMethod ' + ($argsList -join ' '))
    if ($note) { $lines = @($note) + $lines }
    return ($lines -join "`n")
}
