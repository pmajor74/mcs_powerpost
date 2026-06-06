# Ui.Main.ps1 — main window, toolbar, tab management, save/close, app bootstrap.

# Brand/version constants — single source of truth for the title bar and About screen.
$script:PPName      = 'MCS PowerPost'
$script:PPVersion   = '1.0.0'
$script:PPCompany   = 'Major Computing Systems'
$script:PPWebsite   = 'https://majorcomputingsystems.ca'
$script:PPCopyright = "Copyright (c) 2026 $script:PPCompany"

function Get-PPCurrentCtx {
    $tc = $Global:PPApp.tabControl
    if ($tc -and $tc.SelectedTab) { return $tc.SelectedTab.Tag }
    return $null
}

function Copy-PPTab {
    param($Model)
    # Deep copy via a JSON round-trip, then re-normalize to our model.
    return (Resolve-PPTab ($Model | ConvertTo-Json -Depth 20 | ConvertFrom-Json))
}

function Add-PPTabPage {
    param($Model, [bool]$Select = $true)
    $page = New-PPRequestTab $Model
    [void]$Global:PPApp.tabControl.TabPages.Add($page)
    if ($Select) { $Global:PPApp.tabControl.SelectedTab = $page }
    # Apply splitter distance now if the container is already sized (i.e. added at runtime).
    $h = $page.Tag.split.Height
    if ($h -gt 260) { try { $page.Tag.split.SplitterDistance = [int]($h * 0.5) } catch { } }
    return $page
}

function New-PPTabCmd {
    Add-PPTabPage (New-PPTab) $true | Out-Null
}

function Copy-PPTabCmd {
    $ctx = Get-PPCurrentCtx
    if (-not $ctx) { return }
    Sync-PPTabToModel $ctx
    $clone = Copy-PPTab $ctx.model
    $clone.name = $ctx.model.name + ' (copy)'
    Add-PPTabPage $clone $true | Out-Null
}

function Close-PPTabCmd {
    $tc = $Global:PPApp.tabControl
    $page = $tc.SelectedTab
    if (-not $page) { return }
    if ($tc.TabPages.Count -le 1) {
        # Keep at least one tab — reset it instead of closing.
        $tc.TabPages.Remove($page)
        Add-PPTabPage (New-PPTab) $true | Out-Null
        return
    }
    $tc.TabPages.Remove($page)
}

function Rename-PPTabCmd {
    param($Page)
    if (-not $Page) { $Page = $Global:PPApp.tabControl.SelectedTab }
    if (-not $Page) { return }
    $ctx = $Page.Tag
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Tab name:', 'Rename request', $ctx.model.name)
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $ctx.model.name = $name
        $Page.Text = $name
    }
}

function Build-PPStateFromUi {
    $state = $Global:PPApp.state
    $tabs = @()
    foreach ($page in $Global:PPApp.tabControl.TabPages) {
        $ctx = $page.Tag
        Sync-PPTabToModel $ctx
        $tabs += $ctx.model
    }
    $state.tabs = $tabs
    $state.activeTab = $Global:PPApp.tabControl.SelectedIndex
    $state.ignoreSsl = [bool]$Global:PPApp.ignoreSslCheck.Checked
    if ($Global:PPApp.cookies) { $state.cookies = Export-PPCookies $Global:PPApp.cookies }

    $form = $Global:PPApp.form
    if ($form.WindowState -eq 'Maximized') {
        $state.window.maximized = $true
        $b = $form.RestoreBounds
    } else {
        $state.window.maximized = $false
        $b = $form.Bounds
    }
    $state.window.width = $b.Width; $state.window.height = $b.Height
    $state.window.x = $b.X; $state.window.y = $b.Y
    return $state
}

function Save-PPAll {
    $state = Build-PPStateFromUi
    $path = Save-PPState $state
    $Global:PPApp.statusLabel.Text = "Saved $([System.IO.Path]::GetFileName($path)) at $((Get-Date).ToString('HH:mm:ss'))"
}

function New-PPToolbarButton {
    param([string]$Text)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Dock = 'Left'; $b.Width = 92; $b.FlatStyle = 'System'
    return $b
}

# About dialog — app name/version, copyright, and a clickable website link.
function Show-PPAbout {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "About $script:PPName"
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(380, 200)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "$script:PPName  v$script:PPVersion"
    $lblName.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblName.AutoSize = $true
    $lblName.Location = New-Object System.Drawing.Point(18, 18)

    $lblTag = New-Object System.Windows.Forms.Label
    $lblTag.Text = 'A lightweight Postman-style API tester.'
    $lblTag.AutoSize = $true
    $lblTag.Location = New-Object System.Drawing.Point(18, 52)

    $lblCopy = New-Object System.Windows.Forms.Label
    $lblCopy.Text = $script:PPCopyright
    $lblCopy.AutoSize = $true
    $lblCopy.Location = New-Object System.Drawing.Point(18, 88)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = 'majorcomputingsystems.ca'
    $link.AutoSize = $true
    $link.Location = New-Object System.Drawing.Point(18, 112)
    $link.Add_LinkClicked({ try { Start-Process $script:PPWebsite } catch { } })

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Size = New-Object System.Drawing.Size(84, 28)
    $ok.Location = New-Object System.Drawing.Point(278, 158)

    $dlg.Controls.AddRange(@($lblName, $lblTag, $lblCopy, $link, $ok))
    $dlg.AcceptButton = $ok

    $owner = $null
    if ($Global:PPApp) { $owner = $Global:PPApp.form }
    if ($owner) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

function Start-PowerPost {
    param($State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:PPName
    $form.KeyPreview = $true
    $form.MinimumSize = New-Object System.Drawing.Size(720, 480)
    $w = $State.window
    $form.Size = New-Object System.Drawing.Size([Math]::Max(720, $w.width), [Math]::Max(480, $w.height))
    if ($w.x -ge 0 -and $w.y -ge 0) {
        $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point($w.x, $w.y)
    } else {
        $form.StartPosition = 'CenterScreen'
    }

    # toolbar
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Top'; $toolbar.Height = 34
    $btnNew  = New-PPToolbarButton 'New Tab'
    $btnDup  = New-PPToolbarButton 'Duplicate'
    $btnClose = New-PPToolbarButton 'Close Tab'
    $btnSave = New-PPToolbarButton 'Save'
    $btnAbout = New-PPToolbarButton 'About'
    $btnImport = New-PPToolbarButton 'Import cURL'; $btnImport.Width = 100
    $btnLlm  = New-PPToolbarButton 'LLM Playground'; $btnLlm.Width = 118
    $btnTools = New-PPToolbarButton 'Tools'; $btnTools.Width = 66
    $btnEnv  = New-PPToolbarButton 'Environments'; $btnEnv.Width = 104
    $envCombo = New-Object System.Windows.Forms.ComboBox
    $envCombo.DropDownStyle = 'DropDownList'; $envCombo.Dock = 'Left'; $envCombo.Width = 170
    Update-PPEnvCombo $envCombo $State
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($envCombo, 'Active environment for {{variable}} substitution')
    $chkSsl = New-Object System.Windows.Forms.CheckBox
    $chkSsl.Text = 'Ignore SSL errors'; $chkSsl.Dock = 'Left'; $chkSsl.Width = 130; $chkSsl.TextAlign = 'MiddleLeft'
    $chkSsl.Checked = [bool]$State.ignoreSsl
    # Docked-left order is right-to-left by add order; add so New ends up leftmost
    # and About ends up rightmost.
    $toolbar.Controls.Add($btnAbout)
    $toolbar.Controls.Add($chkSsl)
    $toolbar.Controls.Add($btnTools)
    $toolbar.Controls.Add($btnLlm)
    $toolbar.Controls.Add($btnEnv)
    $toolbar.Controls.Add($envCombo)
    $toolbar.Controls.Add($btnImport)
    $toolbar.Controls.Add($btnSave)
    $toolbar.Controls.Add($btnClose)
    $toolbar.Controls.Add($btnDup)
    $toolbar.Controls.Add($btnNew)

    # tab control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = 'Fill'

    # collections sidebar + splitter (left of the tabs)
    $side = Build-PPCollectionsSidebar
    $splitter = New-Object System.Windows.Forms.Splitter
    $splitter.Dock = 'Left'; $splitter.Width = 4

    # status bar
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready'
    [void]$statusStrip.Items.Add($statusLabel)

    # Dock order matters: last-added docks first. Add Fill content first, then the left
    # sidebar + splitter, then toolbar/status last so they span the full width.
    $form.Controls.Add($tabControl)
    $form.Controls.Add($splitter)
    $form.Controls.Add($side.panel)
    $form.Controls.Add($toolbar)
    $form.Controls.Add($statusStrip)

    $Global:PPApp = @{
        form = $form; tabControl = $tabControl; state = $State
        ignoreSslCheck = $chkSsl; statusLabel = $statusLabel; envCombo = $envCombo
        tree = $side.tree
    }
    $Global:PPIgnoreSsl = [bool]$State.ignoreSsl
    [PPCertPolicy]::IgnoreErrors = [bool]$State.ignoreSsl

    # shared cookie jar (persists across requests; restored from / saved to state)
    $Global:PPApp.cookies = New-Object System.Net.CookieContainer
    Import-PPCookies $Global:PPApp.cookies $State.cookies

    # context menu for tabs
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRename = $menu.Items.Add('Rename')
    $miDup    = $menu.Items.Add('Duplicate')
    $miClose  = $menu.Items.Add('Close')
    [void]$menu.Items.Add('-')
    $miCurl   = $menu.Items.Add('Copy as cURL')
    $miPs     = $menu.Items.Add('Copy as PowerShell')
    $miRename.Add_Click({ Rename-PPTabCmd $null })
    $miDup.Add_Click({ Copy-PPTabCmd })
    $miClose.Add_Click({ Close-PPTabCmd })
    $miCurl.Add_Click({ Copy-PPAsCurlCmd })
    $miPs.Add_Click({ Copy-PPAsPowerShellCmd })
    $tabControl.ContextMenuStrip = $menu

    # build tabs from state
    foreach ($model in @($State.tabs)) { Add-PPTabPage $model $false | Out-Null }
    if ($tabControl.TabPages.Count -eq 0) { Add-PPTabPage (New-PPTab) $false | Out-Null }
    $idx = [int]$State.activeTab
    if ($idx -ge 0 -and $idx -lt $tabControl.TabPages.Count) { $tabControl.SelectedIndex = $idx }

    # build collections sidebar from state
    Build-PPTree

    # events
    $btnNew.Add_Click({ New-PPTabCmd })
    $btnDup.Add_Click({ Copy-PPTabCmd })
    $btnClose.Add_Click({ Close-PPTabCmd })
    $btnSave.Add_Click({ Save-PPAll })
    $btnAbout.Add_Click({ Show-PPAbout })
    $btnImport.Add_Click({ Show-PPImportCurl })
    $btnLlm.Add_Click({ Show-PPLlmPlayground })
    $toolsMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miSettings = $toolsMenu.Items.Add('Settings...')
    $miHistory  = $toolsMenu.Items.Add('Request history...')
    $miCookies  = $toolsMenu.Items.Add('Cookies...')
    $miSettings.Add_Click({ Show-PPSettings })
    $miHistory.Add_Click({ Show-PPHistory })
    $miCookies.Add_Click({ Show-PPCookies })
    $btnTools.Add_Click({ $toolsMenu.Show($btnTools, 0, $btnTools.Height) })
    $envCombo.Add_SelectedIndexChanged({
        $idx = $this.SelectedIndex
        if ($idx -le 0) { $Global:PPApp.state.activeEnv = '' }
        else { $Global:PPApp.state.activeEnv = [string]$Global:PPApp.state.environments[$idx - 1].name }
    })
    $btnEnv.Add_Click({
        if (Show-PPEnvManager) { Update-PPEnvCombo $Global:PPApp.envCombo $Global:PPApp.state }
    })
    $side.btnNewCol.Add_Click({ New-PPCollectionCmd })
    $side.btnSaveReq.Add_Click({ Save-PPRequestToCollectionCmd })
    $side.tree.Add_NodeMouseClick({ if ($_.Button -eq 'Right') { $this.SelectedNode = $_.Node } })
    $side.tree.Add_NodeMouseDoubleClick({ Open-PPRequestCmd })
    $chkSsl.Add_CheckedChanged({
        $Global:PPIgnoreSsl = [bool]$this.Checked
        [PPCertPolicy]::IgnoreErrors = [bool]$this.Checked
    })

    # right-click selects the tab under the cursor before the menu opens
    $tabControl.Add_MouseDown({
        if ($_.Button -eq 'Right') {
            for ($i = 0; $i -lt $this.TabPages.Count; $i++) {
                if ($this.GetTabRect($i).Contains($_.Location)) { $this.SelectedIndex = $i; break }
            }
        }
    })
    # double-click a tab header to rename
    $tabControl.Add_MouseDoubleClick({
        for ($i = 0; $i -lt $this.TabPages.Count; $i++) {
            if ($this.GetTabRect($i).Contains($_.Location)) { Rename-PPTabCmd $this.TabPages[$i]; break }
        }
    })

    # keyboard shortcuts
    $form.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq 'T') { New-PPTabCmd; $_.Handled = $true }
        elseif ($_.Control -and $_.KeyCode -eq 'S') { Save-PPAll; $_.Handled = $true }
        elseif ($_.Control -and $_.KeyCode -eq 'W') { Close-PPTabCmd; $_.Handled = $true }
        elseif ($_.KeyCode -eq 'F5' -or ($_.Control -and $_.KeyCode -eq 'Return')) {
            $ctx = Get-PPCurrentCtx; if ($ctx) { Invoke-PPSend $ctx }; $_.Handled = $true
        }
    })

    $form.Add_Shown({
        if ($Global:PPApp.state.window.maximized) { $Global:PPApp.form.WindowState = 'Maximized' }
        foreach ($page in $Global:PPApp.tabControl.TabPages) {
            $h = $page.Tag.split.Height
            if ($h -gt 260) { try { $page.Tag.split.SplitterDistance = [int]($h * 0.5) } catch { } }
        }
        # Testability hook: auto-close shortly after render for the GUI smoke test.
        if ($env:PP_SMOKE -eq '1') {
            $Global:PPSmokeTimer = New-Object System.Windows.Forms.Timer
            $Global:PPSmokeTimer.Interval = 1200
            $Global:PPSmokeTimer.Add_Tick({ $this.Stop(); $Global:PPApp.form.Close() })
            $Global:PPSmokeTimer.Start()
        }
    })

    # autosave on close
    $form.Add_FormClosing({ try { Save-PPAll } catch { } })

    [void]$form.ShowDialog()
}
