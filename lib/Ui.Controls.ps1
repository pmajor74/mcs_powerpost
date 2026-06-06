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
    param($Table, [string]$LabelText, $Control)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $LabelText
    $l.Dock = 'Fill'
    $l.TextAlign = 'MiddleLeft'
    $Control.Dock = 'Fill'
    $r = $Table.RowCount
    [void]$Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
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
    [void]$combo.Items.AddRange(@('None', 'Bearer / JWT', 'Basic', 'OAuth2 Client Credentials', 'OAuth2 Authorization Code'))

    $cards = New-Object System.Windows.Forms.Panel
    $cards.Dock = 'Fill'

    $refs = @{ typeCombo = $combo; cards = $cards; panels = @{} }

    # None
    $pNone = New-Object System.Windows.Forms.Panel; $pNone.Dock = 'Fill'
    $lblNone = New-Object System.Windows.Forms.Label
    $lblNone.Text = 'No authentication will be sent.'; $lblNone.Dock = 'Top'; $lblNone.Padding = New-Object System.Windows.Forms.Padding(6)
    $pNone.Controls.Add($lblNone)
    $refs.panels['none'] = $pNone

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
}
$script:PPAuthTextToType = @{
    'None' = 'none'; 'Bearer / JWT' = 'bearer'; 'Basic' = 'basic'
    'OAuth2 Client Credentials' = 'clientcreds'; 'OAuth2 Authorization Code' = 'authcode'
}

function Show-PPAuthCard {
    param($Refs, [string]$Type)
    foreach ($key in $Refs.panels.Keys) {
        $vis = ($key -eq $Type)
        $Refs.panels[$key].Visible = $vis
        if ($vis) { $Refs.panels[$key].BringToFront() }
    }
}
