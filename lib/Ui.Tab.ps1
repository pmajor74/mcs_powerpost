# Ui.Tab.ps1 — build one request tab (editor + response), sync it to the model, send.

$script:PPBodyTypeToText = @{ none = 'No body'; json = 'JSON'; text = 'Text'; form = 'Form URL-encoded'; multipart = 'Multipart form-data'; graphql = 'GraphQL' }
$script:PPBodyTextToType = @{ 'No body' = 'none'; 'JSON' = 'json'; 'Text' = 'text'; 'Form URL-encoded' = 'form'; 'Multipart form-data' = 'multipart'; 'GraphQL' = 'graphql' }
$script:PPMethods = @('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')

function New-PPReadGrid {
    param([string]$Col1 = 'Key', [string]$Col2 = 'Value')
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.ReadOnly = $true; $g.AllowUserToAddRows = $false
    $g.RowHeadersVisible = $false; $g.AutoSizeColumnsMode = 'Fill'
    $g.SelectionMode = 'FullRowSelect'; $g.BackgroundColor = [System.Drawing.SystemColors]::Window
    $c1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c1.HeaderText = $Col1; $c1.FillWeight = 35
    $c2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c2.HeaderText = $Col2; $c2.FillWeight = 65
    [void]$g.Columns.Add($c1); [void]$g.Columns.Add($c2)
    return $g
}

function New-PPMultiline {
    param([bool]$ReadOnly = $false)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.Dock = 'Fill'; $tb.ScrollBars = 'Both'
    $tb.WordWrap = $false; $tb.AcceptsTab = $true; $tb.Font = $script:PPMono
    $tb.ReadOnly = $ReadOnly
    $tb.HideSelection = $false   # keep search highlight visible when focus leaves the box
    return $tb
}

# Find the next/prev occurrence of the find term in the active response sub-tab's text box.
function Find-PPResponseMatch {
    param($Ctx, [int]$Dir = 1)
    $idx = $Ctx.respTabs.SelectedIndex
    $box = switch ($idx) { 0 { $Ctx.respBodyBox } 1 { $Ctx.respRawBox } 3 { $Ctx.respReqBox } default { $null } }
    if (-not $box) { $Ctx.findStatus.Text = '(no text)'; return }
    $term = $Ctx.findBox.Text
    if ([string]::IsNullOrEmpty($term)) { $Ctx.findStatus.Text = ''; return }
    $text = [string]$box.Text
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if ($text.Length -eq 0) { $Ctx.findStatus.Text = 'no match'; return }
    $pos = -1
    if ($Dir -ge 0) {
        # Start at the end of the current selection (0 when nothing is selected, so a fresh
        # Find catches a match at position 0). A prior match has SelectionLength > 0, so we advance.
        $from = $box.SelectionStart + $box.SelectionLength
        if ($from -gt $text.Length) { $from = 0 }
        $pos = $text.IndexOf($term, $from, $cmp)
        if ($pos -lt 0) { $pos = $text.IndexOf($term, 0, $cmp) }
    } else {
        $before = $box.SelectionStart - 1
        if ($before -lt 0) { $before = $text.Length - 1 }
        if ($before -ge 0) { $pos = $text.LastIndexOf($term, [Math]::Min($before, $text.Length - 1), $cmp) }
        if ($pos -lt 0) { $pos = $text.LastIndexOf($term, $text.Length - 1, $cmp) }
    }
    if ($pos -ge 0) {
        $box.Select($pos, $term.Length); $box.ScrollToCaret()
        $count = 0; $i = 0
        while (($i = $text.IndexOf($term, $i, $cmp)) -ge 0) { $count++; $i += $term.Length }
        $Ctx.findStatus.Text = "$count match(es)"
    } else { $Ctx.findStatus.Text = 'no match' }
}

function New-PPRequestTab {
    param($Model)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Model.name
    $page.UseVisualStyleBackColor = $true

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterWidth = 6

    $ctx = @{ model = $Model; page = $page }

    # ---------- request editor (top) ----------
    $topBar = New-Object System.Windows.Forms.TableLayoutPanel
    $topBar.Dock = 'Top'; $topBar.Height = 30; $topBar.ColumnCount = 3; $topBar.RowCount = 1
    [void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 95)))
    [void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))

    $methodCombo = New-Object System.Windows.Forms.ComboBox
    $methodCombo.DropDownStyle = 'DropDownList'; $methodCombo.Dock = 'Fill'
    [void]$methodCombo.Items.AddRange($script:PPMethods)
    $urlBox = New-Object System.Windows.Forms.TextBox; $urlBox.Dock = 'Fill'
    $sendBtn = New-Object System.Windows.Forms.Button; $sendBtn.Text = 'Send'; $sendBtn.Dock = 'Fill'
    $sendBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $sendBtn.ForeColor = [System.Drawing.Color]::White
    $topBar.Controls.Add($methodCombo, 0, 0)
    $topBar.Controls.Add($urlBox, 1, 0)
    $topBar.Controls.Add($sendBtn, 2, 0)

    $innerTabs = New-Object System.Windows.Forms.TabControl; $innerTabs.Dock = 'Fill'

    $pgParams = New-Object System.Windows.Forms.TabPage; $pgParams.Text = 'Params'; $pgParams.UseVisualStyleBackColor = $true
    $paramsEditor = New-PPKvEditor; $paramsGrid = $paramsEditor.grid; $pgParams.Controls.Add($paramsEditor.panel)

    $pgHeaders = New-Object System.Windows.Forms.TabPage; $pgHeaders.Text = 'Headers'; $pgHeaders.UseVisualStyleBackColor = $true
    $headersEditor = New-PPKvEditor; $headersGrid = $headersEditor.grid; $pgHeaders.Controls.Add($headersEditor.panel)

    $pgBody = New-Object System.Windows.Forms.TabPage; $pgBody.Text = 'Body'; $pgBody.UseVisualStyleBackColor = $true
    $bodyTypeCombo = New-Object System.Windows.Forms.ComboBox; $bodyTypeCombo.DropDownStyle = 'DropDownList'; $bodyTypeCombo.Dock = 'Top'
    [void]$bodyTypeCombo.Items.AddRange(@('No body', 'JSON', 'Text', 'Form URL-encoded', 'Multipart form-data', 'GraphQL'))
    $bodyCards = New-Object System.Windows.Forms.Panel; $bodyCards.Dock = 'Fill'
    $bodyBox = New-PPMultiline; $formGrid = New-PPKvGrid; $multipartGrid = New-PPMultipartGrid
    # GraphQL card: query (fill) + variables (bottom, JSON)
    $gqlPanel = New-Object System.Windows.Forms.Panel; $gqlPanel.Dock = 'Fill'
    $gqlQuery = New-PPMultiline
    $gqlVarsBox = New-PPMultiline; $gqlVarsBox.Dock = 'Bottom'; $gqlVarsBox.Height = 110
    $gqlVarsLbl = New-Object System.Windows.Forms.Label; $gqlVarsLbl.Text = 'Variables (JSON)'; $gqlVarsLbl.Dock = 'Bottom'; $gqlVarsLbl.Height = 18
    $gqlPanel.Controls.Add($gqlQuery); $gqlPanel.Controls.Add($gqlVarsLbl); $gqlPanel.Controls.Add($gqlVarsBox)
    $bodyCards.Controls.Add($bodyBox); $bodyCards.Controls.Add($formGrid); $bodyCards.Controls.Add($multipartGrid); $bodyCards.Controls.Add($gqlPanel)
    $pgBody.Controls.Add($bodyCards); $pgBody.Controls.Add($bodyTypeCombo)

    $pgAuth = New-Object System.Windows.Forms.TabPage; $pgAuth.Text = 'Auth'; $pgAuth.UseVisualStyleBackColor = $true
    $authBuilt = New-PPAuthPanel; $pgAuth.Controls.Add($authBuilt.panel)

    [void]$innerTabs.TabPages.Add($pgParams)
    [void]$innerTabs.TabPages.Add($pgHeaders)
    [void]$innerTabs.TabPages.Add($pgBody)
    [void]$innerTabs.TabPages.Add($pgAuth)

    $split.Panel1.Controls.Add($innerTabs)
    $split.Panel1.Controls.Add($topBar)

    # ---------- response (bottom) ----------
    $respStatus = New-Object System.Windows.Forms.Label
    $respStatus.Dock = 'Top'; $respStatus.Height = 24; $respStatus.TextAlign = 'MiddleLeft'
    $respStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $respStatus.Text = 'No response yet.'

    $respBar = New-Object System.Windows.Forms.Panel; $respBar.Dock = 'Top'; $respBar.Height = 28
    $copyBtn = New-Object System.Windows.Forms.Button; $copyBtn.Text = 'Copy'; $copyBtn.Dock = 'Left'; $copyBtn.Width = 70
    $saveBtn = New-Object System.Windows.Forms.Button; $saveBtn.Text = 'Save...'; $saveBtn.Dock = 'Left'; $saveBtn.Width = 70
    # find-in-response (searches the active Body/Raw/Request sub-tab)
    $findNext = New-Object System.Windows.Forms.Button; $findNext.Text = "Find $([char]0x25BC)"; $findNext.Dock = 'Right'; $findNext.Width = 62
    $findPrev = New-Object System.Windows.Forms.Button; $findPrev.Text = "Find $([char]0x25B2)"; $findPrev.Dock = 'Right'; $findPrev.Width = 62
    $findBox = New-Object System.Windows.Forms.TextBox; $findBox.Dock = 'Right'; $findBox.Width = 180
    $findStatus = New-Object System.Windows.Forms.Label; $findStatus.Dock = 'Right'; $findStatus.Width = 86; $findStatus.TextAlign = 'MiddleRight'
    $respBar.Controls.Add($saveBtn); $respBar.Controls.Add($copyBtn)
    $respBar.Controls.Add($findNext); $respBar.Controls.Add($findPrev); $respBar.Controls.Add($findBox); $respBar.Controls.Add($findStatus)

    $respTabs = New-Object System.Windows.Forms.TabControl; $respTabs.Dock = 'Fill'
    $pgRBody = New-Object System.Windows.Forms.TabPage; $pgRBody.Text = 'Body'; $pgRBody.UseVisualStyleBackColor = $true
    $respBodyBox = New-PPMultiline $true; $pgRBody.Controls.Add($respBodyBox)
    $pgRRaw = New-Object System.Windows.Forms.TabPage; $pgRRaw.Text = 'Raw'; $pgRRaw.UseVisualStyleBackColor = $true
    $respRawBox = New-PPMultiline $true; $pgRRaw.Controls.Add($respRawBox)
    $pgRHead = New-Object System.Windows.Forms.TabPage; $pgRHead.Text = 'Headers'; $pgRHead.UseVisualStyleBackColor = $true
    $respHeadGrid = New-PPReadGrid 'Header' 'Value'; $pgRHead.Controls.Add($respHeadGrid)
    $pgReq = New-Object System.Windows.Forms.TabPage; $pgReq.Text = 'Request'; $pgReq.UseVisualStyleBackColor = $true
    $respReqBox = New-PPMultiline $true; $pgReq.Controls.Add($respReqBox)
    [void]$respTabs.TabPages.Add($pgRBody); [void]$respTabs.TabPages.Add($pgRRaw); [void]$respTabs.TabPages.Add($pgRHead); [void]$respTabs.TabPages.Add($pgReq)

    $split.Panel2.Controls.Add($respTabs)
    $split.Panel2.Controls.Add($respBar)
    $split.Panel2.Controls.Add($respStatus)

    $page.Controls.Add($split)

    # ---------- stash refs ----------
    $ctx.methodCombo = $methodCombo; $ctx.urlBox = $urlBox; $ctx.sendBtn = $sendBtn
    $ctx.paramsGrid = $paramsGrid; $ctx.headersGrid = $headersGrid
    $ctx.paramsEditor = $paramsEditor; $ctx.headersEditor = $headersEditor
    $ctx.bodyTypeCombo = $bodyTypeCombo; $ctx.bodyBox = $bodyBox; $ctx.formGrid = $formGrid; $ctx.multipartGrid = $multipartGrid
    $ctx.gqlPanel = $gqlPanel; $ctx.gqlQuery = $gqlQuery; $ctx.gqlVarsBox = $gqlVarsBox
    $ctx.auth = $authBuilt
    $ctx.respStatus = $respStatus; $ctx.respBodyBox = $respBodyBox; $ctx.respRawBox = $respRawBox; $ctx.respHeadGrid = $respHeadGrid; $ctx.respReqBox = $respReqBox
    $ctx.respTabs = $respTabs; $ctx.findBox = $findBox; $ctx.findStatus = $findStatus
    $ctx.split = $split
    $page.Tag = $ctx

    Set-PPControlsFromModel $ctx

    # ---------- events (use control.Tag = $ctx to stay closure-safe) ----------
    $sendBtn.Tag = $ctx
    $sendBtn.Add_Click({ Invoke-PPSend $this.Tag })

    $bodyTypeCombo.Tag = $ctx
    $bodyTypeCombo.Add_SelectedIndexChanged({ Update-PPBodyCard $this.Tag })

    $authBuilt.refs.typeCombo.Tag = $ctx
    $authBuilt.refs.typeCombo.Add_SelectedIndexChanged({
        $c = $this.Tag
        Show-PPAuthCard $c.auth.refs $script:PPAuthTextToType[[string]$this.SelectedItem]
    })

    $authBuilt.refs.ccGetBtn.Tag = $ctx
    $authBuilt.refs.ccGetBtn.Add_Click({ Invoke-PPGetToken $this.Tag 'clientcreds' })
    $authBuilt.refs.acGetBtn.Tag = $ctx
    $authBuilt.refs.acGetBtn.Add_Click({ Invoke-PPGetToken $this.Tag 'authcode' })

    $copyBtn.Tag = $ctx
    $copyBtn.Add_Click({
        $c = $this.Tag
        if ($c.respBodyBox.Text) { [System.Windows.Forms.Clipboard]::SetText($c.respBodyBox.Text) }
    })
    $saveBtn.Tag = $ctx
    $saveBtn.Add_Click({ Save-PPResponseToFile $this.Tag })

    $findNext.Tag = $ctx; $findNext.Add_Click({ Find-PPResponseMatch $this.Tag 1 })
    $findPrev.Tag = $ctx; $findPrev.Add_Click({ Find-PPResponseMatch $this.Tag -1 })
    $findBox.Tag = $ctx
    $findBox.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Find-PPResponseMatch $this.Tag 1 } })

    $urlBox.Tag = $ctx
    $urlBox.Add_KeyDown({
        if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; Invoke-PPSend $this.Tag }
    })

    # SplitterDistance is applied later (in the form's Shown handler) once the
    # container has a real height — setting it before that throws.
    $split.Panel1MinSize = 120; $split.Panel2MinSize = 120
    return $page
}

# ---- model <-> controls ----

function Set-PPControlsFromModel {
    param($Ctx)
    $m = $Ctx.model
    if ($script:PPMethods -notcontains $m.method) { [void]$Ctx.methodCombo.Items.Add($m.method) }
    $Ctx.methodCombo.SelectedItem = $m.method
    $Ctx.urlBox.Text = $m.url
    Set-PPKvEditor $Ctx.paramsEditor $m.params
    Set-PPKvEditor $Ctx.headersEditor $m.headers
    $Ctx.bodyTypeCombo.SelectedItem = $script:PPBodyTypeToText[$m.bodyType]
    $Ctx.bodyBox.Text = $m.body
    $Ctx.gqlQuery.Text = $m.body
    $Ctx.gqlVarsBox.Text = $m.graphqlVars
    Set-PPKvGrid $Ctx.formGrid $m.form
    Set-PPMultipartGrid $Ctx.multipartGrid $m.multipart

    Set-PPAuthRefs $Ctx.auth.refs $m.auth
    Update-PPBodyCard $Ctx
}

function Sync-PPTabToModel {
    param($Ctx)
    $m = $Ctx.model
    $m.method = [string]$Ctx.methodCombo.SelectedItem
    $m.url = $Ctx.urlBox.Text
    $m.params = Get-PPKvEditorRows $Ctx.paramsEditor
    $m.headers = Get-PPKvEditorRows $Ctx.headersEditor
    $m.bodyType = $script:PPBodyTextToType[[string]$Ctx.bodyTypeCombo.SelectedItem]
    $m.graphqlVars = $Ctx.gqlVarsBox.Text
    $m.body = if ($m.bodyType -eq 'graphql') { $Ctx.gqlQuery.Text } else { $Ctx.bodyBox.Text }
    $m.form = Get-PPKvGrid $Ctx.formGrid
    $m.multipart = Get-PPMultipartGrid $Ctx.multipartGrid
    Sync-PPAuthToModel $Ctx
    $Ctx.page.Text = $m.name
}

function Sync-PPAuthToModel {
    param($Ctx)
    Set-PPAuthModel $Ctx.model.auth $Ctx.auth.refs
}

function Update-PPBodyCard {
    param($Ctx)
    $type = $script:PPBodyTextToType[[string]$Ctx.bodyTypeCombo.SelectedItem]
    $showText = ($type -eq 'json' -or $type -eq 'text')
    $Ctx.bodyBox.Visible = $showText
    $Ctx.formGrid.Visible = ($type -eq 'form')
    $Ctx.multipartGrid.Visible = ($type -eq 'multipart')
    $Ctx.gqlPanel.Visible = ($type -eq 'graphql')
    if ($showText) { $Ctx.bodyBox.BringToFront() }
    elseif ($type -eq 'form') { $Ctx.formGrid.BringToFront() }
    elseif ($type -eq 'multipart') { $Ctx.multipartGrid.BringToFront() }
    elseif ($type -eq 'graphql') { $Ctx.gqlPanel.BringToFront() }
}
