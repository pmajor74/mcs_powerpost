# Ui.Send.ps1 — send a request, render the response, fetch OAuth tokens, save responses.

function Get-PPTimeoutSec {
    $t = 100
    if ($Global:PPApp -and $Global:PPApp.state) { $t = [int]$Global:PPApp.state.timeout }
    if ($t -lt 1) { $t = 100 }
    return $t
}

function Format-PPSize {
    param([int]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return ('{0:N1} MB' -f ($Bytes / 1048576))
}

# Render the exact request that goes on the wire (final URL, headers incl. auth, body).
function Format-PPRequestPreview {
    param($Method, $Url, $Headers, $AuthHeaders, $BodyType, $Body, $Form, $Multipart = @())
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$Method $Url")
    [void]$sb.AppendLine('')
    $hasContentType = $false
    foreach ($h in @($Headers)) {
        if ($null -eq $h -or -not $h.enabled -or [string]::IsNullOrEmpty([string]$h.key)) { continue }
        if ($h.key -ieq 'Content-Type') { $hasContentType = $true }
        [void]$sb.AppendLine("$($h.key): $($h.value)")
    }
    foreach ($h in @($AuthHeaders)) {
        if ($null -eq $h) { continue }
        [void]$sb.AppendLine("$($h.key): $($h.value)")
    }
    $implied = switch ($BodyType) {
        'json' { 'application/json; charset=utf-8' }
        'text' { 'text/plain; charset=utf-8' }
        'form' { 'application/x-www-form-urlencoded; charset=utf-8' }
        'multipart' { 'multipart/form-data; boundary=...' }
        default { '' }
    }
    if ($implied -and -not $hasContentType) { [void]$sb.AppendLine("Content-Type: $implied") }
    [void]$sb.AppendLine('')
    if ($BodyType -eq 'multipart') {
        $lines = @()
        foreach ($row in @($Multipart)) {
            if ($null -eq $row -or -not $row.enabled -or [string]::IsNullOrEmpty([string]$row.key)) { continue }
            if ($row.kind -eq 'file') { $lines += "$($row.key): @$($row.value)  (file)" }
            else { $lines += "$($row.key): $($row.value)" }
        }
        [void]$sb.Append($(if ($lines.Count) { $lines -join "`r`n" } else { '(no fields)' }))
    } else {
        $bodyText = switch ($BodyType) {
            'form' { ConvertTo-PPFormBody $Form }
            'none' { '(no body)' }
            default { if ([string]::IsNullOrEmpty($Body)) { '(no body)' } else { $Body } }
        }
        [void]$sb.Append($bodyText)
    }
    return $sb.ToString()
}

function Invoke-PPSend {
    param($Ctx)
    Sync-PPTabToModel $Ctx
    $m = $Ctx.model
    if ([string]::IsNullOrWhiteSpace($m.url)) {
        $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $Ctx.respStatus.Text = 'Enter a URL first.'
        return
    }

    $form = $Global:PPApp.form
    $oldCursor = $form.Cursor
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $Ctx.respStatus.ForeColor = [System.Drawing.Color]::Black
    $Ctx.respStatus.Text = 'Sending...'
    $form.Refresh()
    try {
        $timeout = Get-PPTimeoutSec
        # Expand {{variables}} from the active environment into a copy of the request,
        # so the wire request (and preview) use resolved values but the saved model keeps tokens.
        $vars    = Get-PPActiveVarMap
        $url     = Build-PPUrl (Expand-PPVars $m.url $vars) (Expand-PPKvList $m.params $vars)
        $headers = Expand-PPKvList $m.headers $vars
        $body    = Expand-PPVars $m.body $vars
        $formRows = Expand-PPKvList $m.form $vars
        $mpRows  = Expand-PPMultipartList $m.multipart $vars
        $authExpanded = Expand-PPAuth $m.auth $vars
        $auth = Resolve-PPAuthHeaders $authExpanded $timeout
        # Carry any freshly fetched/refreshed token back to the persisted model.
        $m.auth.accessToken = $authExpanded.accessToken
        $m.auth.tokenExpiry = $authExpanded.tokenExpiry
        if (-not $auth.ok) {
            $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $headers @() $m.bodyType $body $formRows $mpRows
            $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
            $Ctx.respStatus.Text = "Auth error: $($auth.error)"
            return
        }
        $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $headers $auth.headers $m.bodyType $body $formRows $mpRows
        $follow = $true; $proxy = ''; $jar = $null
        if ($Global:PPApp -and $Global:PPApp.state) {
            $follow = [bool]$Global:PPApp.state.followRedirects; $proxy = [string]$Global:PPApp.state.proxy
            if ($Global:PPApp.state.cookiesEnabled) { $jar = $Global:PPApp.cookies }
        }
        $resp = Invoke-PPRequest -Method $m.method -Url $url -Headers $headers `
            -AuthHeaders $auth.headers -BodyType $m.bodyType -Body $body -Form $formRows -Multipart $mpRows `
            -TimeoutSec $timeout -FollowRedirects $follow -Proxy $proxy -CookieContainer $jar
        Show-PPResponse $Ctx $resp
        Add-PPHistoryEntry $m $resp $url
    } finally {
        $form.Cursor = $oldCursor
    }
}

# Record a send into the rolling request history (most recent first, capped at 50).
function Add-PPHistoryEntry {
    param($Model, $Resp, [string]$Url)
    if (-not ($Global:PPApp -and $Global:PPApp.state)) { return }
    $entry = @{
        when       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        method     = [string]$Model.method
        url        = $(if ($Url) { $Url } else { [string]$Model.url })
        statusCode = [int]($Resp.statusCode)
        elapsedMs  = [int]($Resp.elapsedMs)
        ok         = [bool]$Resp.ok
        request    = (Copy-PPTab $Model)
    }
    $h = @($entry) + @($Global:PPApp.state.history)
    if ($h.Count -gt 50) { $h = $h[0..49] }
    $Global:PPApp.state.history = $h
}

function Show-PPResponse {
    param($Ctx, $Resp)
    if (-not $Resp.ok) {
        $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $Ctx.respStatus.Text = "Request failed  ($($Resp.elapsedMs) ms)"
        $Ctx.respBodyBox.Text = $Resp.error
        $Ctx.respRawBox.Text = $Resp.error
        $Ctx.respHeadGrid.Rows.Clear()
        return
    }

    $code = [int]$Resp.statusCode
    if ($code -lt 300)      { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0) }
    elseif ($code -lt 400)  { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkOrange }
    else                    { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed }
    $Ctx.respStatus.Text = "$code $($Resp.reason)    -    $($Resp.elapsedMs) ms    -    $(Format-PPSize $Resp.sizeBytes)"

    $Ctx.respRawBox.Text = $Resp.body
    if (Test-PPJsonContentType $Resp.contentType) {
        $Ctx.respBodyBox.Text = (Format-PPJson $Resp.body)
    } else {
        $Ctx.respBodyBox.Text = $Resp.body
    }
    $Ctx.respBodyBox.Select(0, 0)

    $Ctx.respHeadGrid.Rows.Clear()
    foreach ($h in @($Resp.headers)) {
        [void]$Ctx.respHeadGrid.Rows.Add([string]$h.key, [string]$h.value)
    }
}

function Invoke-PPGetToken {
    param($Ctx, [string]$Flow)
    Sync-PPAuthToModel $Ctx
    # Fetch against variable-expanded values, but cache the token on the real model.
    $auth = Expand-PPAuth $Ctx.model.auth (Get-PPActiveVarMap)
    $r = $Ctx.auth.refs
    $statusLabel = $(if ($Flow -eq 'authcode') { $r.acStatus } else { $r.ccStatus })

    $form = $Global:PPApp.form
    $oldCursor = $form.Cursor
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $statusLabel.ForeColor = [System.Drawing.Color]::Black
    $statusLabel.Text = $(if ($Flow -eq 'authcode') { 'Waiting for browser sign-in...' } else { 'Requesting token...' })
    $form.Refresh()
    try {
        $timeout = Get-PPTimeoutSec
        if ($Flow -eq 'authcode') {
            $auth.type = 'authcode'
            $result = Get-PPAuthCodeToken $auth $timeout
        } else {
            $auth.type = 'clientcreds'
            $result = Get-PPClientCredentialsToken $auth $timeout
        }
        # Persist the fetched token back onto the real (unexpanded) model.
        $Ctx.model.auth.accessToken = $auth.accessToken
        $Ctx.model.auth.tokenExpiry = $auth.tokenExpiry
        if ($result.ok) {
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            $statusLabel.Text = "Token acquired ($($result.token.Length) chars)."
        } else {
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
            $statusLabel.Text = "Error: $($result.error)"
        }
    } finally {
        $form.Cursor = $oldCursor
    }
}

function Save-PPResponseToFile {
    param($Ctx)
    if ([string]::IsNullOrEmpty($Ctx.respRawBox.Text)) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'All files (*.*)|*.*|JSON (*.json)|*.json|Text (*.txt)|*.txt'
    $dlg.FileName = 'response.json'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Content -LiteralPath $dlg.FileName -Value $Ctx.respRawBox.Text -Encoding UTF8
    }
}
