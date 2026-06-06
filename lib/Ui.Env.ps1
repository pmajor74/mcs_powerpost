# Ui.Env.ps1 — environment selector helpers + the environment-manager dialog.

# Variable map for the currently-active environment (empty when none is selected).
function Get-PPActiveVarMap {
    if (-not ($Global:PPApp -and $Global:PPApp.state)) { return @{} }
    $name = [string]$Global:PPApp.state.activeEnv
    if ([string]::IsNullOrEmpty($name)) { return @{} }
    foreach ($e in @($Global:PPApp.state.environments)) {
        if ($e.name -eq $name) { return (Get-PPVarMap $e) }
    }
    return @{}
}

# Repopulate the toolbar environment combo from state and select the active one.
function Update-PPEnvCombo {
    param($Combo, $State)
    $Combo.Items.Clear()
    [void]$Combo.Items.Add('No Environment')
    foreach ($e in @($State.environments)) { [void]$Combo.Items.Add([string]$e.name) }
    $sel = 0
    $name = [string]$State.activeEnv
    if ($name) {
        for ($i = 0; $i -lt $State.environments.Count; $i++) {
            if ($State.environments[$i].name -eq $name) { $sel = $i + 1; break }
        }
    }
    $Combo.SelectedIndex = $sel
}

# Deep-copy an environments list via a JSON round-trip + re-normalization.
function Copy-PPEnvironments {
    param($Envs)
    $copy = @()
    foreach ($e in @($Envs)) {
        $copy += (Resolve-PPEnvironment ($e | ConvertTo-Json -Depth 20 | ConvertFrom-Json))
    }
    return , $copy
}

# Modal manager: add/rename/delete environments and edit each one's variables.
# Edits happen on a working copy; only OK commits them back to state.
function Show-PPEnvManager {
    $state = $Global:PPApp.state
    # All mutable shared state lives in $ctx so event handlers mutate members
    # (closure-safe) instead of reassigning captured locals.
    $ctx = @{ envs = (Copy-PPEnvironments $state.environments); current = -1 }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Environments'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 440)

    # ----- body (fills above the footer) -----
    $body = New-Object System.Windows.Forms.Panel; $body.Dock = 'Fill'

    # right: variables grid
    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'; $right.Padding = New-Object System.Windows.Forms.Padding(8)
    $grid = New-PPKvGrid
    $lblVars = New-Object System.Windows.Forms.Label
    $lblVars.Text = 'Variables  (use {{name}} in requests)'; $lblVars.Dock = 'Top'; $lblVars.Height = 22
    $right.Controls.Add($grid)
    $right.Controls.Add($lblVars)

    # left: environment list + add/rename/delete
    $left = New-Object System.Windows.Forms.Panel
    $left.Dock = 'Left'; $left.Width = 220; $left.Padding = New-Object System.Windows.Forms.Padding(8)
    $list = New-Object System.Windows.Forms.ListBox; $list.Dock = 'Fill'
    $listBtns = New-Object System.Windows.Forms.Panel; $listBtns.Dock = 'Bottom'; $listBtns.Height = 30
    $btnAdd = New-Object System.Windows.Forms.Button; $btnAdd.Text = 'Add'; $btnAdd.Dock = 'Left'; $btnAdd.Width = 64
    $btnRen = New-Object System.Windows.Forms.Button; $btnRen.Text = 'Rename'; $btnRen.Dock = 'Left'; $btnRen.Width = 70
    $btnDel = New-Object System.Windows.Forms.Button; $btnDel.Text = 'Delete'; $btnDel.Dock = 'Left'; $btnDel.Width = 64
    # Docked-left is right-to-left by add order; add Delete first so Add ends up leftmost.
    $listBtns.Controls.Add($btnDel); $listBtns.Controls.Add($btnRen); $listBtns.Controls.Add($btnAdd)
    $left.Controls.Add($list); $left.Controls.Add($listBtns)

    $body.Controls.Add($right); $body.Controls.Add($left)

    # ----- footer (OK / Cancel) -----
    $foot = New-Object System.Windows.Forms.Panel; $foot.Dock = 'Bottom'; $foot.Height = 44
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Size = New-Object System.Drawing.Size(84, 28)
    $ok.Location = New-Object System.Drawing.Point(484, 9)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(84, 28)
    $cancel.Location = New-Object System.Drawing.Point(572, 9)
    $foot.Controls.Add($ok); $foot.Controls.Add($cancel)

    $dlg.Controls.Add($body)
    $dlg.Controls.Add($foot)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    # ----- shared actions (scriptblocks; invoked with & ) -----
    $saveCurrent = {
        if ($ctx.current -ge 0 -and $ctx.current -lt $ctx.envs.Count) {
            $ctx.envs[$ctx.current].variables = Get-PPKvGrid $grid
        }
    }
    $refreshList = {
        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($e in @($ctx.envs)) { [void]$list.Items.Add([string]$e.name) }
        $list.EndUpdate()
    }

    $list.Add_SelectedIndexChanged({
        & $saveCurrent
        $ctx.current = $list.SelectedIndex
        if ($ctx.current -ge 0 -and $ctx.current -lt $ctx.envs.Count) {
            Set-PPKvGrid $grid $ctx.envs[$ctx.current].variables
            $grid.Enabled = $true
        } else {
            $grid.Rows.Clear(); $grid.Enabled = $false
        }
    })

    $btnAdd.Add_Click({
        & $saveCurrent
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Environment name:', 'New environment', 'New Environment')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $ctx.envs += (New-PPEnvironment $name.Trim())
        & $refreshList
        $list.SelectedIndex = $ctx.envs.Count - 1
    })

    $btnRen.Add_Click({
        $i = $list.SelectedIndex
        if ($i -lt 0) { return }
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Environment name:', 'Rename environment', $ctx.envs[$i].name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $ctx.envs[$i].name = $name.Trim()
        & $refreshList
        $list.SelectedIndex = $i
    })

    $btnDel.Add_Click({
        $i = $list.SelectedIndex
        if ($i -lt 0) { return }
        $new = @()
        for ($k = 0; $k -lt $ctx.envs.Count; $k++) { if ($k -ne $i) { $new += $ctx.envs[$k] } }
        $ctx.current = -1
        $ctx.envs = @($new)
        & $refreshList
        if ($ctx.envs.Count -gt 0) { $list.SelectedIndex = 0 }
        else { $grid.Rows.Clear(); $grid.Enabled = $false }
    })

    $ok.Add_Click({
        & $saveCurrent
        $state.environments = $ctx.envs
        $names = @($ctx.envs | ForEach-Object { $_.name })
        if ($state.activeEnv -and ($names -notcontains $state.activeEnv)) { $state.activeEnv = '' }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    # initial population
    & $refreshList
    if ($ctx.envs.Count -gt 0) { $list.SelectedIndex = 0 } else { $grid.Enabled = $false }

    $owner = $Global:PPApp.form
    $result = if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() }
    $dlg.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}
