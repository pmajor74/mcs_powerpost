# State.ps1 — load/save the app state as JSON next to the script.
# $Global:PPRoot is set by the entry script (PowerPost.ps1) to its own folder.

function Get-PPStatePath {
    $root = $Global:PPRoot
    if ([string]::IsNullOrEmpty($root)) { $root = (Get-Location).Path }
    return (Join-Path $root 'powerpost.state.json')
}

function Save-PPState {
    param($State, [string]$Path)
    if (-not $Path) { $Path = Get-PPStatePath }
    $json = $State | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    return $Path
}

function Load-PPState {
    param([string]$Path)
    if (-not $Path) { $Path = Get-PPStatePath }
    if (-not (Test-Path -LiteralPath $Path)) { return (New-PPState) }
    try {
        $raw = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json -ErrorAction Stop
        return (Resolve-PPState $raw)
    } catch {
        # Corrupt/unreadable: keep a backup so nothing is silently lost, start fresh.
        try { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force } catch { }
        return (New-PPState)
    }
}
