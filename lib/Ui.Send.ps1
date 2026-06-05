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
    param($Method, $Url, $Headers, $AuthHeaders, $BodyType, $Body, $Form)
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
        default { '' }
    }
    if ($implied -and -not $hasContentType) { [void]$sb.AppendLine("Content-Type: $implied") }
    [void]$sb.AppendLine('')
    $bodyText = switch ($BodyType) {
        'form' { ConvertTo-PPFormBody $Form }
        'none' { '(no body)' }
        default { if ([string]::IsNullOrEmpty($Body)) { '(no body)' } else { $Body } }
    }
    [void]$sb.Append($bodyText)
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
        $url = Build-PPUrl $m.url $m.params
        $auth = Resolve-PPAuthHeaders $m.auth $timeout
        if (-not $auth.ok) {
            $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $m.headers @() $m.bodyType $m.body $m.form
            $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
            $Ctx.respStatus.Text = "Auth error: $($auth.error)"
            return
        }
        $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $m.headers $auth.headers $m.bodyType $m.body $m.form
        $resp = Invoke-PPRequest -Method $m.method -Url $url -Headers $m.headers `
            -AuthHeaders $auth.headers -BodyType $m.bodyType -Body $m.body -Form $m.form -TimeoutSec $timeout
        Show-PPResponse $Ctx $resp
    } finally {
        $form.Cursor = $oldCursor
    }
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
    $auth = $Ctx.model.auth
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
