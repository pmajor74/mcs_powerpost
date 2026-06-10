# Ui.Jwt.ps1 — JWT decoder dialog (Tools menu). Decodes header/payload without verifying the
# signature, formats epoch claims as UTC, and explains common claims (OIDC + Azure AD).

$script:PPJwtClaimHelp = @{
    'typ' = 'always set to "JWT"'; 'nonce' = 'a unique random value used to prevent replay attacks'
    'alg' = 'the algorithm used for signing the JWT'; 'x5t' = 'the thumbprint of the certificate used for signing the JWT'
    'kid' = 'the thumbprint for the public key used to verify this token'; 'aud' = 'the recipients that the JWT is intended for'
    'iss' = 'the authorization server that issued the JWT'; 'iat' = 'the time at which the JWT was issued'
    'nbf' = 'the time before which the JWT must not be accepted'; 'exp' = 'the expiration time after which the JWT must not be accepted'
    'jti' = 'a unique identifier for this JWT'; 'sub' = 'the principal (subject) the token asserts information about'
    'acct' = 'user account status (0 = member, 1 = guest)'; 'acr' = 'the "Authentication context class" claim'
    'acrs' = 'authentication context references satisfied by this token'; 'aio' = 'an internal claim used by Azure AD'
    'amr' = 'identifies how the subject of the token was authenticated'; 'app_displayname' = 'display name of the application requesting the token'
    'appid' = 'the application ID of the client using the token'; 'appidacr' = 'how the client was authenticated (0=public, 1=secret, 2=cert)'
    'azp' = 'the authorized party (client id) the token was issued to'; 'azpacr' = 'how the authorized party was authenticated'
    'deviceid' = 'the identifier of the device used to authenticate'; 'family_name' = 'the surname (family name) of the user'
    'given_name' = 'the given (first) name of the user'; 'idtyp' = 'identity type (user or app)'
    'ipaddr' = 'the IP address from which the user authenticated'; 'name' = 'a human-readable name for the subject of the token'
    'oid' = 'the immutable object identifier of the user in the directory'; 'onprem_sid' = 'the on-premises AD security identifier (SID)'
    'platf' = 'the platform identifier of the device'; 'puid' = 'the passport unique identifier for the user'
    'rh' = 'an internal refresh-hint claim used by Azure AD'; 'roles' = 'the roles assigned to the user or application'
    'scp' = 'the scopes (permissions) granted to the application'; 'sid' = 'the session identifier'
    'signin_state' = 'sign-in state flags (e.g., domain-joined, MFA)'; 'tenant_region_scope' = 'the geographic region of the tenant'
    'tid' = 'the tenant identifier (directory the user belongs to)'; 'unique_name' = 'a unique name identifying the user (deprecated; use upn)'
    'upn' = 'the user principal name (e.g., user@domain)'; 'uti' = 'a unique token identifier'; 'ver' = 'the version of the access token'
    'wids' = 'well-known IDs of Azure AD directory roles assigned to the user'; 'email' = 'the email address of the user'
    'preferred_username' = 'the preferred username for display'; 'groups' = 'the groups the user is a member of'
    'hasgroups' = 'indicates the user is in groups (used when the groups claim is too large)'; 'scope' = 'the scopes granted (space-delimited)'
}
$script:PPJwtEpochClaims = @('iat', 'nbf', 'exp', 'auth_time', 'xms_tcdt')
$script:PPJwtDirRoles = @{
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'; '10dae51f-b6af-4016-8d66-8c2a99b929b3' = 'Global Reader'
    'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'; '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
    '5d6b6bb7-de71-4623-b4af-96380a352509' = 'Security Reader'; '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'; 'b0f54661-2d74-4c50-afa3-1ec803f12efe' = 'Billing Administrator'
    '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'; 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
    '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'; '729827e3-9c14-49f7-bb1b-9608f156bbb8' = 'Helpdesk Administrator'
}

function ConvertFrom-PPJwtBase64Url {
    param([string]$Value)
    $p = $Value.Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } 0 { } default { throw 'Invalid Base64Url length' } }
    return [System.Convert]::FromBase64String($p)
}

# Split a JWT into its header/payload PSCustomObjects (signature is not verified).
function Get-PPJwtParts {
    param([string]$Token)
    $clean = ($Token -replace '\s', '').Trim()
    $seg = $clean.Split('.')
    if ($seg.Count -lt 2) { throw 'Not a JWT (need dot-separated header.payload).' }
    $h = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-PPJwtBase64Url $seg[0]))
    $p = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-PPJwtBase64Url $seg[1]))
    return [pscustomobject]@{ Header = ($h | ConvertFrom-Json); Payload = ($p | ConvertFrom-Json) }
}

function Format-PPJwtLeaf {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    if ($Value -is [string]) { return '"' + $Value + '"' }
    if ($Value -is [System.Array]) { return '[ ... ]' }
    if ($Value -is [pscustomobject]) { return '{ ... }' }
    return [string]$Value
}

# Recursively add a JSON value's children under a tree node.
function Add-PPJwtNodes {
    param([System.Windows.Forms.TreeNode]$Node, $Object)
    if ($Object -is [pscustomobject]) {
        foreach ($p in $Object.PSObject.Properties) {
            if ($p.Value -is [pscustomobject] -or $p.Value -is [System.Array]) {
                $stub = New-Object System.Windows.Forms.TreeNode('"' + $p.Name + '" :')
                [void]$Node.Nodes.Add($stub); Add-PPJwtNodes $stub $p.Value
            } else {
                [void]$Node.Nodes.Add((New-Object System.Windows.Forms.TreeNode('"' + $p.Name + '" : ' + (Format-PPJwtLeaf $p.Value))))
            }
        }
    } elseif ($Object -is [System.Array]) {
        for ($i = 0; $i -lt $Object.Count; $i++) {
            $item = $Object[$i]
            if ($item -is [pscustomobject] -or $item -is [System.Array]) {
                $stub = New-Object System.Windows.Forms.TreeNode("$i :")
                [void]$Node.Nodes.Add($stub); Add-PPJwtNodes $stub $item
            } else {
                [void]$Node.Nodes.Add((New-Object System.Windows.Forms.TreeNode("$i : " + (Format-PPJwtLeaf $item))))
            }
        }
    }
}

function Format-PPJwtClaimValue {
    param([string]$Field, $Value)
    if ($null -eq $Value) { return '' }
    if ($script:PPJwtEpochClaims -contains $Field) {
        try { return ([System.DateTimeOffset]::FromUnixTimeSeconds([long]$Value).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC') } catch { }
    }
    if ($Value -is [System.Array]) { return '[' + (($Value | ForEach-Object { Format-PPJwtLeaf $_ }) -join ', ') + ']' }
    if ($Value -is [pscustomobject]) { return ($Value | ConvertTo-Json -Compress -Depth 6) }
    return [string]$Value
}

# Fill the explanation list and roles/scopes list from a decoded token.
function Update-PPJwtTables {
    param($Refs, $Parts)
    foreach ($scope in @($Parts.Header, $Parts.Payload)) {
        foreach ($prop in $scope.PSObject.Properties) {
            $exp = $script:PPJwtClaimHelp[$prop.Name]
            if (-not $exp -and $prop.Name -like 'xms_*') { $exp = 'Microsoft extension claim' }
            $item = New-Object System.Windows.Forms.ListViewItem($prop.Name)
            [void]$item.SubItems.Add((Format-PPJwtClaimValue $prop.Name $prop.Value))
            [void]$item.SubItems.Add([string]$exp)
            [void]$Refs.lvExplain.Items.Add($item)
        }
    }
    $pl = $Parts.Payload
    $addRole = {
        param($src, $val)
        $it = New-Object System.Windows.Forms.ListViewItem($src); [void]$it.SubItems.Add([string]$val); [void]$Refs.lvRoles.Items.Add($it)
    }
    if ($pl.PSObject.Properties.Name -contains 'roles') { foreach ($x in @($pl.roles)) { & $addRole 'Application Role' $x } }
    if ($pl.PSObject.Properties.Name -contains 'wids') {
        foreach ($w in @($pl.wids)) { $n = $script:PPJwtDirRoles[[string]$w]; & $addRole 'Directory Role (wids)' $(if ($n) { "$n  ($w)" } else { [string]$w }) }
    }
    if ($pl.PSObject.Properties.Name -contains 'groups') { foreach ($g in @($pl.groups)) { & $addRole 'Group' $g } }
    if ($pl.PSObject.Properties.Name -contains 'scp')   { foreach ($s in ([string]$pl.scp).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) { & $addRole 'Scope (scp)' $s } }
    if ($pl.PSObject.Properties.Name -contains 'scope') { foreach ($s in ([string]$pl.scope).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) { & $addRole 'Scope' $s } }
    if ($Refs.lvRoles.Items.Count -eq 0) {
        $it = New-Object System.Windows.Forms.ListViewItem('(none)'); [void]$it.SubItems.Add('No roles, groups, or scopes in this token')
        $it.ForeColor = [System.Drawing.Color]::DimGray; [void]$Refs.lvRoles.Items.Add($it)
    }
}

function Update-PPJwtView {
    param($Refs, [string]$Token)
    $Refs.tree.Nodes.Clear(); $Refs.lvExplain.Items.Clear(); $Refs.lvRoles.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    try { $parts = Get-PPJwtParts $Token } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to decode JWT: $($_.Exception.Message)", 'JWT Decoder', 'OK', 'Warning') | Out-Null
        return
    }
    $root = New-Object System.Windows.Forms.TreeNode('{ header, payload }')
    [void]$Refs.tree.Nodes.Add($root)
    $hn = New-Object System.Windows.Forms.TreeNode('"header" :'); [void]$root.Nodes.Add($hn); Add-PPJwtNodes $hn $parts.Header
    $pn = New-Object System.Windows.Forms.TreeNode('"payload" :'); [void]$root.Nodes.Add($pn); Add-PPJwtNodes $pn $parts.Payload
    $root.ExpandAll()
    Update-PPJwtTables $Refs $parts
}

function Show-PPJwtDecoder {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'JWT Decoder'; $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(900, 640)
    $dlg.MinimumSize = New-Object System.Drawing.Size(620, 460)

    $tokenBox = New-Object System.Windows.Forms.TextBox
    $tokenBox.Multiline = $true; $tokenBox.ScrollBars = 'Vertical'; $tokenBox.WordWrap = $true
    $tokenBox.Dock = 'Top'; $tokenBox.Height = 120; $tokenBox.MaxLength = 0
    $tokenBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.Height = 38; $bar.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
    $btnDecode = New-Object System.Windows.Forms.Button; $btnDecode.Text = 'Decode'; $btnDecode.Size = New-Object System.Drawing.Size(90, 28)
    $btnClear  = New-Object System.Windows.Forms.Button; $btnClear.Text = 'Clear';   $btnClear.Size = New-Object System.Drawing.Size(90, 28)
    $bar.Controls.Add($btnDecode); $bar.Controls.Add($btnClear)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'; $tree.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $tree.HideSelection = $false
    $split.Panel1.Controls.Add($tree)

    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'
    $tpExplain = New-Object System.Windows.Forms.TabPage; $tpExplain.Text = 'Claims'
    $tpRoles   = New-Object System.Windows.Forms.TabPage; $tpRoles.Text = 'Roles / Scopes'
    $lvExplain = New-Object System.Windows.Forms.ListView
    $lvExplain.Dock = 'Fill'; $lvExplain.View = 'Details'; $lvExplain.FullRowSelect = $true; $lvExplain.GridLines = $true
    [void]$lvExplain.Columns.Add('Field', 120); [void]$lvExplain.Columns.Add('Value', 320); [void]$lvExplain.Columns.Add('Explanation', 420)
    $tpExplain.Controls.Add($lvExplain)
    $lvRoles = New-Object System.Windows.Forms.ListView
    $lvRoles.Dock = 'Fill'; $lvRoles.View = 'Details'; $lvRoles.FullRowSelect = $true; $lvRoles.GridLines = $true
    [void]$lvRoles.Columns.Add('Source', 180); [void]$lvRoles.Columns.Add('Value', 660)
    $tpRoles.Controls.Add($lvRoles)
    [void]$tabs.TabPages.Add($tpExplain); [void]$tabs.TabPages.Add($tpRoles)
    $split.Panel2.Controls.Add($tabs)

    $dlg.Controls.Add($split); $dlg.Controls.Add($bar); $dlg.Controls.Add($tokenBox)

    $refs = @{ tree = $tree; lvExplain = $lvExplain; lvRoles = $lvRoles }
    $btnDecode.Add_Click({ Update-PPJwtView $refs $tokenBox.Text }.GetNewClosure())
    $btnClear.Add_Click({ $tokenBox.Clear(); $tree.Nodes.Clear(); $lvExplain.Items.Clear(); $lvRoles.Items.Clear() }.GetNewClosure())

    # Prefill from the clipboard when it looks like a JWT, and decode on open.
    try {
        $clip = [System.Windows.Forms.Clipboard]::GetText()
        if ($clip -and (($clip -replace '\s', '') -match '^[\w-]+\.[\w-]+\.[\w-]*$')) { $tokenBox.Text = $clip.Trim() }
    } catch { }
    # On open: size the splitter (needs a realized height) and decode any prefilled token.
    $dlg.Add_Shown({
        try { $split.SplitterDistance = [int]($split.Height * 0.45) } catch { }
        if ($tokenBox.Text) { Update-PPJwtView $refs $tokenBox.Text }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($Global:PPApp.form)
    $dlg.Dispose()
}
