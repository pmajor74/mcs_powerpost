# Ui.Tools.ps1 — Settings dialog (timeout / follow-redirects / proxy) + Request history viewer.

function Show-PPSettings {
    $state = $Global:PPApp.state
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(440, 200)

    $tbl = New-PPFieldTable
    $tbl.Dock = 'Top'; $tbl.Height = 146
    $timeoutBox = New-PPTextBox ([string]$state.timeout)
    $followChk = New-Object System.Windows.Forms.CheckBox; $followChk.Checked = [bool]$state.followRedirects; $followChk.Text = 'Follow 3xx redirects'
    $cookieChk = New-Object System.Windows.Forms.CheckBox; $cookieChk.Checked = [bool]$state.cookiesEnabled; $cookieChk.Text = 'Use cookie jar (persist cookies across requests)'
    $proxyBox = New-PPTextBox ([string]$state.proxy)
    Add-PPFieldRow $tbl 'Timeout (sec)'   $timeoutBox
    Add-PPFieldRow $tbl 'Redirects'       $followChk
    Add-PPFieldRow $tbl 'Cookies'         $cookieChk
    Add-PPFieldRow $tbl 'Proxy URL'       $proxyBox

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Size = New-Object System.Drawing.Size(84, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(84, 28)
    $foot.Controls.Add($ok); $foot.Controls.Add($cancel)

    $dlg.Controls.Add($tbl); $dlg.Controls.Add($foot)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    $ok.Add_Click({
        $t = 100; [void][int]::TryParse($timeoutBox.Text, [ref]$t); if ($t -lt 1) { $t = 100 }
        $state.timeout = $t
        $state.followRedirects = [bool]$followChk.Checked
        $state.cookiesEnabled = [bool]$cookieChk.Checked
        $state.proxy = $proxyBox.Text.Trim()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    [void]$dlg.ShowDialog($Global:PPApp.form); $dlg.Dispose()
}

# Import an OpenAPI/Swagger spec or Postman collection into a new collection.
function Show-PPImportCollection {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'API spec / collection (*.json)|*.json|All files (*.*)|*.*'
    if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $col = ConvertFrom-PPApiSpec ([System.IO.File]::ReadAllText($ofd.FileName))
        $Global:PPApp.state.collections = @($Global:PPApp.state.collections) + @($col)
        Build-PPTree
        if ($Global:PPApp.statusLabel) { $Global:PPApp.statusLabel.Text = "Imported '$($col.name)' ($(@($col.requests).Count) request(s)). Save to keep it." }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not import that file.`n`n$($_.Exception.Message)", 'Import collection', 'OK', 'Warning') | Out-Null
    }
}

# Manage the saved response examples on a request (view / delete).
function Show-PPExamplesDialog {
    param($Ctx)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Response examples'; $dlg.FormBorderStyle = 'Sizable'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(700, 380); $dlg.MinimumSize = New-Object System.Drawing.Size(480, 280)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($c in @(@('Name', 26), @('Status', 12), @('Method', 12), @('URL', 50))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = $c[0]; $col.FillWeight = $c[1]; [void]$grid.Columns.Add($col)
    }
    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $close = New-Object System.Windows.Forms.Button; $close.Text = 'Close'; $close.Size = New-Object System.Drawing.Size(84, 28)
    $view = New-Object System.Windows.Forms.Button; $view.Text = 'View'; $view.Size = New-Object System.Drawing.Size(84, 28)
    $del = New-Object System.Windows.Forms.Button; $del.Text = 'Delete'; $del.Size = New-Object System.Drawing.Size(84, 28)
    $foot.Controls.Add($close); $foot.Controls.Add($view); $foot.Controls.Add($del)
    $dlg.Controls.Add($grid); $dlg.Controls.Add($foot); $dlg.CancelButton = $close

    $fill = { $grid.Rows.Clear(); foreach ($e in @($Ctx.model.examples)) { [void]$grid.Rows.Add($e.name, [string]$e.statusCode, $e.method, $e.url) } }
    & $fill
    $view.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $i = $grid.SelectedRows[0].Index
        if ($i -ge 0 -and $i -lt @($Ctx.model.examples).Count) { Show-PPExample $Ctx $Ctx.model.examples[$i]; $dlg.Close() }
    })
    $del.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $i = $grid.SelectedRows[0].Index
        $exs = @($Ctx.model.examples)
        if ($i -ge 0 -and $i -lt $exs.Count) { $target = $exs[$i]; $Ctx.model.examples = @($exs | Where-Object { -not [object]::ReferenceEquals($_, $target) }); & $fill }
    })
    $close.Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog($Global:PPApp.form); $dlg.Dispose()
}

function Show-PPCookies {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Cookies'; $dlg.FormBorderStyle = 'Sizable'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 440); $dlg.MinimumSize = New-Object System.Drawing.Size(520, 300)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($c in @(@('Domain', 22), @('Name', 18), @('Value', 34), @('Path', 12), @('Expires', 14))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = $c[0]; $col.FillWeight = $c[1]
        [void]$grid.Columns.Add($col)
    }

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $close = New-Object System.Windows.Forms.Button; $close.Text = 'Close'; $close.Size = New-Object System.Drawing.Size(84, 28)
    $del = New-Object System.Windows.Forms.Button; $del.Text = 'Delete selected'; $del.Size = New-Object System.Drawing.Size(120, 28)
    $clear = New-Object System.Windows.Forms.Button; $clear.Text = 'Clear all'; $clear.Size = New-Object System.Drawing.Size(90, 28)
    $foot.Controls.Add($close); $foot.Controls.Add($del); $foot.Controls.Add($clear)

    $dlg.Controls.Add($grid); $dlg.Controls.Add($foot)
    $dlg.CancelButton = $close

    $fill = {
        $grid.Rows.Clear()
        foreach ($ck in (Get-PPAllCookies $Global:PPApp.cookies)) {
            $exp = if ($ck.Expires -eq [DateTime]::MinValue) { 'session' } else { $ck.Expires.ToString('yyyy-MM-dd HH:mm') }
            [void]$grid.Rows.Add($ck.Domain, $ck.Name, $ck.Value, $ck.Path, $exp)
        }
    }
    & $fill

    $del.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $idx = $grid.SelectedRows[0].Index
        $all = @(Get-PPAllCookies $Global:PPApp.cookies)
        if ($idx -lt 0 -or $idx -ge $all.Count) { return }
        $t = $all[$idx]
        $newC = New-Object System.Net.CookieContainer
        foreach ($ck in $all) {
            if ($ck.Name -eq $t.Name -and $ck.Domain -eq $t.Domain -and $ck.Path -eq $t.Path) { continue }
            try { $newC.Add($ck) } catch { }
        }
        $Global:PPApp.cookies = $newC; & $fill
    })
    $clear.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show('Clear all cookies?', 'Confirm', 'YesNo', 'Question') -eq 'Yes') {
            $Global:PPApp.cookies = New-Object System.Net.CookieContainer; & $fill
        }
    })
    $close.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    [void]$dlg.ShowDialog($Global:PPApp.form); $dlg.Dispose()
}

function Show-PPHistory {
    $state = $Global:PPApp.state
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Request history'; $dlg.FormBorderStyle = 'Sizable'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 460); $dlg.MinimumSize = New-Object System.Drawing.Size(520, 320)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($c in @(@('When', 18), @('Method', 10), @('Status', 10), @('ms', 8), @('URL', 54))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c[0]; $col.FillWeight = $c[1]
        [void]$grid.Columns.Add($col)
    }

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $open = New-Object System.Windows.Forms.Button; $open.Text = 'Open in new tab'; $open.Size = New-Object System.Drawing.Size(120, 28)
    $close = New-Object System.Windows.Forms.Button; $close.Text = 'Close'; $close.Size = New-Object System.Drawing.Size(84, 28)
    $clear = New-Object System.Windows.Forms.Button; $clear.Text = 'Clear history'; $clear.Size = New-Object System.Drawing.Size(110, 28)
    $foot.Controls.Add($open); $foot.Controls.Add($close); $foot.Controls.Add($clear)

    $dlg.Controls.Add($grid); $dlg.Controls.Add($foot)
    $dlg.CancelButton = $close

    $fill = {
        $grid.Rows.Clear()
        foreach ($e in @($state.history)) {
            $status = if ($e.ok) { [string]$e.statusCode } else { 'failed' }
            [void]$grid.Rows.Add($e.when, $e.method, $status, [string]$e.elapsedMs, $e.url)
        }
    }
    $reopen = {
        $i = $grid.SelectedRows.Count
        if ($i -eq 0) { return }
        $idx = $grid.SelectedRows[0].Index
        if ($idx -lt 0 -or $idx -ge @($state.history).Count) { return }
        Add-PPTabPage (Copy-PPTab $state.history[$idx].request) $true | Out-Null
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    }
    & $fill

    $open.Add_Click({ & $reopen })
    $grid.Add_CellDoubleClick({ & $reopen })
    $close.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    $clear.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show('Clear all request history?', 'Confirm', 'YesNo', 'Question') -eq 'Yes') {
            $state.history = @(); & $fill
        }
    })

    [void]$dlg.ShowDialog($Global:PPApp.form); $dlg.Dispose()
}
