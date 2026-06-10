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
    param($Method, $Url, $Headers, $AuthHeaders, $BodyType, $Body, $Form, $Multipart = @(), $GraphQLVariables = '')
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
        'graphql' { 'application/json; charset=utf-8' }
        default { '' }
    }
    if ($implied -and -not $hasContentType) { [void]$sb.AppendLine("Content-Type: $implied") }
    [void]$sb.AppendLine('')
    if ($BodyType -eq 'graphql') {
        [void]$sb.Append((Format-PPJson (ConvertTo-PPGraphQLBody $Body $GraphQLVariables)))
    } elseif ($BodyType -eq 'multipart') {
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
        $gqlVars = Expand-PPVars $m.graphqlVars $vars
        $authExpanded = Expand-PPAuth $m.auth $vars
        $auth = Resolve-PPAuthHeaders $authExpanded $timeout
        # Carry any freshly fetched/refreshed token back to the persisted model.
        $m.auth.accessToken = $authExpanded.accessToken
        $m.auth.tokenExpiry = $authExpanded.tokenExpiry
        if (-not $auth.ok) {
            $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $headers @() $m.bodyType $body $formRows $mpRows $gqlVars
            $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
            $Ctx.respStatus.Text = "Auth error: $($auth.error)"
            return
        }
        $Ctx.respReqBox.Text = Format-PPRequestPreview $m.method $url $headers $auth.headers $m.bodyType $body $formRows $mpRows $gqlVars
        $follow = $true; $proxy = ''; $jar = $null
        if ($Global:PPApp -and $Global:PPApp.state) {
            $follow = [bool]$Global:PPApp.state.followRedirects; $proxy = [string]$Global:PPApp.state.proxy
            if ($Global:PPApp.state.cookiesEnabled) { $jar = $Global:PPApp.cookies }
        }
        $resp = Invoke-PPRequest -Method $m.method -Url $url -Headers $headers `
            -AuthHeaders $auth.headers -BodyType $m.bodyType -Body $body -Form $formRows -Multipart $mpRows `
            -GraphQLVariables $gqlVars -TimeoutSec $timeout -FollowRedirects $follow -Proxy $proxy -CookieContainer $jar
        Show-PPResponse $Ctx $resp
        Show-PPTestResults $Ctx (Invoke-PPTests $m.tests $resp)
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
    $Ctx.lastResp = $Resp    # kept so "Save as example" can snapshot it
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

# Render post-response assertion results into the response panel's Tests sub-tab.
function Show-PPTestResults {
    param($Ctx, $Run)
    $box = $Ctx.respTestsBox
    if (-not $box) { return }
    $box.Clear()
    if ($Run.total -eq 0) { $box.AppendText('No tests defined. Add assertions on the request''s Tests tab.'); return }
    $green = [System.Drawing.Color]::FromArgb(0, 128, 0); $red = [System.Drawing.Color]::FromArgb(192, 0, 0)
    foreach ($r in $Run.results) {
        if ($r.passed) { $box.SelectionColor = $green; $box.AppendText("PASS  $($r.name)`r`n") }
        else { $box.SelectionColor = $red; $box.AppendText("FAIL  $($r.name)   (actual: $($r.actual))`r`n") }
    }
    $box.Select(0, 0)
    $sum = "Tests: $($Run.passed)/$($Run.total) passed"
    $Ctx.respStatus.Text = "$($Ctx.respStatus.Text)        $sum"
}

function Invoke-PPGetToken {
    param($Ctx, [string]$Flow)
    Sync-PPAuthToModel $Ctx
    # Fetch against variable-expanded values, but cache the token on the real model.
    $auth = Expand-PPAuth $Ctx.model.auth (Get-PPActiveVarMap)
    $r = $Ctx.auth.refs
    $statusLabel = switch ($Flow) { 'authcode' { $r.acStatus } 'vertex' { $r.vxStatus } default { $r.ccStatus } }

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
        } elseif ($Flow -eq 'vertex') {
            $auth.type = 'vertex'
            $result = Get-PPVertexToken $auth $timeout
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

# Load a Google service-account credentials JSON into the Vertex auth panel. Accepts both
# the gcloud key shape (client_email / private_key) and the VertexAI tool shape
# (ClientEmail / PrivateKey [+ Endpoint / Model]); when Endpoint+Model are present and the
# URL box is empty, prefill the generateContent URL.
function Import-PPVertexCredentials {
    param($Ctx)
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Load service-account credentials JSON'
    $dlg.Filter = 'JSON (*.json)|*.json|All files (*.*)|*.*'
    if ($dlg.ShowDialog($Global:PPApp.form) -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    $path = $dlg.FileName; $dlg.Dispose()
    $r = $Ctx.auth.refs
    try {
        $j = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $r.vxStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $r.vxStatus.Text = "Could not read JSON: $($_.Exception.Message)"
        return
    }
    $email = [string](Get-PPProp $j 'ClientEmail' (Get-PPProp $j 'client_email' ''))
    $key   = [string](Get-PPProp $j 'PrivateKey'  (Get-PPProp $j 'private_key'  ''))
    if (-not $email -and -not $key) {
        $r.vxStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $r.vxStatus.Text = 'No client email / private key found in that file.'
        return
    }
    $r.vxClientEmail.Text = $email
    $r.vxPrivateKey.Text = $key
    $endpoint = [string](Get-PPProp $j 'Endpoint' '')
    $model    = [string](Get-PPProp $j 'Model' '')
    if ($endpoint -and $model -and [string]::IsNullOrWhiteSpace($Ctx.urlBox.Text)) {
        $Ctx.urlBox.Text = ('{0}/models/{1}:generateContent' -f $endpoint.TrimEnd('/'), $model)
    }
    $r.vxStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
    $r.vxStatus.Text = 'Credentials loaded. Click Get Token to verify.'
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
