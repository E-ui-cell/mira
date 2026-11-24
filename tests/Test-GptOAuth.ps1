#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\gemma\gemma.ps1')
)

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw ("GEMMA has PowerShell syntax errors; OAuth tests cannot run. First error: {0}" -f $errors[0].Message)
}

# Load only deterministic helpers. No browser, credentials, or network requests
# are used by this test.
foreach ($functionName in @(
    'ConvertTo-GptBase64Url',
    'ConvertFrom-GptBase64Url',
    'New-GptRandomToken',
    'Get-GptScopeList',
    'Test-GptPlanUsageEnabled',
    'Resolve-GptModel',
    'ConvertTo-GptResponsesInput'
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw "Required GEMMA function not found: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$originalBytes = New-Object byte[] 32
for ($i = 0; $i -lt $originalBytes.Length; $i++) { $originalBytes[$i] = [byte]$i }
$encoded = ConvertTo-GptBase64Url -Bytes $originalBytes
if ($encoded.Contains('=')) { throw 'Base64url output must not contain padding.' }
$decoded = ConvertFrom-GptBase64Url -Value $encoded
if ([Convert]::ToBase64String($decoded) -ne [Convert]::ToBase64String($originalBytes)) {
    throw 'Base64url round-trip failed.'
}

$randomA = New-GptRandomToken -ByteCount 32
$randomB = New-GptRandomToken -ByteCount 32
if ($randomA.Length -ne 43 -or $randomA -eq $randomB -or $randomA.Contains('=')) {
    throw 'OAuth random-token generation failed its length/uniqueness checks.'
}

$scopeList = @(Get-GptScopeList -Scope 'openid profile chatgpt.tokens.use.direct openid')
if ($scopeList.Count -ne 3 -or $scopeList -notcontains 'chatgpt.tokens.use.direct') {
    throw 'OAuth scope parsing did not preserve unique granted scopes.'
}
if (-not (Test-GptPlanUsageEnabled -Profile ([pscustomobject]@{ scopes = @('openid','chatgpt.tokens.use.direct') }))) {
    throw 'ChatGPT plan-usage scope detection failed for an authorized profile.'
}
if (Test-GptPlanUsageEnabled -Profile ([pscustomobject]@{ scopes = @('openid','profile') })) {
    throw 'Identity-only OAuth must not be treated as ChatGPT plan-usage authorization.'
}

if ((Resolve-GptModel -Model 'gpt-model-from-catalog') -ne 'gpt-model-from-catalog') {
    throw 'GPT model resolver changed the model slug.'
}
$modelRejected = $false
try { [void](Resolve-GptModel -Model ' ') } catch { $modelRejected = $true }
if (-not $modelRejected) { throw 'GPT model resolver accepted an empty model.' }

$history = @(
    [pscustomobject]@{ role = 'user'; parts = @([pscustomobject]@{ text = 'hello' }) },
    [pscustomobject]@{ role = 'model'; parts = @([pscustomobject]@{ text = 'hi there' }) },
    [pscustomobject]@{ role = 'user'; parts = @([pscustomobject]@{ functionResponse = [pscustomobject]@{ name = 'ignored' } }) }
)
$inputMessages = @(ConvertTo-GptResponsesInput -History $history)
if ($inputMessages.Count -ne 2 -or $inputMessages[0].role -ne 'user' -or
    $inputMessages[1].role -ne 'assistant' -or $inputMessages[1].content -ne 'hi there') {
    throw 'Gemini conversation history was not converted to Responses API user/assistant messages correctly.'
}

$sourceText = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
foreach ($required in @(
    'https://auth.openai.com/api/accounts/authorize',
    'https://auth.openai.com/api/accounts/oauth/token',
    'https://api.openai.com/v1/models',
    'https://api.openai.com/v1/responses',
    'code_challenge_method = ''S256''',
    'chatgpt.tokens.use.direct',
    'response.completed',
    'store = $false',
    'stream = $true',
    'ProtectedData]::Protect',
    'ProtectedData]::Unprotect'
)) {
    if (-not $sourceText.Contains($required)) { throw "Required official ChatGPT OAuth/Responses implementation marker is missing: $required" }
}
foreach ($forbidden in @(
    'chatgpt.com/backend-api',
    'Import-GptHarSession',
    'Get-GptHarCookieHeader',
    'MIRA_GPT_HAR_PATH',
    'openai-sentinel',
    'Turnstile',
    'SentinelExpiresUtc'
)) {
    if ($sourceText.Contains($forbidden)) { throw "Obsolete HAR/private-endpoint implementation remains: $forbidden" }
}

Write-Host 'GPT OAuth tests OK: PKCE/base64url helpers, unique state tokens, scope gating, model resolution, history conversion, DPAPI storage, public Responses API streaming, and removal of HAR/private endpoints.' -ForegroundColor Green
exit 0
