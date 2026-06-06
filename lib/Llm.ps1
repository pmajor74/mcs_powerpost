# Llm.ps1 — multi-provider LLM request build / response parse (UI-free, testable).
# Dialects (body shape): openai | anthropic | gemini  (Vertex reuses the gemini body).
# Auth:                  bearer | anthropic | googleApiKey | vertex (service-account JWT).

# --- Vertex service-account JWT (RS256) ---------------------------------------
# .NET Framework 4.8 has no RSA.ImportPkcs8PrivateKey, so parse the PKCS#8 DER by
# hand and sign with RSACng (which supports SHA-256). No external DLLs.
if (-not ([System.Management.Automation.PSTypeName]'PPVertexAuth').Type) {
    Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Text;

public static class PPVertexAuth {
    [ThreadStatic] static byte[] _buf;
    [ThreadStatic] static int _pos;

    static int ReadLen() {
        int b = _buf[_pos++];
        if ((b & 0x80) == 0) return b;
        int n = b & 0x7F, len = 0;
        for (int i = 0; i < n; i++) len = (len << 8) | _buf[_pos++];
        return len;
    }
    static void Skip() { _pos++; int len = ReadLen(); _pos += len; }
    static byte[] ReadInt() {
        if (_buf[_pos++] != 0x02) throw new Exception("expected INTEGER");
        int len = ReadLen();
        byte[] o = new byte[len];
        Array.Copy(_buf, _pos, o, 0, len); _pos += len;
        return o;
    }
    static byte[] Trim(byte[] a) {
        int i = 0; while (i < a.Length - 1 && a[i] == 0) i++;
        if (i == 0) return a;
        byte[] r = new byte[a.Length - i]; Array.Copy(a, i, r, 0, r.Length); return r;
    }
    static byte[] Pad(byte[] a, int size) {
        a = Trim(a);
        if (a.Length == size) return a;
        byte[] r = new byte[size];
        if (a.Length > size) Array.Copy(a, a.Length - size, r, 0, size);
        else Array.Copy(a, 0, r, size - a.Length, a.Length);
        return r;
    }
    static RSAParameters ParsePkcs8(string pem) {
        string b64 = pem.Replace("-----BEGIN PRIVATE KEY-----", "").Replace("-----END PRIVATE KEY-----", "")
                        .Replace("\r", "").Replace("\n", "").Replace(" ", "").Trim();
        _buf = Convert.FromBase64String(b64); _pos = 0;
        if (_buf[_pos++] != 0x30) throw new Exception("bad pkcs8"); ReadLen(); // outer SEQUENCE
        Skip();                                                                 // version
        Skip();                                                                 // algorithm SEQUENCE
        if (_buf[_pos++] != 0x04) throw new Exception("no octet string"); ReadLen(); // privateKey OCTET STRING
        if (_buf[_pos++] != 0x30) throw new Exception("bad rsaprivatekey"); ReadLen(); // RSAPrivateKey SEQUENCE
        Skip();                                                                 // version
        byte[] n = ReadInt(), e = ReadInt(), d = ReadInt(), p = ReadInt(),
               q = ReadInt(), dp = ReadInt(), dq = ReadInt(), iq = ReadInt();
        n = Trim(n);
        int mod = n.Length, half = (mod + 1) / 2;
        RSAParameters rp = new RSAParameters();
        rp.Modulus = n; rp.Exponent = Trim(e); rp.D = Pad(d, mod);
        rp.P = Pad(p, half); rp.Q = Pad(q, half);
        rp.DP = Pad(dp, half); rp.DQ = Pad(dq, half); rp.InverseQ = Pad(iq, half);
        return rp;
    }
    static string B64Url(byte[] b) {
        return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
    public static string MakeJwt(string clientEmail, string privateKeyPem, string aud, string scope, long iat, long exp) {
        string header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
        string claims = "{\"iss\":\"" + clientEmail + "\",\"scope\":\"" + scope + "\",\"aud\":\"" + aud
                      + "\",\"iat\":" + iat + ",\"exp\":" + exp + "}";
        string signingInput = B64Url(Encoding.UTF8.GetBytes(header)) + "." + B64Url(Encoding.UTF8.GetBytes(claims));
        RSAParameters rp = ParsePkcs8(privateKeyPem);
        using (RSACng rsa = new RSACng()) {
            rsa.ImportParameters(rp);
            byte[] sig = rsa.SignData(Encoding.UTF8.GetBytes(signingInput), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            return signingInput + "." + B64Url(sig);
        }
    }
    // Re-parse the key and verify a JWT signature (used by -SelfTest; also a sanity hook).
    public static bool VerifyJwt(string privateKeyPem, string jwt) {
        string[] parts = jwt.Split('.');
        if (parts.Length != 3) return false;
        byte[] data = Encoding.UTF8.GetBytes(parts[0] + "." + parts[1]);
        string s = parts[2].Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; }
        byte[] sig = Convert.FromBase64String(s);
        RSAParameters rp = ParsePkcs8(privateKeyPem);
        using (RSACng rsa = new RSACng()) {
            rsa.ImportParameters(rp);
            return rsa.VerifyData(data, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }
    }
}
'@
}

# Read an image file as inline data; mime guessed from the extension.
function Get-PPImageInlineData {
    param([string]$Path)
    $ext = ([System.IO.Path]::GetExtension($Path)).ToLowerInvariant()
    $mime = switch ($ext) {
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.gif'  { 'image/gif' }
        '.webp' { 'image/webp' }
        default { 'application/octet-stream' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return @{ mimeType = $mime; base64 = [Convert]::ToBase64String($bytes) }
}

# Build the request body (shape only) for a dialect. Returns @{ urlSuffix; body(json) }.
# Messages = @(@{ role='user'|'assistant'; text; images=@(paths) }).
function Build-PPLlmBody {
    param([string]$Dialect, [string]$Model, [string]$System, $Messages, $Params = @{})
    $maxTokens = 0
    if ($Params -and $Params.ContainsKey('maxTokens')) { $maxTokens = [int]$Params.maxTokens }
    $temp = $null
    if ($Params -and $Params.ContainsKey('temperature') -and "$($Params.temperature)" -ne '') { $temp = [double]$Params.temperature }
    $think = ''
    if ($Params -and $Params.ContainsKey('thinking')) { $think = [string]$Params.thinking }
    $thinkOn = ($think -and $think -ne 'Default')

    switch ($Dialect) {
        'anthropic' {
            $msgs = @()
            foreach ($m in @($Messages)) {
                $content = @()
                if ($m.text) { $content += @{ type = 'text'; text = [string]$m.text } }
                foreach ($img in @($m.images)) {
                    $d = Get-PPImageInlineData $img
                    $content += @{ type = 'image'; source = @{ type = 'base64'; media_type = $d.mimeType; data = $d.base64 } }
                }
                $msgs += @{ role = $m.role; content = $content }
            }
            $body = @{ model = $Model; max_tokens = $(if ($maxTokens -gt 0) { $maxTokens } else { 1024 }); messages = $msgs }
            if ($System) { $body.system = $System }
            if ($null -ne $temp) { $body.temperature = $temp }
            if ($thinkOn) {
                if ($think -eq 'Off') { $body.thinking = @{ type = 'disabled' } }
                else { $body.thinking = @{ type = 'adaptive' }; $body.output_config = @{ effort = $think.ToLower() } }
            }
            return @{ urlSuffix = '/messages'; body = ($body | ConvertTo-Json -Depth 15) }
        }
        'gemini' {
            $contents = @()
            foreach ($m in @($Messages)) {
                $parts = @()
                if ($m.text) { $parts += @{ text = [string]$m.text } }
                foreach ($img in @($m.images)) {
                    $d = Get-PPImageInlineData $img
                    $parts += @{ inline_data = @{ mime_type = $d.mimeType; data = $d.base64 } }
                }
                $role = if ($m.role -eq 'assistant') { 'model' } else { 'user' }
                $contents += @{ role = $role; parts = $parts }
            }
            $body = @{ contents = $contents }
            if ($System) { $body.systemInstruction = @{ parts = @(@{ text = $System }) } }
            $gen = @{}
            if ($maxTokens -gt 0) { $gen.maxOutputTokens = $maxTokens }
            if ($null -ne $temp) { $gen.temperature = $temp }
            if ($thinkOn) {
                # Gemini 3.x uses thinkingLevel (low/medium/high); 2.5 uses thinkingBudget (int).
                if ($Model -match '(?i)gemini-3') {
                    $lvl = switch ($think) { 'High' { 'high' } 'Medium' { 'medium' } default { 'low' } }
                    $gen.thinkingConfig = @{ thinkingLevel = $lvl }
                } else {
                    $budget = switch ($think) { 'Off' { 0 } 'Low' { 512 } 'Medium' { 2048 } 'High' { 8192 } default { $null } }
                    if ($null -ne $budget) { $gen.thinkingConfig = @{ thinkingBudget = $budget } }
                }
            }
            if ($gen.Count -gt 0) { $body.generationConfig = $gen }
            return @{ urlSuffix = "/models/$($Model):generateContent"; body = ($body | ConvertTo-Json -Depth 15) }
        }
        default {
            # openai
            $msgs = @()
            if ($System) { $msgs += @{ role = 'system'; content = $System } }
            foreach ($m in @($Messages)) {
                if (@($m.images).Count -gt 0) {
                    $parts = @()
                    if ($m.text) { $parts += @{ type = 'text'; text = [string]$m.text } }
                    foreach ($img in @($m.images)) {
                        $d = Get-PPImageInlineData $img
                        $parts += @{ type = 'image_url'; image_url = @{ url = "data:$($d.mimeType);base64,$($d.base64)" } }
                    }
                    $msgs += @{ role = $m.role; content = $parts }
                } else {
                    $msgs += @{ role = $m.role; content = [string]$m.text }
                }
            }
            $body = @{ model = $Model; messages = $msgs }
            if ($maxTokens -gt 0) { $body.max_tokens = $maxTokens }
            if ($null -ne $temp) { $body.temperature = $temp }
            # reasoning_effort only applies to reasoning models (o-series / gpt-5).
            if ($thinkOn -and $think -ne 'Off') { $body.reasoning_effort = $think.ToLower() }
            return @{ urlSuffix = '/chat/completions'; body = ($body | ConvertTo-Json -Depth 15) }
        }
    }
}

# The model's *effective* thinking level when no thinking param is sent (for the "Default (...)" label).
function Get-PPLlmEffectiveThinking {
    param([string]$Model, [string]$Dialect)
    switch ($Dialect) {
        'gemini' {
            if ($Model -match '(?i)gemini-(1\.5|2\.0)') { return 'none' }
            if ($Model -match '(?i)gemini-[3-9]') { if ($Model -match '(?i)flash') { return 'medium' } else { return 'high' } }
            if ($Model -match '(?i)gemini-2\.5') { return 'dynamic' }
            return ''
        }
        'anthropic' { return 'off' }
        default { return 'model default' }
    }
}

# The least-thinking option that's safe for a model (Off where it can disable; else the lowest level).
function Get-PPLlmLowestThinking {
    param([string]$Model, [string]$Dialect)
    switch ($Dialect) {
        'gemini' {
            if ($Model -match '(?i)gemini-(1\.5|2\.0)') { return 'Default' }  # non-thinking models
            if ($Model -match '(?i)gemini-[3-9]') { return 'Low' }            # no "off"; low is safe everywhere
            if ($Model -match '(?i)flash') { return 'Off' }                   # 2.5 flash can disable thinking
            return 'Low'                                                      # 2.5 pro etc. can't fully disable
        }
        'anthropic' { return 'Off' }
        default { return 'Off' }   # openai: "Off" sends no reasoning_effort (safe on non-reasoning models)
    }
}

# Acquire/refresh a Vertex AI access token via service-account JWT -> OAuth exchange.
function Get-PPVertexToken {
    param($Provider, [int]$TimeoutSec = 100)
    if ([string]::IsNullOrEmpty($Provider.clientEmail) -or [string]::IsNullOrEmpty($Provider.privateKey)) {
        return @{ ok = $false; error = 'Vertex provider needs clientEmail and privateKey.' }
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $aud = 'https://oauth2.googleapis.com/token'
    $scope = 'https://www.googleapis.com/auth/cloud-platform'
    try { $jwt = [PPVertexAuth]::MakeJwt($Provider.clientEmail, $Provider.privateKey, $aud, $scope, [long]$now, [long]($now + 3600)) }
    catch { return @{ ok = $false; error = "JWT signing failed: $($_.Exception.Message)" } }
    $form = @( (New-PPKv $true 'grant_type' 'urn:ietf:params:oauth:grant-type:jwt-bearer'), (New-PPKv $true 'assertion' $jwt) )
    $resp = Invoke-PPRequest -Method 'POST' -Url $aud -BodyType 'form' -Form $form -TimeoutSec $TimeoutSec
    return (Set-PPTokenFromResponse $Provider $resp)
}

# Build the auth headers (+ Content-Type) for a provider. For vertex, fetches/refreshes a token.
function Resolve-PPLlmAuthHeaders {
    param($Provider, [int]$TimeoutSec = 100)
    $h = @(@{ key = 'Content-Type'; value = 'application/json' })
    switch ($Provider.auth) {
        'bearer'       { if ($Provider.apiKey) { $h += @{ key = 'Authorization'; value = "Bearer $($Provider.apiKey)" } }; return @{ ok = $true; headers = $h } }
        'anthropic'    { $h += @{ key = 'x-api-key'; value = $Provider.apiKey }; $h += @{ key = 'anthropic-version'; value = '2023-06-01' }; return @{ ok = $true; headers = $h } }
        'googleApiKey' { $h += @{ key = 'x-goog-api-key'; value = $Provider.apiKey }; return @{ ok = $true; headers = $h } }
        'vertex' {
            if (-not (Test-PPTokenValid $Provider)) {
                $r = Get-PPVertexToken $Provider $TimeoutSec
                if (-not $r.ok) { return @{ ok = $false; error = $r.error; headers = @() } }
            }
            $h += @{ key = 'Authorization'; value = "Bearer $($Provider.accessToken)" }
            return @{ ok = $true; headers = $h }
        }
        default { return @{ ok = $true; headers = $h } }
    }
}

# Extract assistant text + usage from a provider response (Resp = Invoke-PPRequest result).
function Read-PPLlmResponse {
    param([string]$Dialect, $Resp)
    if (-not $Resp.ok) { return @{ ok = $false; error = $Resp.error; raw = [string]$Resp.error } }
    $raw = [string]$Resp.body
    if ($Resp.statusCode -ge 400) { return @{ ok = $false; error = "HTTP $($Resp.statusCode): $raw"; raw = $raw } }
    try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return @{ ok = $false; error = "Non-JSON response: $raw"; raw = $raw } }
    $text = ''; $usage = $null; $finish = ''
    try {
        switch ($Dialect) {
            'anthropic' {
                foreach ($b in @($data.content)) { if ($b.type -eq 'text') { $text += [string]$b.text } }
                $usage = $data.usage; $finish = [string]$data.stop_reason
            }
            'gemini' {
                $cand = @($data.candidates)[0]
                foreach ($p in @($cand.content.parts)) { if ($null -ne $p.text) { $text += [string]$p.text } }
                $usage = $data.usageMetadata; $finish = [string]$cand.finishReason
            }
            default {
                $ch = @($data.choices)[0]
                $text = [string]$ch.message.content; $usage = $data.usage; $finish = [string]$ch.finish_reason
            }
        }
    } catch { return @{ ok = $false; error = "Unexpected response shape: $raw"; raw = $raw } }
    if ([string]::IsNullOrEmpty($text)) {
        # 200 OK but no text — usually the token budget was spent (thinking models) or content was blocked.
        $note = '(No text returned'
        if ($finish) { $note += "; finishReason=$finish" }
        $note += '.)'
        if ($finish -match 'MAX_TOKENS|length|max_tokens') {
            $note += ' The token limit was reached before any answer text was produced — thinking models (e.g. Gemini 3.x) spend the budget on reasoning first. Increase Max tok and resend.'
        }
        $text = $note
    }
    return @{ ok = $true; text = $text; usage = $usage; raw = $raw; finishReason = $finish }
}

# Full round-trip: expand {{vars}}, build, auth, send, parse. Returns text/usage/raw/request.
function Invoke-PPLlmChat {
    param($Provider, [string]$Model, [string]$System, $Messages, $Params = @{}, [int]$TimeoutSec = 100, $Map = @{})
    $prov = $Provider.Clone()
    $prov.apiKey      = Expand-PPVars ([string]$Provider.apiKey) $Map
    $prov.baseUrl     = Expand-PPVars ([string]$Provider.baseUrl) $Map
    $prov.clientEmail = Expand-PPVars ([string]$Provider.clientEmail) $Map
    $prov.privateKey  = Expand-PPVars ([string]$Provider.privateKey) $Map
    $model = Expand-PPVars $Model $Map

    $built = Build-PPLlmBody $Provider.dialect $model $System $Messages $Params
    $auth = Resolve-PPLlmAuthHeaders $prov $TimeoutSec
    # Carry any freshly fetched vertex token back to the persisted provider.
    $Provider.accessToken = $prov.accessToken
    $Provider.tokenExpiry = $prov.tokenExpiry
    if (-not $auth.ok) { return @{ ok = $false; error = $auth.error; request = @{ url = ''; body = $built.body } } }

    $url = ($prov.baseUrl.TrimEnd('/')) + $built.urlSuffix
    $resp = Invoke-PPRequest -Method 'POST' -Url $url -AuthHeaders $auth.headers -BodyType 'json' -Body $built.body -TimeoutSec $TimeoutSec
    $parsed = Read-PPLlmResponse $Provider.dialect $resp
    # Surface full REST detail for the Playground (status/time/size/headers + exact request).
    $parsed.request = @{ method = 'POST'; url = $url; headers = $auth.headers; body = $built.body }
    $parsed.response = $resp
    return $parsed
}

# Convert an external llm-providers.json (the owner's schema) into PowerPost providers.
# VertexAI entries that share an endpoint + service account are consolidated into ONE
# "Google Vertex" provider whose Model dropdown lists all their models (it's one endpoint +
# credential — the model is just a selection). Other entries are read as-is.
function ConvertFrom-PPProviderFile {
    param([string]$JsonText)
    $data = $JsonText | ConvertFrom-Json -ErrorAction Stop
    $providers = @()
    $vertexByKey = @{}
    foreach ($e in @($data)) {
        $kind = [string](Get-PPProp $e 'Provider' '')
        if ($kind -ieq 'VertexAI') {
            $endpoint = [string](Get-PPProp $e 'Endpoint' '')
            $email = [string](Get-PPProp $e 'ClientEmail' '')
            $model = [string](Get-PPProp $e 'Model' '')
            $key = "$endpoint|$email"
            if (-not $vertexByKey.ContainsKey($key)) {
                $p = New-PPLlmProvider
                $p.name        = 'Google Vertex'
                $p.dialect     = 'gemini'
                $p.auth        = 'vertex'
                $p.baseUrl     = $endpoint
                $p.clientEmail = $email
                $p.privateKey  = [string](Get-PPProp $e 'PrivateKey' '')
                $p.maxRetries  = [int](Get-PPProp $e 'MaxRetries' 0)
                $p.models      = @()
                $vertexByKey[$key] = $p
                $providers += $p
            }
            $p = $vertexByKey[$key]
            if ($model -and (@($p.models) -notcontains $model)) { $p.models = @($p.models) + @($model) }
            if ([string]::IsNullOrEmpty($p.model) -and $model) { $p.model = $model }
        } else {
            $providers += (Resolve-PPLlmProvider $e)
        }
    }
    # Disambiguate names if there are multiple distinct Vertex projects.
    $vn = 0
    foreach ($p in $providers) { if ($p.auth -eq 'vertex') { $vn++; if ($vn -gt 1) { $p.name = "Google Vertex ($vn)" } } }
    return , $providers
}
