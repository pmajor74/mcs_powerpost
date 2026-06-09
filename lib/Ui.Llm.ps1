# Ui.Llm.ps1 — the LLM Playground: a tabbed, Postman-style chat workbench.
# Each tab = a saved session (provider/model/system/params + full conversation).
# Per tab: chat transcript + a Response/Headers/Request details notebook (REST info).
# Tabs persist to state.llm.tabs. Per-control handlers carry ctx via control.Tag.

# --- provider lookup / combo population (per tab ctx) ---

function Get-PPLlmProviderByName {
    param([string]$Name)
    foreach ($p in @($Global:PPApp.state.llm.providers)) { if ($p.name -eq $Name) { return $p } }
    return $null
}

function Update-PPLlmModelCombo {
    param($Ctx)
    $prov = Get-PPLlmProviderByName ([string]$Ctx.providerCombo.SelectedItem)
    $Ctx.modelCombo.Items.Clear()
    if ($prov) { foreach ($m in @($prov.models)) { [void]$Ctx.modelCombo.Items.Add($m) } }
    $want = [string]$Ctx.model.model
    if ([string]::IsNullOrEmpty($want) -and $prov) { $want = $prov.model }
    $Ctx.modelCombo.Text = $want
}

# Relabel the first Thinking item to "Default (<effective level>)" for the current model.
function Update-PPLlmThinkDefaultLabel {
    param($Ctx)
    $combo = $Ctx.thinkingCombo
    if (-not $combo -or $combo.Items.Count -eq 0) { return }
    $prov = Get-PPLlmProviderByName ([string]$Ctx.providerCombo.SelectedItem)
    $dialect = if ($prov) { $prov.dialect } else { 'openai' }
    $eff = Get-PPLlmEffectiveThinking ([string]$Ctx.modelCombo.Text) $dialect
    $label = if ($eff) { "Default ($eff)" } else { 'Default' }
    $sel = $combo.SelectedIndex
    $combo.Items[0] = $label
    if ($sel -ge 0) { $combo.SelectedIndex = $sel }
}

# Read the Thinking value, normalizing the relabeled first item back to 'Default'.
function Get-PPLlmThinkValue {
    param($Ctx)
    $s = [string]$Ctx.thinkingCombo.SelectedItem
    if ($s -like 'Default*') { return 'Default' }
    return $s
}

function Update-PPLlmProviderCombo {
    param($Ctx)
    $combo = $Ctx.providerCombo
    $combo.Items.Clear()
    foreach ($p in @($Global:PPApp.state.llm.providers)) { [void]$combo.Items.Add($p.name) }
    if ($combo.Items.Count -eq 0) { return }
    $target = [string]$Ctx.model.provider
    if ([string]::IsNullOrEmpty($target)) { $target = [string]$Global:PPApp.state.llm.activeProvider }
    $sel = 0
    if ($target) { for ($i = 0; $i -lt $combo.Items.Count; $i++) { if ($combo.Items[$i] -eq $target) { $sel = $i; break } } }
    $Ctx.suppress = $true
    $combo.SelectedIndex = $sel
    $Ctx.suppress = $false
}

# --- attachments ---

function Update-PPLlmAttachLabel {
    param($Ctx)
    $n = @($Ctx.attachments).Count
    if ($n -eq 0) { $Ctx.attachLabel.Text = 'No images attached.' }
    else { $Ctx.attachLabel.Text = "$n image(s): " + (@($Ctx.attachments | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', ') }
}

function Add-PPLlmAttachments {
    param($Ctx)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Multiselect = $true
    $ofd.Filter = 'Images (*.png;*.jpg;*.jpeg;*.gif;*.webp)|*.png;*.jpg;*.jpeg;*.gif;*.webp|All files (*.*)|*.*'
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Ctx.attachments = @($Ctx.attachments) + @($ofd.FileNames)
        Update-PPLlmAttachLabel $Ctx
    }
}

# --- transcript ---

function Add-PPLlmTranscript {
    param($Ctx, [string]$Role, [string]$Text, $Color)
    $rtb = $Ctx.transcript
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $Color
    $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Bold)
    $rtb.AppendText("$Role`n")
    $rtb.SelectionColor = [System.Drawing.Color]::Black
    $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Regular)
    $rtb.AppendText("$Text`n`n")
    $rtb.SelectionStart = $rtb.TextLength; $rtb.ScrollToCaret()
}

# Force the transcript to repaint + scroll to the latest line. Needed because the transcript
# is first rendered during tab construction (before the window is shown / the splitter sizes
# the panel), and a RichTextBox won't repaint that content until something invalidates it.
function Update-PPLlmTranscriptView {
    param($Ctx)
    $rtb = $Ctx.transcript
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.ScrollToCaret()
    $rtb.Refresh()
}

function Render-PPLlmTranscript {
    param($Ctx)
    $Ctx.transcript.Clear()
    foreach ($turn in @($Ctx.model.conversation)) {
        $suffix = if (@($turn.images).Count -gt 0) { "   [+$(@($turn.images).Count) image(s)]" } else { '' }
        if ($turn.role -eq 'assistant') { Add-PPLlmTranscript $Ctx 'Assistant' $turn.text ([System.Drawing.Color]::FromArgb(0, 128, 0)) }
        else { Add-PPLlmTranscript $Ctx 'You' ($turn.text + $suffix) ([System.Drawing.Color]::FromArgb(0, 90, 158)) }
    }
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

# Fill the Response / Headers / Request detail tabs from a chat result.
function Show-PPLlmDetails {
    param($Ctx, $Res)
    $req = $Res.request
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$($req.method) $($req.url)")
    [void]$sb.AppendLine('')
    foreach ($h in @($req.headers)) { if ($null -ne $h) { [void]$sb.AppendLine("$($h.key): $($h.value)") } }
    [void]$sb.AppendLine('')
    [void]$sb.Append((Format-PPJson $req.body))
    $Ctx.reqBox.Text = $sb.ToString()

    $resp = $Res.response
    $Ctx.headGrid.Rows.Clear()
    if ($null -ne $resp -and $resp.ok) {
        $code = [int]$resp.statusCode
        if ($code -lt 300) { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0) }
        elseif ($code -lt 400) { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkOrange }
        else { $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed }
        $Ctx.respStatus.Text = "$code $($resp.reason)    -    $($resp.elapsedMs) ms    -    $(Format-PPSize $resp.sizeBytes)"
        $Ctx.respBody.Text = (Format-PPJson $resp.body)
        foreach ($h in @($resp.headers)) { [void]$Ctx.headGrid.Rows.Add([string]$h.key, [string]$h.value) }
    } elseif ($null -ne $resp) {
        $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $Ctx.respStatus.Text = "Request failed  ($($resp.elapsedMs) ms)"
        $Ctx.respBody.Text = [string]$resp.error
    } else {
        $Ctx.respStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $Ctx.respStatus.Text = 'No response.'
        $Ctx.respBody.Text = [string]$Res.error
    }
    $Ctx.respBody.Select(0, 0)
}

# --- model <-> controls ---

function Sync-PPLlmCtxToModel {
    param($Ctx)
    $m = $Ctx.model
    $m.provider = [string]$Ctx.providerCombo.SelectedItem
    $m.model = [string]$Ctx.modelCombo.Text
    $m.system = $Ctx.systemBox.Text
    $m.maxTokens = $Ctx.maxTokens.Text
    $m.temperature = $Ctx.temp.Text
    $m.thinking = Get-PPLlmThinkValue $Ctx
    $m.attachments = @($Ctx.attachments)   # persist the pending (unsent) image queue
    $Ctx.page.Text = $m.name
}

function Set-PPLlmControlsFromModel {
    param($Ctx)
    $m = $Ctx.model
    Update-PPLlmProviderCombo $Ctx
    Update-PPLlmModelCombo $Ctx
    $Ctx.systemBox.Text = $m.system
    $Ctx.maxTokens.Text = $m.maxTokens
    $Ctx.temp.Text = $m.temperature
    Update-PPLlmThinkDefaultLabel $Ctx
    $prov = Get-PPLlmProviderByName ([string]$Ctx.providerCombo.SelectedItem)
    $dialect = if ($prov) { $prov.dialect } else { 'openai' }
    $tv = [string]$m.thinking
    if ([string]::IsNullOrEmpty($tv)) { $tv = Get-PPLlmLowestThinking ([string]$Ctx.modelCombo.Text) $dialect }  # new tab -> least thinking
    if ($tv -eq 'Default') { $Ctx.thinkingCombo.SelectedIndex = 0 }
    else { $i = $Ctx.thinkingCombo.Items.IndexOf($tv); $Ctx.thinkingCombo.SelectedIndex = $(if ($i -ge 0) { $i } else { 0 }) }
    $Ctx.attachments = @($m.attachments)   # restore pending image queue
    Update-PPLlmAttachLabel $Ctx
    Render-PPLlmTranscript $Ctx
}

# --- send ---

function Send-PPLlmMessage {
    param($Ctx)
    Sync-PPLlmCtxToModel $Ctx
    $text = $Ctx.input.Text.Trim()
    # Allow sending with any of: chat text, an attached image, or a system prompt.
    $hasImg = @($Ctx.attachments).Count -gt 0
    $hasSys = -not [string]::IsNullOrWhiteSpace([string]$Ctx.model.system)
    if ([string]::IsNullOrEmpty($text) -and -not $hasImg -and -not $hasSys) {
        $Ctx.status.Text = 'Enter a message, attach an image, or set a system prompt.'
        return
    }
    $prov = Get-PPLlmProviderByName $Ctx.model.provider
    if (-not $prov) { $Ctx.status.Text = 'Select a provider first (Providers...).'; return }
    $model = $Ctx.model.model
    if ([string]::IsNullOrWhiteSpace($model)) { $Ctx.status.Text = 'Enter a model.'; return }

    $imgs = @($Ctx.attachments)
    $Ctx.model.conversation = @($Ctx.model.conversation) + @(@{ role = 'user'; text = $text; images = $imgs })
    $suffix = if ($imgs.Count -gt 0) { "   [+$($imgs.Count) image(s)]" } else { '' }
    Add-PPLlmTranscript $Ctx 'You' ($text + $suffix) ([System.Drawing.Color]::FromArgb(0, 90, 158))
    $Ctx.input.Clear()
    $Ctx.attachments = @(); Update-PPLlmAttachLabel $Ctx

    $params = @{}
    if ($Ctx.model.maxTokens.Trim()) { $params.maxTokens = $Ctx.model.maxTokens.Trim() }
    if ($Ctx.model.temperature.Trim()) { $params.temperature = $Ctx.model.temperature.Trim() }
    if ($Ctx.model.thinking -and $Ctx.model.thinking -ne 'Default') { $params.thinking = $Ctx.model.thinking }

    $form = $Global:PPApp.llmForm
    $old = $form.Cursor; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $Ctx.status.ForeColor = [System.Drawing.Color]::Black
    $Ctx.status.Text = "Sending to $($prov.name) / $model ..."; $form.Refresh()
    try {
        $res = Invoke-PPLlmChat $prov $model ([string]$Ctx.model.system) $Ctx.model.conversation $params (Get-PPTimeoutSec) (Get-PPActiveVarMap)
        Show-PPLlmDetails $Ctx $res
        if ($res.ok) {
            $Ctx.model.conversation = @($Ctx.model.conversation) + @(@{ role = 'assistant'; text = $res.text; images = @() })
            Add-PPLlmTranscript $Ctx 'Assistant' $res.text ([System.Drawing.Color]::FromArgb(0, 128, 0))
            $Ctx.status.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            $Ctx.status.Text = "Done." + (Format-PPLlmUsage $res.usage)
        } else {
            Add-PPLlmTranscript $Ctx 'Error' ([string]$res.error) ([System.Drawing.Color]::DarkRed)
            $Ctx.status.ForeColor = [System.Drawing.Color]::DarkRed
            $Ctx.status.Text = 'Request failed (see Response tab).'
        }
    } finally { $form.Cursor = $old }
}

# --- build one Playground tab page ---

function New-PPLlmTabPage {
    param($Model)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Model.name; $page.UseVisualStyleBackColor = $true
    $ctx = @{ model = $Model; page = $page; attachments = @(); suppress = $false }

    # settings row
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.Height = 32; $bar.WrapContents = $false; $bar.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)
    function _l([string]$t, [int]$w) { $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $false; $l.TextAlign = 'MiddleLeft'; $l.Height = 24; $l.Width = $w; return $l }
    $providerCombo = New-Object System.Windows.Forms.ComboBox; $providerCombo.DropDownStyle = 'DropDownList'; $providerCombo.Width = 170
    $modelCombo = New-Object System.Windows.Forms.ComboBox; $modelCombo.DropDownStyle = 'DropDown'; $modelCombo.Width = 190
    $maxTokensBox = New-Object System.Windows.Forms.TextBox; $maxTokensBox.Width = 60
    $tempBox = New-Object System.Windows.Forms.TextBox; $tempBox.Width = 46
    $thinkCombo = New-Object System.Windows.Forms.ComboBox; $thinkCombo.DropDownStyle = 'DropDownList'; $thinkCombo.Width = 92
    [void]$thinkCombo.Items.AddRange(@('Default', 'Off', 'Low', 'Medium', 'High'))
    $bar.Controls.AddRange(@((_l 'Provider' 56), $providerCombo, (_l 'Model' 42), $modelCombo, (_l 'Max tok' 52), $maxTokensBox, (_l 'Temp' 38), $tempBox, (_l 'Thinking' 56), $thinkCombo))

    # system (multiline)
    $sysPanel = New-Object System.Windows.Forms.Panel; $sysPanel.Dock = 'Top'; $sysPanel.Height = 56
    $systemBox = New-Object System.Windows.Forms.TextBox; $systemBox.Dock = 'Fill'; $systemBox.Multiline = $true; $systemBox.ScrollBars = 'Vertical'; $systemBox.AcceptsReturn = $true; $systemBox.MaxLength = 0
    $sysLbl = New-Object System.Windows.Forms.Label; $sysLbl.Text = 'System:'; $sysLbl.Dock = 'Left'; $sysLbl.Width = 56; $sysLbl.TextAlign = 'TopLeft'; $sysLbl.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    $sysPanel.Controls.Add($systemBox); $sysPanel.Controls.Add($sysLbl)

    # split: chat (top) | details (bottom)
    $split = New-Object System.Windows.Forms.SplitContainer; $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterWidth = 6
    $split.Panel1MinSize = 120; $split.Panel2MinSize = 90

    # --- chat panel ---
    $transcript = New-Object System.Windows.Forms.RichTextBox
    $transcript.Dock = 'Fill'; $transcript.ReadOnly = $true; $transcript.BackColor = [System.Drawing.SystemColors]::Window; $transcript.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $chatBottom = New-Object System.Windows.Forms.Panel; $chatBottom.Dock = 'Bottom'; $chatBottom.Height = 132
    $status = New-Object System.Windows.Forms.Label; $status.Dock = 'Bottom'; $status.Height = 20; $status.Text = 'Ready.'; $status.TextAlign = 'MiddleLeft'
    $attachRow = New-Object System.Windows.Forms.Panel; $attachRow.Dock = 'Top'; $attachRow.Height = 28
    $btnAttach = New-Object System.Windows.Forms.Button; $btnAttach.Text = 'Attach image(s)'; $btnAttach.Dock = 'Left'; $btnAttach.Width = 120
    $btnClearAttach = New-Object System.Windows.Forms.Button; $btnClearAttach.Text = 'x'; $btnClearAttach.Dock = 'Left'; $btnClearAttach.Width = 28
    $attachLabel = New-Object System.Windows.Forms.Label; $attachLabel.Dock = 'Fill'; $attachLabel.TextAlign = 'MiddleLeft'; $attachLabel.Text = 'No images attached.'; $attachLabel.AutoEllipsis = $true
    $attachRow.Controls.Add($attachLabel); $attachRow.Controls.Add($btnClearAttach); $attachRow.Controls.Add($btnAttach)
    $inputArea = New-Object System.Windows.Forms.Panel; $inputArea.Dock = 'Fill'
    $input = New-Object System.Windows.Forms.TextBox; $input.Multiline = $true; $input.Dock = 'Fill'; $input.ScrollBars = 'Vertical'; $input.Font = New-Object System.Drawing.Font('Segoe UI', 10); $input.MaxLength = 0
    $sendBtn = New-Object System.Windows.Forms.Button; $sendBtn.Text = 'Send'; $sendBtn.Dock = 'Right'; $sendBtn.Width = 90
    $sendBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $sendBtn.ForeColor = [System.Drawing.Color]::White
    $inputArea.Controls.Add($input); $inputArea.Controls.Add($sendBtn)
    $chatBottom.Controls.Add($inputArea); $chatBottom.Controls.Add($attachRow); $chatBottom.Controls.Add($status)
    $split.Panel1.Controls.Add($transcript); $split.Panel1.Controls.Add($chatBottom)

    # --- details notebook ---
    $detail = New-Object System.Windows.Forms.TabControl; $detail.Dock = 'Fill'
    $pgResp = New-Object System.Windows.Forms.TabPage; $pgResp.Text = 'Response'; $pgResp.UseVisualStyleBackColor = $true
    $respStatus = New-Object System.Windows.Forms.Label; $respStatus.Dock = 'Top'; $respStatus.Height = 22; $respStatus.TextAlign = 'MiddleLeft'; $respStatus.Text = 'No response yet.'; $respStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $respBody = New-PPMultiline $true; $pgResp.Controls.Add($respBody); $pgResp.Controls.Add($respStatus)
    $pgHead = New-Object System.Windows.Forms.TabPage; $pgHead.Text = 'Resp Headers'; $pgHead.UseVisualStyleBackColor = $true
    $headGrid = New-PPReadGrid 'Header' 'Value'; $pgHead.Controls.Add($headGrid)
    $pgReq = New-Object System.Windows.Forms.TabPage; $pgReq.Text = 'Request'; $pgReq.UseVisualStyleBackColor = $true
    $reqBox = New-PPMultiline $true; $pgReq.Controls.Add($reqBox)
    [void]$detail.TabPages.Add($pgResp); [void]$detail.TabPages.Add($pgHead); [void]$detail.TabPages.Add($pgReq)
    $split.Panel2.Controls.Add($detail)

    $page.Controls.Add($split)
    $page.Controls.Add($sysPanel)
    $page.Controls.Add($bar)

    # stash refs
    $ctx.providerCombo = $providerCombo; $ctx.modelCombo = $modelCombo; $ctx.systemBox = $systemBox
    $ctx.maxTokens = $maxTokensBox; $ctx.temp = $tempBox; $ctx.thinkingCombo = $thinkCombo; $ctx.transcript = $transcript
    $ctx.input = $input; $ctx.status = $status; $ctx.attachLabel = $attachLabel; $ctx.split = $split
    $ctx.respStatus = $respStatus; $ctx.respBody = $respBody; $ctx.headGrid = $headGrid; $ctx.reqBox = $reqBox
    $page.Tag = $ctx

    Set-PPLlmControlsFromModel $ctx

    # events (control.Tag = ctx, closure-safe)
    $providerCombo.Tag = $ctx
    $providerCombo.Add_SelectedIndexChanged({
        $c = $this.Tag; if ($c.suppress) { return }
        $c.model.model = ''; Update-PPLlmModelCombo $c; Update-PPLlmThinkDefaultLabel $c
        $Global:PPApp.state.llm.activeProvider = [string]$this.SelectedItem
        $Global:PPApp.state.llm.activeModel = [string]$c.modelCombo.Text
    })
    $modelCombo.Tag = $ctx
    $modelCombo.Add_TextChanged({ Update-PPLlmThinkDefaultLabel $this.Tag })
    $btnAttach.Tag = $ctx;       $btnAttach.Add_Click({ Add-PPLlmAttachments $this.Tag })
    $btnClearAttach.Tag = $ctx;  $btnClearAttach.Add_Click({ $this.Tag.attachments = @(); Update-PPLlmAttachLabel $this.Tag })
    $sendBtn.Tag = $ctx;         $sendBtn.Add_Click({ Send-PPLlmMessage $this.Tag })
    $input.Tag = $ctx;           $input.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Send-PPLlmMessage $this.Tag } })

    return $page
}

# --- tab management ---

function Get-PPLlmCurrentCtx {
    $tc = $Global:PPApp.llmTabs
    if ($tc -and $tc.SelectedTab) { return $tc.SelectedTab.Tag }
    return $null
}

function Add-PPLlmTabPage {
    param($Model, [bool]$Select = $true)
    $page = New-PPLlmTabPage $Model
    [void]$Global:PPApp.llmTabs.TabPages.Add($page)
    if ($Select) { $Global:PPApp.llmTabs.SelectedTab = $page }
    $h = $page.Tag.split.Height
    if ($h -gt 220) { try { $page.Tag.split.SplitterDistance = [int]($h * 0.62) } catch { } }
    return $page
}

function New-PPLlmTabCmd { Add-PPLlmTabPage (New-PPLlmTab) $true | Out-Null }

function Close-PPLlmTabCmd {
    $tc = $Global:PPApp.llmTabs; $page = $tc.SelectedTab
    if (-not $page) { return }
    if ($tc.TabPages.Count -le 1) { $tc.TabPages.Remove($page); Add-PPLlmTabPage (New-PPLlmTab) $true | Out-Null; return }
    $tc.TabPages.Remove($page)
}

function Duplicate-PPLlmTabCmd {
    $ctx = Get-PPLlmCurrentCtx
    if (-not $ctx) { return }
    Sync-PPLlmCtxToModel $ctx                                   # capture current edits first
    $clone = Resolve-PPLlmTab ($ctx.model | ConvertTo-Json -Depth 20 | ConvertFrom-Json)  # deep copy
    $clone.name = $ctx.model.name + ' (copy)'
    Add-PPLlmTabPage $clone $true | Out-Null
}

function Rename-PPLlmTabCmd {
    param($Page)
    if (-not $Page) { $Page = $Global:PPApp.llmTabs.SelectedTab }
    if (-not $Page) { return }
    $ctx = $Page.Tag
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Tab name:', 'Rename chat', $ctx.model.name)
    if (-not [string]::IsNullOrWhiteSpace($name)) { $ctx.model.name = $name; $Page.Text = $name }
}

function Save-PPLlmState {
    $tabs = @()
    foreach ($page in $Global:PPApp.llmTabs.TabPages) { $ctx = $page.Tag; Sync-PPLlmCtxToModel $ctx; $tabs += $ctx.model }
    $Global:PPApp.state.llm.tabs = $tabs
    $Global:PPApp.state.llm.activeTab = $Global:PPApp.llmTabs.SelectedIndex
    $path = Save-PPState $Global:PPApp.state
    if ($Global:PPApp.statusLabel) { $Global:PPApp.statusLabel.Text = "Saved LLM state at $((Get-Date).ToString('HH:mm:ss'))" }
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
    $box.Multiline = $true; $box.Dock = 'Fill'; $box.ScrollBars = 'Both'; $box.WordWrap = $false; $box.MaxLength = 0
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
        try { $box.Text = (ConvertFrom-PPProviderFile ([System.IO.File]::ReadAllText($ofd.FileName)) | ConvertTo-Json -Depth 10) }
        catch { [System.Windows.Forms.MessageBox]::Show("Could not import that file.`n`n$($_.Exception.Message)", 'Import providers', 'OK', 'Warning') | Out-Null }
    })
    $save.Add_Click({
        try {
            $provs = @(); foreach ($e in @($box.Text | ConvertFrom-Json -ErrorAction Stop)) { $provs += (Resolve-PPLlmProvider $e) }
            if ($provs.Count -eq 0) { throw 'No providers defined.' }
            $Global:PPApp.state.llm.providers = $provs
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } catch { [System.Windows.Forms.MessageBox]::Show("Invalid provider JSON.`n`n$($_.Exception.Message)", 'Save providers', 'OK', 'Warning') | Out-Null }
    })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    $res = $dlg.ShowDialog($Global:PPApp.llmForm); $dlg.Dispose()
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-PPLlmPlayground {
    if ($Global:PPApp.llmForm -and -not $Global:PPApp.llmForm.IsDisposed) { $Global:PPApp.llmForm.Activate(); return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'LLM Playground'; $form.Size = New-Object System.Drawing.Size(900, 760); $form.StartPosition = 'CenterParent'
    $form.MinimumSize = New-Object System.Drawing.Size(600, 500)

    $toolbar = New-Object System.Windows.Forms.Panel; $toolbar.Dock = 'Top'; $toolbar.Height = 34
    $btnNew = New-PPToolbarButton 'New Chat'
    $btnClose = New-PPToolbarButton 'Close Chat'
    $btnSave = New-PPToolbarButton 'Save'
    $btnProv = New-PPToolbarButton 'Providers...'
    $toolbar.Controls.Add($btnProv); $toolbar.Controls.Add($btnSave); $toolbar.Controls.Add($btnClose); $toolbar.Controls.Add($btnNew)

    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs); $form.Controls.Add($toolbar)

    $Global:PPApp.llmForm = $form
    $Global:PPApp.llmTabs = $tabs

    foreach ($m in @($Global:PPApp.state.llm.tabs)) { Add-PPLlmTabPage $m $false | Out-Null }
    if ($tabs.TabPages.Count -eq 0) { Add-PPLlmTabPage (New-PPLlmTab) $false | Out-Null }
    $idx = [int]$Global:PPApp.state.llm.activeTab
    if ($idx -ge 0 -and $idx -lt $tabs.TabPages.Count) { $tabs.SelectedIndex = $idx }

    $btnNew.Add_Click({ New-PPLlmTabCmd })
    $btnClose.Add_Click({ Close-PPLlmTabCmd })
    $btnSave.Add_Click({ Save-PPLlmState })
    $btnProv.Add_Click({ if (Show-PPLlmProviders) { $c = Get-PPLlmCurrentCtx; if ($c) { Set-PPLlmControlsFromModel $c } } })
    $tabs.Add_MouseDoubleClick({ for ($i = 0; $i -lt $this.TabPages.Count; $i++) { if ($this.GetTabRect($i).Contains($_.Location)) { Rename-PPLlmTabCmd $this.TabPages[$i]; break } } })

    # right-click context menu on the tab strip
    $tabMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miTNew = $tabMenu.Items.Add('New Chat')
    $miTDup = $tabMenu.Items.Add('Duplicate Chat')
    $miTRen = $tabMenu.Items.Add('Rename')
    $miTClose = $tabMenu.Items.Add('Close')
    $miTNew.Add_Click({ New-PPLlmTabCmd })
    $miTDup.Add_Click({ Duplicate-PPLlmTabCmd })
    $miTRen.Add_Click({ Rename-PPLlmTabCmd $null })
    $miTClose.Add_Click({ Close-PPLlmTabCmd })
    $tabs.ContextMenuStrip = $tabMenu
    # select the tab under the cursor before the menu opens
    $tabs.Add_MouseDown({
        if ($_.Button -eq 'Right') {
            for ($i = 0; $i -lt $this.TabPages.Count; $i++) {
                if ($this.GetTabRect($i).Contains($_.Location)) { $this.SelectedIndex = $i; break }
            }
        }
    })

    $form.Add_Shown({
        foreach ($page in $Global:PPApp.llmTabs.TabPages) {
            $h = $page.Tag.split.Height
            if ($h -gt 220) { try { $page.Tag.split.SplitterDistance = [int]($h * 0.62) } catch { } }
            Update-PPLlmTranscriptView $page.Tag
        }
    })
    $tabs.Add_SelectedIndexChanged({ $c = Get-PPLlmCurrentCtx; if ($c) { Update-PPLlmTranscriptView $c } })
    # No auto-save: the user must click Save to persist the session.
    $form.Add_FormClosed({ $Global:PPApp.llmForm = $null; $Global:PPApp.llmTabs = $null })
    $form.Show($Global:PPApp.form)
}
