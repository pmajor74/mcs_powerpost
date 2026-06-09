# Ui.Code.ps1 — cURL import dialog + "Copy as cURL / PowerShell" commands.

# Paste a cURL command; parse it into a new tab.
function Show-PPImportCurl {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Import cURL'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 360)
    $dlg.MinimumSize = New-Object System.Drawing.Size(440, 260)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Paste a cURL command, then click Import:'; $lbl.Dock = 'Top'; $lbl.Height = 24
    $lbl.Padding = New-Object System.Windows.Forms.Padding(4, 5, 4, 0)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.Dock = 'Fill'; $box.ScrollBars = 'Both'; $box.MaxLength = 0
    $box.WordWrap = $false; $box.AcceptsReturn = $true; $box.Font = New-Object System.Drawing.Font('Consolas', 9.5)

    # FlowLayoutPanel (right-to-left) places the buttons reliably at the bottom-right
    # regardless of DPI/scaling — no manual coordinates to drift off-screen.
    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'
    $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Import'; $ok.Size = New-Object System.Drawing.Size(110, 30)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $foot.Controls.Add($ok)        # rightmost (RightToLeft flow)
    $foot.Controls.Add($cancel)    # left of Import

    $dlg.Controls.Add($box)        # Fill (add first so it doesn't overlap the docked edges)
    $dlg.Controls.Add($foot)       # Bottom
    $dlg.Controls.Add($lbl)        # Top
    $dlg.CancelButton = $cancel    # Esc cancels; Enter stays in the textbox

    $ok.Add_Click({
        if ([string]::IsNullOrWhiteSpace($box.Text)) { return }   # nothing to import; keep dialog open
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    $owner = $Global:PPApp.form
    $res = if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() }
    $text = $box.Text
    $dlg.Dispose()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $model = ConvertFrom-PPCurl $text
        Add-PPTabPage $model $true | Out-Null
        $Global:PPApp.statusLabel.Text = "Imported '$($model.method) $($model.url)' into a new tab."
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not parse that cURL command.`n`n$($_.Exception.Message)", 'Import cURL', 'OK', 'Warning') | Out-Null
    }
}

function Copy-PPAsCurlCmd {
    $ctx = Get-PPCurrentCtx
    if (-not $ctx) { return }
    Sync-PPTabToModel $ctx
    $code = ConvertTo-PPCurl $ctx.model (Get-PPActiveVarMap)
    if ($code) { [System.Windows.Forms.Clipboard]::SetText($code) }
    $Global:PPApp.statusLabel.Text = 'Copied request as cURL.'
}

function Copy-PPAsPowerShellCmd {
    $ctx = Get-PPCurrentCtx
    if (-not $ctx) { return }
    Sync-PPTabToModel $ctx
    $code = ConvertTo-PPPowerShell $ctx.model (Get-PPActiveVarMap)
    if ($code) { [System.Windows.Forms.Clipboard]::SetText($code) }
    $Global:PPApp.statusLabel.Text = 'Copied request as PowerShell.'
}

# Build a filesystem-safe default file name from the tab/request name.
function Get-PPSafeFileName {
    param([string]$Name, [string]$Fallback = 'request')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Fallback }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) { if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) } }
    $s = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { $s = $Fallback }
    return $s
}

# Export the current tab as a cURL command saved to a .sh / .txt file.
function Export-PPAsCurlCmd {
    $ctx = Get-PPCurrentCtx
    if (-not $ctx) { return }
    Sync-PPTabToModel $ctx
    $code = ConvertTo-PPCurl $ctx.model (Get-PPActiveVarMap)
    if (-not $code) { return }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Export as cURL'
    $dlg.Filter = 'Shell script (*.sh)|*.sh|Text file (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.DefaultExt = 'sh'
    $dlg.FileName = (Get-PPSafeFileName $ctx.model.name) + '.sh'
    $owner = $Global:PPApp.form
    $res = if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() }
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    $path = $dlg.FileName
    $dlg.Dispose()
    try {
        # newline-terminated, UTF-8 without BOM so the script runs cleanly on *nix
        [System.IO.File]::WriteAllText($path, $code + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $Global:PPApp.statusLabel.Text = "Exported cURL to $path"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not write the file.`n`n$($_.Exception.Message)", 'Export as cURL', 'OK', 'Warning') | Out-Null
    }
}
