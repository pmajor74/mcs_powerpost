# Ui.Controls.ps1 — small reusable WinForms builders (grids, labeled fields, auth panel).

$script:PPMono = New-Object System.Drawing.Font('Consolas', 9.5)

# --- key/value grid (params, headers, form body) ---

function New-PPKvGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $true
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.AutoSizeColumnsMode = 'Fill'
    $g.SelectionMode = 'CellSelect'
    $g.EditMode = 'EditOnKeystrokeOrF2'
    $g.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colEnabled = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colEnabled.HeaderText = 'On'; $colEnabled.FillWeight = 10; $colEnabled.Name = 'Enabled'
    $colKey = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colKey.HeaderText = 'Key'; $colKey.FillWeight = 45; $colKey.Name = 'Key'
    $colVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colVal.HeaderText = 'Value'; $colVal.FillWeight = 45; $colVal.Name = 'Value'
    [void]$g.Columns.Add($colEnabled)
    [void]$g.Columns.Add($colKey)
    [void]$g.Columns.Add($colVal)
    return $g
}

function Set-PPKvGrid {
    param($Grid, $Rows)
    $Grid.Rows.Clear()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        [void]$Grid.Rows.Add([bool]$r.enabled, [string]$r.key, [string]$r.value)
    }
}

function Get-PPKvGrid {
    param($Grid)
    $list = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $k = [string]$row.Cells['Key'].Value
        $v = [string]$row.Cells['Value'].Value
        if ([string]::IsNullOrEmpty($k) -and [string]::IsNullOrEmpty($v)) { continue }
        $eCell = $row.Cells['Enabled'].Value
        $e = if ($null -eq $eCell) { $true } else { [bool]$eCell }
        $list += @{ enabled = $e; key = $k; value = $v }
    }
    return , $list
}

# A key/value editor: a grid plus a "Bulk edit" toggle that swaps it for a text box
# (one "key: value" per line; "//" prefix disables a row). Returns @{ panel; grid; bulk; toggle }.
function New-PPKvEditor {
    $panel = New-Object System.Windows.Forms.Panel; $panel.Dock = 'Fill'
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = 'Top'; $bar.Height = 24
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = 'Bulk edit'; $chk.Dock = 'Left'; $chk.Width = 84
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'one per line:  key: value   (prefix // to disable)'; $hint.Dock = 'Fill'; $hint.TextAlign = 'MiddleLeft'; $hint.ForeColor = [System.Drawing.Color]::Gray
    $bar.Controls.Add($hint); $bar.Controls.Add($chk)
    $card = New-Object System.Windows.Forms.Panel; $card.Dock = 'Fill'
    $grid = New-PPKvGrid
    $bulk = New-PPMultiline
    $bulk.Visible = $false
    $card.Controls.Add($grid); $card.Controls.Add($bulk)
    $panel.Controls.Add($card); $panel.Controls.Add($bar)

    $editor = @{ panel = $panel; grid = $grid; bulk = $bulk; toggle = $chk }
    $chk.Tag = $editor
    $chk.Add_CheckedChanged({
        $e = $this.Tag
        if ($this.Checked) {
            $e.bulk.Text = ConvertTo-PPKvText (Get-PPKvGrid $e.grid)
            $e.grid.Visible = $false; $e.bulk.Visible = $true; $e.bulk.BringToFront()
        } else {
            Set-PPKvGrid $e.grid (ConvertFrom-PPKvText $e.bulk.Text)
            $e.bulk.Visible = $false; $e.grid.Visible = $true; $e.grid.BringToFront()
        }
    })
    return $editor
}

# Read rows from a KV editor, honoring whichever view (grid or bulk text) is active.
function Get-PPKvEditorRows {
    param($Editor)
    if ($Editor.toggle.Checked) { return ConvertFrom-PPKvText $Editor.bulk.Text }
    return Get-PPKvGrid $Editor.grid
}

# Load rows into a KV editor (updates the active view too).
function Set-PPKvEditor {
    param($Editor, $Rows)
    Set-PPKvGrid $Editor.grid $Rows
    if ($Editor.toggle.Checked) { $Editor.bulk.Text = ConvertTo-PPKvText $Rows }
}

# --- post-response tests grid (On | Source | Path | Op | Expected) ---
function New-PPTestGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.AllowUserToAddRows = $true; $g.RowHeadersVisible = $false
    $g.AutoSizeColumnsMode = 'Fill'; $g.EditMode = 'EditOnEnter'; $g.BackgroundColor = [System.Drawing.SystemColors]::Window
    $cOn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $cOn.Name = 'On'; $cOn.HeaderText = 'On'; $cOn.Width = 36; $cOn.FillWeight = 7; $cOn.AutoSizeMode = 'None'
    $cSrc = New-Object System.Windows.Forms.DataGridViewComboBoxColumn; $cSrc.Name = 'Source'; $cSrc.HeaderText = 'Source'; $cSrc.FillWeight = 16; $cSrc.FlatStyle = 'Flat'
    [void]$cSrc.Items.AddRange(@('status', 'time', 'body', 'header', 'rawBody'))
    $cPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cPath.Name = 'Path'; $cPath.HeaderText = 'Path / header'; $cPath.FillWeight = 26
    $cOp = New-Object System.Windows.Forms.DataGridViewComboBoxColumn; $cOp.Name = 'Op'; $cOp.HeaderText = 'Op'; $cOp.FillWeight = 18; $cOp.FlatStyle = 'Flat'
    [void]$cOp.Items.AddRange(@('equals', 'notEquals', 'contains', 'notContains', 'lessThan', 'greaterThan', 'exists', 'notExists', 'matches'))
    $cVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cVal.Name = 'Value'; $cVal.HeaderText = 'Expected'; $cVal.FillWeight = 25
    [void]$g.Columns.AddRange($cOn, $cSrc, $cPath, $cOp, $cVal)
    $g.Add_DataError({ param($s, $e) $e.ThrowException = $false })   # tolerate combo cells not yet in Items
    return $g
}

function Set-PPTestGrid {
    param($Grid, $Tests)
    $Grid.Rows.Clear()
    foreach ($t in @($Tests)) {
        if ($null -eq $t) { continue }
        [void]$Grid.Rows.Add([bool]$t.enabled, [string]$t.source, [string]$t.path, [string]$t.op, [string]$t.value)
    }
}

function Get-PPTestGrid {
    param($Grid)
    $list = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $src = [string]$row.Cells['Source'].Value
        $op = [string]$row.Cells['Op'].Value
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        if ([string]::IsNullOrWhiteSpace($op)) { $op = 'equals' }
        $en = $row.Cells['On'].Value
        $list += (New-PPTest ([bool]$en) $src ([string]$row.Cells['Path'].Value) $op ([string]$row.Cells['Value'].Value))
    }
    return , $list
}

# --- multipart/form-data grid (text or file fields) ---

function New-PPMultipartGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $true
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.AutoSizeColumnsMode = 'Fill'
    $g.SelectionMode = 'CellSelect'
    $g.EditMode = 'EditOnKeystrokeOrF2'
    $g.BackgroundColor = [System.Drawing.SystemColors]::Window

    $colEnabled = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colEnabled.HeaderText = 'On'; $colEnabled.FillWeight = 8; $colEnabled.Name = 'Enabled'
    $colKey = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colKey.HeaderText = 'Key'; $colKey.FillWeight = 26; $colKey.Name = 'Key'
    $colType = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colType.HeaderText = 'Type'; $colType.FillWeight = 16; $colType.Name = 'Type'; $colType.FlatStyle = 'Flat'
    [void]$colType.Items.AddRange(@('Text', 'File'))
    $colVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colVal.HeaderText = 'Value / File path'; $colVal.FillWeight = 42; $colVal.Name = 'Value'
    $colBrowse = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colBrowse.HeaderText = ''; $colBrowse.FillWeight = 8; $colBrowse.Name = 'Browse'
    $colBrowse.Text = '...'; $colBrowse.UseColumnTextForButtonValue = $true

    [void]$g.Columns.Add($colEnabled)
    [void]$g.Columns.Add($colKey)
    [void]$g.Columns.Add($colType)
    [void]$g.Columns.Add($colVal)
    [void]$g.Columns.Add($colBrowse)

    # Combo cells raise DataError noise for empty/new rows — ignore it.
    $g.Add_DataError({})
    # The "..." button opens a file picker and flips the row to a File field.
    $g.Add_CellContentClick({
        if ($_.RowIndex -lt 0) { return }
        if ($this.Columns[$_.ColumnIndex].Name -ne 'Browse') { return }
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $this.Rows[$_.RowIndex].Cells['Value'].Value = $ofd.FileName
            $this.Rows[$_.RowIndex].Cells['Type'].Value = 'File'
        }
    })
    return $g
}

function Set-PPMultipartGrid {
    param($Grid, $Rows)
    $Grid.Rows.Clear()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $type = if ($r.kind -eq 'file') { 'File' } else { 'Text' }
        [void]$Grid.Rows.Add([bool]$r.enabled, [string]$r.key, $type, [string]$r.value)
    }
}

function Get-PPMultipartGrid {
    param($Grid)
    $list = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) { continue }
        $k = [string]$row.Cells['Key'].Value
        $v = [string]$row.Cells['Value'].Value
        if ([string]::IsNullOrEmpty($k) -and [string]::IsNullOrEmpty($v)) { continue }
        $eCell = $row.Cells['Enabled'].Value
        $e = if ($null -eq $eCell) { $true } else { [bool]$eCell }
        $kind = if (([string]$row.Cells['Type'].Value) -eq 'File') { 'file' } else { 'text' }
        $list += @{ enabled = $e; key = $k; kind = $kind; value = $v }
    }
    return , $list
}

# --- labeled-field tables for the auth panels ---

function New-PPFieldTable {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = 2
    $t.Dock = 'Fill'
    $t.AutoScroll = $true
    $t.Padding = New-Object System.Windows.Forms.Padding(4)
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    return $t
}

function Add-PPFieldRow {
    param($Table, [string]$LabelText, $Control, [int]$Height = 28)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $LabelText
    $l.Dock = 'Fill'
    $l.TextAlign = $(if ($Height -gt 28) { 'TopLeft' } else { 'MiddleLeft' })
    $Control.Dock = 'Fill'
    $r = $Table.RowCount
    [void]$Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $Height)))
    $Table.Controls.Add($l, 0, $r)
    $Table.Controls.Add($Control, 1, $r)
    $Table.RowCount = $r + 1
}

function New-PPTextBox {
    param([string]$Text = '', [char]$PasswordChar = [char]0)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Text
    if ($PasswordChar -ne [char]0) { $tb.UseSystemPasswordChar = $true }
    return $tb
}

# Build the Auth tab content. Returns @{ panel; refs } where refs holds every control
# the sync/handlers need. One stacked panel per auth type; only the selected is visible.
function New-PPAuthPanel {
    # NB: avoid $host (a PowerShell automatic variable) as a control name.
    $root = New-Object System.Windows.Forms.Panel
    $root.Dock = 'Fill'

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Dock = 'Top'
    $combo.DropDownStyle = 'DropDownList'
    [void]$combo.Items.AddRange(@('None', 'Bearer / JWT', 'Basic', 'OAuth2 Client Credentials', 'OAuth2 Authorization Code', 'Google Service Account (Vertex)', 'Inherit (collection)'))

    $cards = New-Object System.Windows.Forms.Panel
    $cards.Dock = 'Fill'

    $refs = @{ typeCombo = $combo; cards = $cards; panels = @{} }

    # None
    $pNone = New-Object System.Windows.Forms.Panel; $pNone.Dock = 'Fill'
    $lblNone = New-Object System.Windows.Forms.Label
    $lblNone.Text = 'No authentication will be sent.'; $lblNone.Dock = 'Top'; $lblNone.Padding = New-Object System.Windows.Forms.Padding(6)
    $pNone.Controls.Add($lblNone)
    $refs.panels['none'] = $pNone

    # Inherit (collection)
    $pInherit = New-Object System.Windows.Forms.Panel; $pInherit.Dock = 'Fill'
    $lblInherit = New-Object System.Windows.Forms.Label
    $lblInherit.Text = "Uses the parent collection's auth (resolved when this request is opened from a collection)."
    $lblInherit.Dock = 'Top'; $lblInherit.Height = 44; $lblInherit.Padding = New-Object System.Windows.Forms.Padding(6)
    $pInherit.Controls.Add($lblInherit)
    $refs.panels['inherit'] = $pInherit

    # Bearer
    $pBearer = New-PPFieldTable
    $refs.bearerBox = New-PPTextBox
    Add-PPFieldRow $pBearer 'Token' $refs.bearerBox
    $refs.panels['bearer'] = $pBearer

    # Basic
    $pBasic = New-PPFieldTable
    $refs.basicUser = New-PPTextBox
    $refs.basicPass = New-PPTextBox '' '*'
    Add-PPFieldRow $pBasic 'Username' $refs.basicUser
    Add-PPFieldRow $pBasic 'Password' $refs.basicPass
    $refs.panels['basic'] = $pBasic

    # Client credentials
    $pCc = New-PPFieldTable
    $refs.ccTokenUrl     = New-PPTextBox
    $refs.ccClientId     = New-PPTextBox
    $refs.ccClientSecret = New-PPTextBox '' '*'
    $refs.ccScope        = New-PPTextBox
    $refs.ccStyle = New-Object System.Windows.Forms.ComboBox
    $refs.ccStyle.DropDownStyle = 'DropDownList'
    [void]$refs.ccStyle.Items.AddRange(@('Send in body', 'Basic auth header'))
    $refs.ccGetBtn = New-Object System.Windows.Forms.Button; $refs.ccGetBtn.Text = 'Get Token'
    $refs.ccStatus = New-Object System.Windows.Forms.Label; $refs.ccStatus.AutoEllipsis = $true
    Add-PPFieldRow $pCc 'Token URL'      $refs.ccTokenUrl
    Add-PPFieldRow $pCc 'Client ID'      $refs.ccClientId
    Add-PPFieldRow $pCc 'Client Secret'  $refs.ccClientSecret
    Add-PPFieldRow $pCc 'Scope'          $refs.ccScope
    Add-PPFieldRow $pCc 'Credentials in' $refs.ccStyle
    Add-PPFieldRow $pCc ''               $refs.ccGetBtn
    Add-PPFieldRow $pCc 'Status'         $refs.ccStatus
    $refs.panels['clientcreds'] = $pCc

    # Authorization code
    $pAc = New-PPFieldTable
    $refs.acAuthUrl      = New-PPTextBox
    $refs.acTokenUrl     = New-PPTextBox
    $refs.acClientId     = New-PPTextBox
    $refs.acClientSecret = New-PPTextBox '' '*'
    $refs.acScope        = New-PPTextBox
    $refs.acPort         = New-PPTextBox '8080'
    $refs.acPkce = New-Object System.Windows.Forms.CheckBox; $refs.acPkce.Text = 'Use PKCE (S256)'
    $refs.acGetBtn = New-Object System.Windows.Forms.Button; $refs.acGetBtn.Text = 'Get Token'
    $refs.acStatus = New-Object System.Windows.Forms.Label; $refs.acStatus.AutoEllipsis = $true
    Add-PPFieldRow $pAc 'Authorize URL'  $refs.acAuthUrl
    Add-PPFieldRow $pAc 'Token URL'      $refs.acTokenUrl
    Add-PPFieldRow $pAc 'Client ID'      $refs.acClientId
    Add-PPFieldRow $pAc 'Client Secret'  $refs.acClientSecret
    Add-PPFieldRow $pAc 'Scope'          $refs.acScope
    Add-PPFieldRow $pAc 'Redirect Port'  $refs.acPort
    Add-PPFieldRow $pAc ''               $refs.acPkce
    Add-PPFieldRow $pAc ''               $refs.acGetBtn
    Add-PPFieldRow $pAc 'Status'         $refs.acStatus
    $refs.panels['authcode'] = $pAc

    # Google service account (Vertex): paste the service-account email + PKCS#8 PEM private
    # key (or load a vertex-credentials.json). PowerPost RS256-signs a JWT and exchanges it
    # for a short-lived cloud-platform OAuth token, attached as a Bearer header.
    $pVx = New-PPFieldTable
    $refs.vxClientEmail = New-PPTextBox
    $refs.vxPrivateKey = New-Object System.Windows.Forms.TextBox
    $refs.vxPrivateKey.Multiline = $true; $refs.vxPrivateKey.ScrollBars = 'Vertical'
    $refs.vxPrivateKey.WordWrap = $false; $refs.vxPrivateKey.AcceptsReturn = $true
    $refs.vxPrivateKey.MaxLength = 0; $refs.vxPrivateKey.Font = $script:PPMono
    $refs.vxLoadBtn = New-Object System.Windows.Forms.Button; $refs.vxLoadBtn.Text = 'Load credentials JSON...'
    $refs.vxGetBtn = New-Object System.Windows.Forms.Button; $refs.vxGetBtn.Text = 'Get Token'
    $refs.vxStatus = New-Object System.Windows.Forms.Label; $refs.vxStatus.AutoEllipsis = $true
    Add-PPFieldRow $pVx 'Client Email'   $refs.vxClientEmail
    Add-PPFieldRow $pVx 'Private Key'    $refs.vxPrivateKey 132
    Add-PPFieldRow $pVx ''               $refs.vxLoadBtn
    Add-PPFieldRow $pVx ''               $refs.vxGetBtn
    Add-PPFieldRow $pVx 'Status'         $refs.vxStatus
    $refs.panels['vertex'] = $pVx

    foreach ($key in $refs.panels.Keys) {
        $p = $refs.panels[$key]
        $p.Visible = $false
        $cards.Controls.Add($p)
    }

    $root.Controls.Add($cards)
    $root.Controls.Add($combo)
    return @{ panel = $root; refs = $refs }
}

# Map between the friendly combo text and the internal auth type code.
$script:PPAuthTypeToText = @{
    'none' = 'None'; 'bearer' = 'Bearer / JWT'; 'basic' = 'Basic'
    'clientcreds' = 'OAuth2 Client Credentials'; 'authcode' = 'OAuth2 Authorization Code'
    'vertex' = 'Google Service Account (Vertex)'; 'inherit' = 'Inherit (collection)'
}
$script:PPAuthTextToType = @{
    'None' = 'none'; 'Bearer / JWT' = 'bearer'; 'Basic' = 'basic'
    'OAuth2 Client Credentials' = 'clientcreds'; 'OAuth2 Authorization Code' = 'authcode'
    'Google Service Account (Vertex)' = 'vertex'; 'Inherit (collection)' = 'inherit'
}

function Show-PPAuthCard {
    param($Refs, [string]$Type)
    foreach ($key in $Refs.panels.Keys) {
        $vis = ($key -eq $Type)
        $Refs.panels[$key].Visible = $vis
        if ($vis) { $Refs.panels[$key].BringToFront() }
    }
}

# Populate an auth panel's controls from an auth model (reused by request tabs + the
# collection-auth dialog).
function Set-PPAuthRefs {
    param($Refs, $Auth)
    $Refs.typeCombo.SelectedItem = $script:PPAuthTypeToText[$Auth.type]
    $Refs.bearerBox.Text = $Auth.bearerToken
    $Refs.basicUser.Text = $Auth.basicUser; $Refs.basicPass.Text = $Auth.basicPass
    $Refs.ccTokenUrl.Text = $Auth.tokenUrl; $Refs.ccClientId.Text = $Auth.clientId
    $Refs.ccClientSecret.Text = $Auth.clientSecret; $Refs.ccScope.Text = $Auth.scope
    $Refs.ccStyle.SelectedIndex = $(if ($Auth.clientAuthStyle -eq 'header') { 1 } else { 0 })
    $Refs.acAuthUrl.Text = $Auth.authUrl; $Refs.acTokenUrl.Text = $Auth.tokenUrl; $Refs.acClientId.Text = $Auth.clientId
    $Refs.acClientSecret.Text = $Auth.clientSecret; $Refs.acScope.Text = $Auth.scope
    $Refs.acPort.Text = [string]$Auth.redirectPort; $Refs.acPkce.Checked = [bool]$Auth.usePkce
    $Refs.vxClientEmail.Text = $Auth.clientEmail; $Refs.vxPrivateKey.Text = $Auth.privateKey
    if ($Auth.accessToken) { $Refs.ccStatus.Text = 'Cached token present.'; $Refs.acStatus.Text = 'Cached token present.'; $Refs.vxStatus.Text = 'Cached token present.' }
    Show-PPAuthCard $Refs $Auth.type
}

# Read an auth panel's controls back into an auth model (mutates $Auth in place so cached
# token fields are preserved).
function Set-PPAuthModel {
    param($Auth, $Refs)
    $Auth.type = $script:PPAuthTextToType[[string]$Refs.typeCombo.SelectedItem]
    $Auth.bearerToken = $Refs.bearerBox.Text
    $Auth.basicUser = $Refs.basicUser.Text; $Auth.basicPass = $Refs.basicPass.Text
    switch ($Auth.type) {
        'clientcreds' {
            $Auth.tokenUrl = $Refs.ccTokenUrl.Text; $Auth.clientId = $Refs.ccClientId.Text
            $Auth.clientSecret = $Refs.ccClientSecret.Text; $Auth.scope = $Refs.ccScope.Text
            $Auth.clientAuthStyle = $(if ($Refs.ccStyle.SelectedIndex -eq 1) { 'header' } else { 'body' })
        }
        'authcode' {
            $Auth.authUrl = $Refs.acAuthUrl.Text; $Auth.tokenUrl = $Refs.acTokenUrl.Text
            $Auth.clientId = $Refs.acClientId.Text; $Auth.clientSecret = $Refs.acClientSecret.Text
            $Auth.scope = $Refs.acScope.Text; $Auth.usePkce = [bool]$Refs.acPkce.Checked
            $p = 8080; [void][int]::TryParse($Refs.acPort.Text, [ref]$p); $Auth.redirectPort = $p
        }
        'vertex' {
            $Auth.clientEmail = $Refs.vxClientEmail.Text.Trim(); $Auth.privateKey = $Refs.vxPrivateKey.Text
        }
    }
}
