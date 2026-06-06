# Import.ps1 — turn an OpenAPI/Swagger spec or a Postman collection into a PowerPost
# collection (New-PPCollection of New-PPTab requests). UI-free so -SelfTest can cover it.

# --- OpenAPI / Swagger schema -> example JSON ---

function Resolve-PPSchemaRef {
    param($Schema, $Root)
    $ref = Get-PPProp $Schema '$ref' $null
    if ($ref) {
        $node = $Root
        foreach ($seg in (($ref -replace '^#/', '') -split '/')) {
            $node = Get-PPProp $node $seg $null
            if ($null -eq $node) { return $null }
        }
        return $node
    }
    return $Schema
}

function Get-PPSchemaExample {
    param($Schema, $Root, [int]$Depth = 0)
    if ($null -eq $Schema -or $Depth -gt 5) { return $null }
    $Schema = Resolve-PPSchemaRef $Schema $Root
    if ($null -eq $Schema) { return $null }
    $ex = Get-PPProp $Schema 'example' $null
    if ($null -ne $ex) { return $ex }
    $props = Get-PPProp $Schema 'properties' $null
    $type = [string](Get-PPProp $Schema 'type' '')
    if ($null -ne $props -or $type -eq 'object') {
        $obj = [ordered]@{}
        if ($null -ne $props) { foreach ($pr in $props.PSObject.Properties) { $obj[$pr.Name] = Get-PPSchemaExample $pr.Value $Root ($Depth + 1) } }
        return $obj
    }
    if ($type -eq 'array') { return @( Get-PPSchemaExample (Get-PPProp $Schema 'items' $null) $Root ($Depth + 1) ) }
    switch ($type) {
        'string'  { $en = Get-PPProp $Schema 'enum' $null; if ($en) { return [string]@($en)[0] }
                    switch ([string](Get-PPProp $Schema 'format' '')) { 'date-time' { return '2026-01-01T00:00:00Z' } 'date' { return '2026-01-01' } 'uuid' { return '00000000-0000-0000-0000-000000000000' } default { return 'string' } } }
        'integer' { return 0 }
        'number'  { return 0 }
        'boolean' { return $false }
        default   { return $null }
    }
}

function Get-PPSchemaExampleJson {
    param($Schema, $Root)
    $ex = Get-PPSchemaExample $Schema $Root 0
    if ($null -eq $ex) { return '{}' }
    return ($ex | ConvertTo-Json -Depth 12)
}

function ConvertFrom-PPOpenApi {
    param($Doc)
    $title = [string](Get-PPProp (Get-PPProp $Doc 'info' $null) 'title' 'Imported API')
    $col = New-PPCollection $title

    $base = ''
    if (Get-PPProp $Doc 'openapi' $null) {
        $servers = @(Get-PPProp $Doc 'servers' @())
        if ($servers.Count -gt 0) { $base = [string](Get-PPProp $servers[0] 'url' '') }
    } else {
        $schemes = @(Get-PPProp $Doc 'schemes' @())
        $scheme = if ($schemes.Count -gt 0) { [string]$schemes[0] } else { 'https' }
        $hostName = [string](Get-PPProp $Doc 'host' '')
        $basePath = [string](Get-PPProp $Doc 'basePath' '')
        if ($hostName) { $base = "$scheme`://$hostName$basePath" }
    }

    $paths = Get-PPProp $Doc 'paths' $null
    if ($null -ne $paths) {
        foreach ($pp in $paths.PSObject.Properties) {
            $pathUrl = $pp.Name
            $ops = $pp.Value
            foreach ($m in 'get', 'post', 'put', 'patch', 'delete', 'head', 'options') {
                $op = Get-PPProp $ops $m $null
                if ($null -eq $op) { continue }
                $t = New-PPTab
                $t.method = $m.ToUpper()
                $t.url = ($base.TrimEnd('/')) + $pathUrl
                $opId = [string](Get-PPProp $op 'operationId' '')
                $summary = [string](Get-PPProp $op 'summary' '')
                $t.name = if ($opId) { $opId } elseif ($summary) { "$($t.method) $summary" } else { "$($t.method) $pathUrl" }

                foreach ($pa in @(Get-PPProp $op 'parameters' @())) {
                    $in = [string](Get-PPProp $pa 'in' '')
                    $nm = [string](Get-PPProp $pa 'name' '')
                    if (-not $nm) { continue }
                    if ($in -eq 'query') { $t.params += (New-PPKv $false $nm '') }       # imported disabled; enable as needed
                    elseif ($in -eq 'header') { $t.headers += (New-PPKv $false $nm '') }
                    elseif ($in -eq 'body') {
                        $schema = Get-PPProp $pa 'schema' $null
                        if ($null -ne $schema) { $t.bodyType = 'json'; $t.body = (Get-PPSchemaExampleJson $schema $Doc) }
                    }
                }

                $rb = Get-PPProp $op 'requestBody' $null
                if ($null -ne $rb) {
                    $content = Get-PPProp $rb 'content' $null
                    $json = if ($null -ne $content) { Get-PPProp $content 'application/json' $null } else { $null }
                    if ($null -ne $json) {
                        $schema = Get-PPProp $json 'schema' $null
                        if ($null -ne $schema) { $t.bodyType = 'json'; $t.body = (Get-PPSchemaExampleJson $schema $Doc) }
                    }
                }
                $col.requests += $t
            }
        }
    }
    return $col
}

# --- Postman v2.x ---

function Convert-PPPostmanItems {
    param($Items, [string]$Prefix, $Col)
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $sub = Get-PPProp $it 'item' $null
        if ($null -ne $sub) {
            $folder = [string](Get-PPProp $it 'name' '')
            $np = if ($Prefix) { "$Prefix / $folder" } else { $folder }
            Convert-PPPostmanItems $sub $np $Col
            continue
        }
        $req = Get-PPProp $it 'request' $null
        if ($null -eq $req) { continue }
        $t = New-PPTab
        $nm = [string](Get-PPProp $it 'name' 'Request')
        $t.name = if ($Prefix) { "$Prefix / $nm" } else { $nm }
        $t.method = ([string](Get-PPProp $req 'method' 'GET')).ToUpper()

        $url = Get-PPProp $req 'url' $null
        if ($url -is [string]) { $t.url = [string]$url }
        elseif ($null -ne $url) { $t.url = [string](Get-PPProp $url 'raw' '') }

        foreach ($h in @(Get-PPProp $req 'header' @())) {
            if ($null -eq $h) { continue }
            $t.headers += (New-PPKv (-not [bool](Get-PPProp $h 'disabled' $false)) ([string](Get-PPProp $h 'key' '')) ([string](Get-PPProp $h 'value' '')))
        }

        $body = Get-PPProp $req 'body' $null
        if ($null -ne $body) {
            switch ([string](Get-PPProp $body 'mode' '')) {
                'raw' {
                    $raw = [string](Get-PPProp $body 'raw' '')
                    $lang = ''
                    $opt = Get-PPProp $body 'options' $null
                    if ($null -ne $opt) { $ro = Get-PPProp $opt 'raw' $null; if ($null -ne $ro) { $lang = [string](Get-PPProp $ro 'language' '') } }
                    $t.bodyType = if ($lang -eq 'json' -or $raw -match '^\s*[\{\[]') { 'json' } else { 'text' }
                    $t.body = $raw
                }
                'urlencoded' {
                    $t.bodyType = 'form'
                    foreach ($kv in @(Get-PPProp $body 'urlencoded' @())) { if ($null -ne $kv) { $t.form += (New-PPKv (-not [bool](Get-PPProp $kv 'disabled' $false)) ([string](Get-PPProp $kv 'key' '')) ([string](Get-PPProp $kv 'value' ''))) } }
                }
                'formdata' {
                    $t.bodyType = 'multipart'
                    foreach ($fd in @(Get-PPProp $body 'formdata' @())) {
                        if ($null -eq $fd) { continue }
                        if ([string](Get-PPProp $fd 'type' 'text') -eq 'file') { $t.multipart += (New-PPMultipartRow $true ([string](Get-PPProp $fd 'key' '')) 'file' ([string](Get-PPProp $fd 'src' ''))) }
                        else { $t.multipart += (New-PPMultipartRow $true ([string](Get-PPProp $fd 'key' '')) 'text' ([string](Get-PPProp $fd 'value' ''))) }
                    }
                }
            }
        }

        $auth = Get-PPProp $req 'auth' $null
        if ($null -ne $auth) {
            switch ([string](Get-PPProp $auth 'type' '')) {
                'bearer' {
                    $tok = ''
                    foreach ($x in @(Get-PPProp $auth 'bearer' @())) { if ([string](Get-PPProp $x 'key' '') -eq 'token') { $tok = [string](Get-PPProp $x 'value' '') } }
                    $t.auth.type = 'bearer'; $t.auth.bearerToken = $tok
                }
                'basic' {
                    $u = ''; $pw = ''
                    foreach ($x in @(Get-PPProp $auth 'basic' @())) { $k = [string](Get-PPProp $x 'key' ''); if ($k -eq 'username') { $u = [string](Get-PPProp $x 'value' '') } elseif ($k -eq 'password') { $pw = [string](Get-PPProp $x 'value' '') } }
                    $t.auth.type = 'basic'; $t.auth.basicUser = $u; $t.auth.basicPass = $pw
                }
            }
        }
        $Col.requests += $t
    }
}

function ConvertFrom-PPPostman {
    param($Doc)
    $name = [string](Get-PPProp (Get-PPProp $Doc 'info' $null) 'name' 'Imported Collection')
    $col = New-PPCollection $name
    Convert-PPPostmanItems (Get-PPProp $Doc 'item' @()) '' $col
    return $col
}

# Detect the format and convert. Returns a New-PPCollection; throws on unknown input.
function ConvertFrom-PPApiSpec {
    param([string]$Text)
    $doc = $Text | ConvertFrom-Json -ErrorAction Stop
    if (Get-PPProp $doc 'openapi' $null) { return ConvertFrom-PPOpenApi $doc }
    if (Get-PPProp $doc 'swagger' $null) { return ConvertFrom-PPOpenApi $doc }
    if (($null -ne (Get-PPProp $doc 'info' $null)) -and ($null -ne (Get-PPProp $doc 'item' $null))) { return ConvertFrom-PPPostman $doc }
    throw 'Unrecognized file: expected an OpenAPI/Swagger spec or a Postman collection.'
}
