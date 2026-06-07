# Ui.Collections.ps1 — left sidebar: a tree of Collections -> saved Requests.
# A saved request is a New-PPTab-shaped model stored in $State.collections.
# Handlers read $Global:PPApp (never captured locals) to stay closure-safe, and all
# mutations edit $State.collections in place then rebuild the tree.

# Rebuild the whole tree from state (collections are small; rebuild keeps node<->model in sync).
function Build-PPTree {
    $tree = $Global:PPApp.tree
    if (-not $tree) { return }
    $tree.BeginUpdate()
    $tree.Nodes.Clear()
    foreach ($c in @($Global:PPApp.state.collections)) {
        $cn = New-Object System.Windows.Forms.TreeNode($c.name)
        $cn.Tag = @{ kind = 'collection'; col = $c }
        foreach ($r in @($c.requests)) {
            $rn = New-Object System.Windows.Forms.TreeNode(('{0}  {1}' -f $r.method, $r.name))
            $rn.Tag = @{ kind = 'request'; col = $c; req = $r }
            [void]$cn.Nodes.Add($rn)
        }
        [void]$tree.Nodes.Add($cn)
        $cn.Expand()
    }
    $tree.EndUpdate()
}

# Resolve the collection a Save/Add should target from the current selection.
function Get-PPTargetCollection {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node) { return $null }
    $t = $node.Tag
    if ($t.kind -eq 'collection') { return $t.col }
    if ($t.kind -eq 'request')    { return $t.col }
    return $null
}

function New-PPCollectionCmd {
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Collection name:', 'New collection', 'New Collection')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $Global:PPApp.state.collections += (New-PPCollection $name.Trim())
    Build-PPTree
}

# Save a snapshot of the active tab into a collection (selected one, or create when none exist).
function Save-PPRequestToCollectionCmd {
    $ctx = Get-PPCurrentCtx
    if (-not $ctx) { return }
    Sync-PPTabToModel $ctx
    $target = Get-PPTargetCollection
    if (-not $target) {
        if (@($Global:PPApp.state.collections).Count -eq 0) {
            $Global:PPApp.state.collections += (New-PPCollection 'My Collection')
            $target = $Global:PPApp.state.collections[-1]
        } else {
            $Global:PPApp.statusLabel.Text = 'Select a collection first, then Save Request.'
            return
        }
    }
    $snapshot = Copy-PPTab $ctx.model
    $target.requests += $snapshot
    Build-PPTree
    $Global:PPApp.statusLabel.Text = "Saved '$($snapshot.name)' to '$($target.name)'."
}

# Open the selected saved request as a new editable tab (a copy — edits don't touch the saved one).
# If the request inherits auth, resolve it from the parent collection at open time.
function Open-PPRequestCmd {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node -or $node.Tag.kind -ne 'request') { return }
    $clone = Copy-PPTab $node.Tag.req
    $clone.auth = Resolve-PPInheritedAuth $clone.auth $node.Tag.col.auth
    Add-PPTabPage $clone $true | Out-Null
}

# Edit a collection's default auth (inherited by its requests with auth = Inherit).
function Show-PPCollectionAuthCmd {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node -or $node.Tag.kind -ne 'collection') { return }
    $col = $node.Tag.col

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Collection auth - $($col.name)"; $dlg.FormBorderStyle = 'Sizable'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(440, 340); $dlg.MinimumSize = New-Object System.Drawing.Size(380, 280)

    $built = New-PPAuthPanel
    $built.panel.Dock = 'Fill'
    # collection auth is a template: hide the per-request OAuth "Get Token" buttons
    $built.refs.ccGetBtn.Visible = $false; $built.refs.acGetBtn.Visible = $false

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.FlowDirection = 'RightToLeft'; $foot.Padding = New-Object System.Windows.Forms.Padding(8)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Size = New-Object System.Drawing.Size(84, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(84, 28)
    $foot.Controls.Add($ok); $foot.Controls.Add($cancel)

    $dlg.Controls.Add($built.panel); $dlg.Controls.Add($foot)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    $built.refs.typeCombo.Add_SelectedIndexChanged({ Show-PPAuthCard $built.refs ($script:PPAuthTextToType[[string]$this.SelectedItem]) })
    Set-PPAuthRefs $built.refs $col.auth
    $ok.Add_Click({ Set-PPAuthModel $col.auth $built.refs; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    [void]$dlg.ShowDialog($Global:PPApp.form); $dlg.Dispose()
}

function Rename-PPTreeNodeCmd {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node) { return }
    $t = $node.Tag
    if ($t.kind -eq 'collection') {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Collection name:', 'Rename collection', $t.col.name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $t.col.name = $name.Trim()
    } elseif ($t.kind -eq 'request') {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Request name:', 'Rename request', $t.req.name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $t.req.name = $name.Trim()
    }
    Build-PPTree
}

function Duplicate-PPRequestCmd {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node -or $node.Tag.kind -ne 'request') { return }
    $t = $node.Tag
    $clone = Copy-PPTab $t.req
    $clone.name = $t.req.name + ' (copy)'
    $t.col.requests += $clone
    Build-PPTree
}

function Delete-PPTreeNodeCmd {
    $node = $Global:PPApp.tree.SelectedNode
    if (-not $node) { return }
    $t = $node.Tag
    if ($t.kind -eq 'collection') {
        $msg = "Delete collection '$($t.col.name)' and its $(@($t.col.requests).Count) request(s)?"
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm delete', 'YesNo', 'Warning') -ne 'Yes') { return }
        $new = @()
        foreach ($c in @($Global:PPApp.state.collections)) { if (-not [object]::ReferenceEquals($c, $t.col)) { $new += $c } }
        $Global:PPApp.state.collections = @($new)
    } elseif ($t.kind -eq 'request') {
        if ([System.Windows.Forms.MessageBox]::Show("Delete request '$($t.req.name)'?", 'Confirm delete', 'YesNo', 'Warning') -ne 'Yes') { return }
        $new = @()
        foreach ($r in @($t.col.requests)) { if (-not [object]::ReferenceEquals($r, $t.req)) { $new += $r } }
        $t.col.requests = @($new)
    }
    Build-PPTree
}

# Build the sidebar controls. Events are wired by the caller after $Global:PPApp exists.
function Build-PPCollectionsSidebar {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Left'; $panel.Width = 230

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 28
    $btnNewCol = New-Object System.Windows.Forms.Button
    $btnNewCol.Text = '+ Collection'; $btnNewCol.Dock = 'Left'; $btnNewCol.Width = 96; $btnNewCol.FlatStyle = 'System'
    $btnSaveReq = New-Object System.Windows.Forms.Button
    $btnSaveReq.Text = 'Save Request'; $btnSaveReq.Dock = 'Left'; $btnSaveReq.Width = 104; $btnSaveReq.FlatStyle = 'System'
    # Docked-left is right-to-left by add order; add Save first so +Collection ends up leftmost.
    $header.Controls.Add($btnSaveReq)
    $header.Controls.Add($btnNewCol)

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'; $tree.HideSelection = $false; $tree.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # Context menu. Each actionable item carries a .Tag of the selection it needs
    # ('request' | 'any' | 'always'); the Opening handler enables items by that tag
    # (robust against item reordering — no positional indexing).
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $menu.Items.Add('Open Request');             $miOpen.Tag = 'request'
    [void]$menu.Items.Add('-')
    $miNew  = $menu.Items.Add('New Collection');           $miNew.Tag  = 'always'
    $miAdd  = $menu.Items.Add('Add Current Request Here');  $miAdd.Tag  = 'any'
    [void]$menu.Items.Add('-')
    $miRen  = $menu.Items.Add('Rename');                   $miRen.Tag  = 'any'
    $miDup  = $menu.Items.Add('Duplicate Request');        $miDup.Tag  = 'request'
    $miAuth = $menu.Items.Add('Collection auth...');       $miAuth.Tag = 'collection'
    $miDel  = $menu.Items.Add('Delete');                   $miDel.Tag  = 'any'
    $miOpen.Add_Click({ Open-PPRequestCmd })
    $miNew.Add_Click({ New-PPCollectionCmd })
    $miAdd.Add_Click({ Save-PPRequestToCollectionCmd })
    $miRen.Add_Click({ Rename-PPTreeNodeCmd })
    $miDup.Add_Click({ Duplicate-PPRequestCmd })
    $miAuth.Add_Click({ Show-PPCollectionAuthCmd })
    $miDel.Add_Click({ Delete-PPTreeNodeCmd })
    $menu.Add_Opening({
        $node = $Global:PPApp.tree.SelectedNode
        $kind = if ($node) { [string]$node.Tag.kind } else { '' }
        foreach ($it in $this.Items) {
            $need = [string]$it.Tag
            if (-not $need) { continue }   # separators
            switch ($need) {
                'request'    { $it.Enabled = ($kind -eq 'request') }
                'collection' { $it.Enabled = ($kind -eq 'collection') }
                'any'        { $it.Enabled = ($kind -eq 'request' -or $kind -eq 'collection') }
                default      { $it.Enabled = $true }
            }
        }
    })
    $tree.ContextMenuStrip = $menu

    $panel.Controls.Add($tree)
    $panel.Controls.Add($header)
    return @{ panel = $panel; tree = $tree; btnNewCol = $btnNewCol; btnSaveReq = $btnSaveReq }
}
