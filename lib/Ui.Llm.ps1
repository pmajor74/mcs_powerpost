# Ui.Llm.ps1 — the LLM Playground window + provider config dialog.
# Single-instance modeless window; handlers read $Global:PPApp.llmCtx (closure-safe).

function Get-PPLlmActiveProvider {
    $ctx = $Global:PPApp.llmCtx
    if (-not $ctx) { return $null }
    $name = [string]$ctx.providerCombo.SelectedItem
    foreach ($p in @($Global:PPApp.state.llm.providers)) { if ($p.name -eq $name) { return $p } }
    return $null
}

function Update-PPLlmModelCombo {
    $ctx = $Global:PPApp.llmCtx
    $prov = Get-PPLlmActiveProvider
    $ctx.modelCombo.Items.Clear()
    if ($prov) {
        foreach ($m in @($prov.models)) { [void]$ctx.modelCombo.Items.Add($m) }
        $ctx.modelCombo.Text = $prov.model
        $Global:PPApp.state.llm.activeProvider = $prov.name
        $Global:PPApp.state.llm.activeModel = $prov.model
    }
}

function Update-PPLlmProviderCombo {
    $ctx = $Global:PPApp.llmCtx
    $combo = $ctx.providerCombo
    $combo.Items.Clear()
    foreach ($p in @($Global:PPApp.state.llm.providers)) { [void]$combo.Items.Add($p.name) }
    if ($combo.Items.Count -eq 0) { return }
    $sel = 0; $active = [string]$Global:PPApp.state.llm.activeProvider
    if ($active) { for ($i = 0; $i -lt $combo.Items.Count; $i++) { if ($combo.Items[$i] -eq $active) { $sel = $i; break } } }
    $combo.SelectedIndex = $sel
}

function Update-PPLlmAttachLabel {
    $ctx = $Global:PPApp.llmCtx
    $n = @($ctx.attachments).Count
    if ($n -eq 0) { $ctx.attachLabel.Text = 'No images attached.' }
    else {
        $names = @($ctx.attachments | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', '
        $ctx.attachLabel.Text = "$n image(s): $names"
    }
}

function Add-PPLlmAttachments {
    $ctx = $Global:PPApp.llmCtx
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Multiselect = $true
    $ofd.Filter = 'Images (*.png;*.jpg;*.jpeg;*.gif;*.webp)|*.png;*.jpg;*.jpeg;*.gif;*.webp|All files (*.*)|*.*'
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ctx.attachments = @($ctx.attachments) + @($ofd.FileNames)
        Update-PPLlmAttachLabel
    }
}

function Clear-PPLlmAttachments {
    $Global:PPApp.llmCtx.attachments = @()
    Update-PPLlmAttachLabel
}

function Clear-PPLlmConversation {
    $ctx = $Global:PPApp.llmCtx
    $ctx.conversation = @()
    $ctx.lastRaw = ''
    $ctx.transcript.Clear()
    $ctx.status.Text = 'Conversation cleared.'
}

function Add-PPLlmTranscript {
    param([string]$Role, [string]$Text, $Color)
    $rtb = $Global:PPApp.llmCtx.transcript
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $Color
    $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Bold)
    $rtb.AppendText("$Role`n")
    $rtb.SelectionColor = [System.Drawing.Color]::Black
    $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Regular)
    $rtb.AppendText("$Text`n`n")
    $rtb.SelectionStart = $rtb.TextLength; $rtb.ScrollToCaret()
}

function Send-PPLlmMessage {
    $ctx = $Global:PPApp.llmCtx
    $text = $ctx.input.Text.Trim()
    if ([string]::IsNullOrEmpty($text) -and @($ctx.attachments).Count -eq 0) { return }
    $prov = Get-PPLlmActiveProvider
    if (-not $prov) { $ctx.status.Text = 'Select a provider first (Providers...).'; return }
    $model = [string]$ctx.modelCombo.Text
    if ([string]::IsNullOrWhiteSpace($model)) { $ctx.status.Text = 'Enter a model.'; return }

    $imgs = @($ctx.attachments)
    $ctx.conversation = @($ctx.conversation) + @(@{ role = 'user'; text = $text; images = $imgs })
    $suffix = if ($imgs.Count -gt 0) { "   [+$($imgs.Count) image(s)]" } else { '' }
    Add-PPLlmTranscript 'You' ($text + $suffix) ([System.Drawing.Color]::FromArgb(0, 90, 158))
    $ctx.input.Clear()
    $ctx.attachments = @(); Update-PPLlmAttachLabel

    $params = @{}
    if ($ctx.maxTokens.Text.Trim()) { $params.maxTokens = $ctx.maxTokens.Text.Trim() }
    if ($ctx.temp.Text.Trim()) { $params.temperature = $ctx.temp.Text.Trim() }

    $form = $Global:PPApp.llmForm
    $old = $form.Cursor; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ctx.status.ForeColor = [System.Drawing.Color]::Black
    $ctx.status.Text = "Sending to $($prov.name) / $model ..."; $form.Refresh()
    try {
        $timeout = Get-PPTimeoutSec
        $res = Invoke-PPLlmChat $prov $model ([string]$ctx.systemBox.Text) $ctx.conversation $params $timeout (Get-PPActiveVarMap)
        $ctx.lastRaw = [string]$res.raw
        if ($res.ok) {
            $ctx.conversation = @($ctx.conversation) + @(@{ role = 'assistant'; text = $res.text; images = @() })
            Add-PPLlmTranscript 'Assistant' $res.text ([System.Drawing.Color]::FromArgb(0, 128, 0))
            $ctx.status.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            $ctx.status.Text = "Done." + (Format-PPLlmUsage $res.usage)
        } else {
            Add-PPLlmTranscript 'Error' ([string]$res.error) ([System.Drawing.Color]::DarkRed)
            $ctx.status.ForeColor = [System.Drawing.Color]::DarkRed
            $ctx.status.Text = 'Request failed (see transcript / View raw).'
        }
    } finally { $form.Cursor = $old }
}

function Format-PPLlmUsage {
    param($Usage)
    if ($null -eq $Usage) { return '' }
    $inTok = $null; $outTok = $null
    foreach ($n in 'input_tokens', 'prompt_tokens', 'promptTokenCount') { $v = Get-PPProp $Usage $n $null; if ($null -ne $v) { $inTok = $v; break } }
    foreach ($n in 'output_tokens', 'completion_tokens', 'candidatesTokenCount') { $v = Get-PPProp $Usage $n $null; if ($null -ne $v) { $outTok = $v; break } }
    if ($null -ne $inTok -or $null -ne $outTok) { return "   tokens in=$inTok out=$outTok" }
    return ''
}

function Show-PPLlmRaw {
    $ctx = $Global:PPApp.llmCtx
    if ([string]::IsNullOrEmpty($ctx.lastRaw)) { $ctx.status.Text = 'No response yet.'; return }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Last raw response'; $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(680, 520); $dlg.ShowInTaskbar = $false
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.Dock = 'Fill'; $box.ScrollBars = 'Both'; $box.ReadOnly = $true
    $box.WordWrap = $false; $box.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $box.Text = (Format-PPJson $ctx.lastRaw)
    $dlg.Controls.Add($box)
    [void]$dlg.ShowDialog($Global:PPApp.llmForm); $dlg.Dispose()
}

# Provider config editor (JSON) + Import from file.
function Show-PPLlmProviders {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'LLM Providers'; $dlg.FormBorderStyle = 'Sizable'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(720, 480); $dlg.MinimumSize = New-Object System.Drawing.Size(520, 320)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Providers (JSON). Keys/secrets are stored locally in powerpost.state.json.'
    $lbl.Dock = 'Top'; $lbl.Height = 24; $lbl.Padding = New-Object System.Windows.Forms.Padding(4, 5, 4, 0)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.Dock = 'Fill'; $box.ScrollBars = 'Both'; $box.WordWrap = $false
    $box.AcceptsReturn = $true; $box.AcceptsTab = $true; $box.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $box.Text = ($Global:PPApp.state.llm.providers | ConvertTo-Json -Depth 10)

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $save = New-Object System.Windows.Forms.Button; $save.Text = 'Save'; $save.Size = New-Object System.Drawing.Size(90, 30)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $import = New-Object System.Windows.Forms.Button; $import.Text = 'Import from file...'; $import.Size = New-Object System.Drawing.Size(140, 30)
    $foot.Controls.Add($save); $foot.Controls.Add($cancel); $foot.Controls.Add($import)

    $dlg.Controls.Add($box); $dlg.Controls.Add($foot); $dlg.Controls.Add($lbl)
    $dlg.CancelButton = $cancel

    $import.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'JSON (*.json)|*.json|All files (*.*)|*.*'
        if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        try {
            $txt = [System.IO.File]::ReadAllText($ofd.FileName)
            $provs = ConvertFrom-PPProviderFile $txt
            $box.Text = ($provs | ConvertTo-Json -Depth 10)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not import that file.`n`n$($_.Exception.Message)", 'Import providers', 'OK', 'Warning') | Out-Null
        }
    })
    $save.Add_Click({
        try {
            $parsed = $box.Text | ConvertFrom-Json -ErrorAction Stop
            $provs = @()
            foreach ($e in @($parsed)) { $provs += (Resolve-PPLlmProvider $e) }
            if ($provs.Count -eq 0) { throw 'No providers defined.' }
            $Global:PPApp.state.llm.providers = $provs
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Invalid provider JSON.`n`n$($_.Exception.Message)", 'Save providers', 'OK', 'Warning') | Out-Null
        }
    })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    $res = $dlg.ShowDialog($Global:PPApp.llmForm)
    $dlg.Dispose()
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-PPLlmPlayground {
    if ($Global:PPApp.llmForm -and -not $Global:PPApp.llmForm.IsDisposed) { $Global:PPApp.llmForm.Activate(); return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'LLM Playground'
    $form.Size = New-Object System.Drawing.Size(840, 700)
    $form.StartPosition = 'CenterParent'
    $form.MinimumSize = New-Object System.Drawing.Size(560, 460)

    # ---- top bar (provider/model/params) ----
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.Height = 34; $bar.WrapContents = $false; $bar.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)
    function _lbl([string]$t, [int]$w = 0) { $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $false; $l.TextAlign = 'MiddleLeft'; $l.Height = 24; $l.Width = $(if ($w) { $w } else { ($t.Length * 7 + 6) }); return $l }
    $providerCombo = New-Object System.Windows.Forms.ComboBox; $providerCombo.DropDownStyle = 'DropDownList'; $providerCombo.Width = 160
    $modelCombo = New-Object System.Windows.Forms.ComboBox; $modelCombo.DropDownStyle = 'DropDown'; $modelCombo.Width = 190
    $btnProviders = New-Object System.Windows.Forms.Button; $btnProviders.Text = 'Providers...'; $btnProviders.Width = 92; $btnProviders.Height = 24
    $maxTokensBox = New-Object System.Windows.Forms.TextBox; $maxTokensBox.Width = 60
    $tempBox = New-Object System.Windows.Forms.TextBox; $tempBox.Width = 46
    $btnClear = New-Object System.Windows.Forms.Button; $btnClear.Text = 'Clear'; $btnClear.Width = 64; $btnClear.Height = 24
    $bar.Controls.AddRange(@((_lbl 'Provider' 56), $providerCombo, (_lbl 'Model' 42), $modelCombo, $btnProviders, (_lbl 'Max tok' 52), $maxTokensBox, (_lbl 'Temp' 38), $tempBox, $btnClear))

    # ---- system prompt row (multiline) ----
    $sysPanel = New-Object System.Windows.Forms.Panel; $sysPanel.Dock = 'Top'; $sysPanel.Height = 60
    $systemBox = New-Object System.Windows.Forms.TextBox
    $systemBox.Dock = 'Fill'; $systemBox.Multiline = $true; $systemBox.ScrollBars = 'Vertical'; $systemBox.AcceptsReturn = $true
    $sysLbl = New-Object System.Windows.Forms.Label; $sysLbl.Text = 'System:'; $sysLbl.Dock = 'Left'; $sysLbl.Width = 56; $sysLbl.TextAlign = 'TopLeft'; $sysLbl.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    $sysPanel.Controls.Add($systemBox); $sysPanel.Controls.Add($sysLbl)

    # ---- transcript ----
    $transcript = New-Object System.Windows.Forms.RichTextBox
    $transcript.Dock = 'Fill'; $transcript.ReadOnly = $true; $transcript.BackColor = [System.Drawing.SystemColors]::Window
    $transcript.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    # ---- bottom (attachments + input + status) ----
    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 150

    $status = New-Object System.Windows.Forms.Label; $status.Dock = 'Bottom'; $status.Height = 20; $status.Text = 'Ready.'; $status.TextAlign = 'MiddleLeft'

    $attachRow = New-Object System.Windows.Forms.Panel; $attachRow.Dock = 'Top'; $attachRow.Height = 28
    $btnAttach = New-Object System.Windows.Forms.Button; $btnAttach.Text = 'Attach image(s)'; $btnAttach.Dock = 'Left'; $btnAttach.Width = 120
    $btnClearAttach = New-Object System.Windows.Forms.Button; $btnClearAttach.Text = 'x'; $btnClearAttach.Dock = 'Left'; $btnClearAttach.Width = 28
    $attachLabel = New-Object System.Windows.Forms.Label; $attachLabel.Dock = 'Fill'; $attachLabel.TextAlign = 'MiddleLeft'; $attachLabel.Text = 'No images attached.'; $attachLabel.AutoEllipsis = $true
    $attachRow.Controls.Add($attachLabel); $attachRow.Controls.Add($btnClearAttach); $attachRow.Controls.Add($btnAttach)

    $inputArea = New-Object System.Windows.Forms.Panel; $inputArea.Dock = 'Fill'
    $input = New-Object System.Windows.Forms.TextBox; $input.Multiline = $true; $input.Dock = 'Fill'; $input.ScrollBars = 'Vertical'
    $input.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $sendBtn = New-Object System.Windows.Forms.Button; $sendBtn.Text = 'Send'; $sendBtn.Dock = 'Right'; $sendBtn.Width = 90
    $sendBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $sendBtn.ForeColor = [System.Drawing.Color]::White
    $rawBtn = New-Object System.Windows.Forms.Button; $rawBtn.Text = 'View raw'; $rawBtn.Dock = 'Right'; $rawBtn.Width = 80
    $inputArea.Controls.Add($input); $inputArea.Controls.Add($rawBtn); $inputArea.Controls.Add($sendBtn)

    $bottom.Controls.Add($inputArea); $bottom.Controls.Add($attachRow); $bottom.Controls.Add($status)

    $form.Controls.Add($transcript)
    $form.Controls.Add($bottom)
    $form.Controls.Add($sysPanel)
    $form.Controls.Add($bar)

    $ctx = @{
        providerCombo = $providerCombo; modelCombo = $modelCombo; systemBox = $systemBox
        maxTokens = $maxTokensBox; temp = $tempBox; transcript = $transcript
        input = $input; status = $status; attachLabel = $attachLabel
        attachments = @(); conversation = @(); lastRaw = ''
    }
    $Global:PPApp.llmForm = $form
    $Global:PPApp.llmCtx = $ctx

    Update-PPLlmProviderCombo
    Update-PPLlmModelCombo
    $maxTokensBox.Text = '1024'

    $providerCombo.Add_SelectedIndexChanged({ Update-PPLlmModelCombo })
    $modelCombo.Add_TextChanged({ $Global:PPApp.state.llm.activeModel = $Global:PPApp.llmCtx.modelCombo.Text })
    $btnProviders.Add_Click({ if (Show-PPLlmProviders) { Update-PPLlmProviderCombo; Update-PPLlmModelCombo } })
    $btnClear.Add_Click({ Clear-PPLlmConversation })
    $btnAttach.Add_Click({ Add-PPLlmAttachments })
    $btnClearAttach.Add_Click({ Clear-PPLlmAttachments })
    $sendBtn.Add_Click({ Send-PPLlmMessage })
    $rawBtn.Add_Click({ Show-PPLlmRaw })
    # Ctrl+Enter sends
    $input.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Send-PPLlmMessage } })

    $form.Add_FormClosed({ $Global:PPApp.llmForm = $null; $Global:PPApp.llmCtx = $null })
    $form.Show($Global:PPApp.form)
}
