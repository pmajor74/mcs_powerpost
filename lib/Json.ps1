# Json.ps1 — pretty-printing helpers for the response viewer.

# Pretty-print a JSON string. Returns the original text unchanged if it isn't valid JSON.
function Format-PPJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    try {
        $obj = $Text | ConvertFrom-Json -ErrorAction Stop
        # ConvertTo-Json re-indents; -Depth high enough for typical API payloads.
        $pretty = $obj | ConvertTo-Json -Depth 30
        return $pretty
    } catch {
        return $Text
    }
}

# Does a Content-Type header look like JSON?
function Test-PPJsonContentType {
    param([string]$ContentType)
    if ([string]::IsNullOrWhiteSpace($ContentType)) { return $false }
    return ($ContentType -match 'json')
}
