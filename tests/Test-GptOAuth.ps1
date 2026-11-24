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
# are used by this test. Define them together in the test script scope so helper
# functions called by other extracted functions are visible in both PS 5.1 and 7.
$functionDefinitions = New-Object System.Collections.Generic.List[string]
foreach ($functionName in @(
    'ConvertTo-GptBase64Url',
    'ConvertFrom-GptBase64Url',
    'New-GptRandomToken',
    'Get-GptScopeList',
    'Test-GptPlanUsageEnabled',
    'Test-GptIdToken',
    'Resolve-GptModel',
    'Get-GptObjectProperty',
    'ConvertTo-GptResponsesInput',
    'Get-GptToolDefinitions'
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw "Required GEMMA function not found: $functionName" }
    [void]$functionDefinitions.Add($functionAst.Extent.Text)
}
. ([scriptblock]::Create([string]::Join([Environment]::NewLine, $functionDefinitions.ToArray())))

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

# Exercise the RS256/JWKS/issuer/audience/expiry/nonce validation path without
# making a network request or using a real OpenAI token.
$rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new(2048)
try {
    $publicKey = $rsa.ExportParameters($false)
    $testJwks = [pscustomobject]@{
        keys = @(
            [pscustomobject]@{
                kid = 'gemma-ci-key'
                kty = 'RSA'
                n = (ConvertTo-GptBase64Url -Bytes $publicKey.Modulus)
                e = (ConvertTo-GptBase64Url -Bytes $publicKey.Exponent)
            }
        )
    }
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01T00:00:00', [DateTimeKind]::Utc)
    $nowSeconds = [long]([DateTime]::UtcNow - $epoch).TotalSeconds
    $testHeader = ConvertTo-GptBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","kid":"gemma-ci-key","typ":"JWT"}'))
    $testClaims = @{
        iss = 'https://auth.openai.com'
        aud = 'gemma-ci-client'
        sub = 'synthetic-subject'
        email = 'gemma-ci@example.invalid'
        nonce = 'synthetic-nonce'
        iat = $nowSeconds
        nbf = ($nowSeconds - 5)
        exp = ($nowSeconds + 3600)
    } | ConvertTo-Json -Compress
    $testPayload = ConvertTo-GptBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($testClaims))
    $signingInput = $testHeader + '.' + $testPayload
    $signature = $rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($signingInput), 'SHA256')
    $testJwt = $signingInput + '.' + (ConvertTo-GptBase64Url -Bytes $signature)
    $verifiedClaims = Test-GptIdToken -IdToken $testJwt -ClientId 'gemma-ci-client' -Nonce 'synthetic-nonce' -Jwks $testJwks
    if ($verifiedClaims.sub -ne 'synthetic-subject') { throw 'Synthetic ID-token validation returned the wrong subject.' }

    $badNonceRejected = $false
    try { [void](Test-GptIdToken -IdToken $testJwt -ClientId 'gemma-ci-client' -Nonce 'wrong-nonce' -Jwks $testJwks) } catch { $badNonceRejected = $true }
    if (-not $badNonceRejected) { throw 'ID-token validator accepted an incorrect nonce.' }

    $badAudienceRejected = $false
    try { [void](Test-GptIdToken -IdToken $testJwt -ClientId 'another-client' -Nonce 'synthetic-nonce' -Jwks $testJwks) } catch { $badAudienceRejected = $true }
    if (-not $badAudienceRejected) { throw 'ID-token validator accepted an incorrect audience.' }
} finally {
    $rsa.Dispose()
}

# Verify the CurrentUser DPAPI primitive used by the saved OAuth profile under
# both Windows PowerShell 5.1 and PowerShell 7.
try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $dpapiPlain = [System.Text.Encoding]::UTF8.GetBytes('gemma-dpapi-ci')
    $dpapiProtected = [System.Security.Cryptography.ProtectedData]::Protect(
        $dpapiPlain,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $dpapiRestored = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $dpapiProtected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    if ([System.Text.Encoding]::UTF8.GetString($dpapiRestored) -ne 'gemma-dpapi-ci') {
        throw 'DPAPI round-trip returned different bytes.'
    }
} catch {
    throw "Windows CurrentUser DPAPI is unavailable or failed under PowerShell $($PSVersionTable.PSVersion): $($_.Exception.Message)"
}

if ((Resolve-GptModel -Model 'gpt-model-from-catalog') -ne 'gpt-model-from-catalog') {
    throw 'GPT model resolver changed the model slug.'
}
$modelRejected = $false
try { [void](Resolve-GptModel -Model ' ') } catch { $modelRejected = $true }
if (-not $modelRejected) { throw 'GPT model resolver accepted an empty model.' }

$history = @(
    [pscustomobject]@{ role = 'user'; parts = @([pscustomobject]@{ text = 'hello' }) },
    [pscustomobject]@{ role = 'model'; parts = @([pscustomobject]@{ text = 'hi there' }) }
)
$inputMessages = @(ConvertTo-GptResponsesInput -History $history)
if ($inputMessages.Count -ne 2 -or $inputMessages[0].role -ne 'user' -or
    $inputMessages[1].role -ne 'assistant' -or $inputMessages[1].content -ne 'hi there') {
    throw 'GEMMA conversation history was not converted to Responses API user/assistant messages correctly.'
}

# The live chat loop stores turns and content parts as PowerShell hashtables.
# Exercise that exact representation so normal text cannot disappear on conversion.
$hashtableHistory = @(
    @{
        role = 'user'
        parts = @(@{ text = 'hello from a hashtable' })
    }
)
$hashtableInput = @(ConvertTo-GptResponsesInput -History $hashtableHistory)
if ($hashtableInput.Count -ne 1 -or $hashtableInput[0].role -ne 'user' -or
    $hashtableInput[0].content -ne 'hello from a hashtable') {
    throw 'PowerShell hashtable conversation turns were not converted to Responses API input.'
}

$toolDefinitions = @(Get-GptToolDefinitions)
$toolNames = @($toolDefinitions | ForEach-Object { [string]$_.name })
foreach ($requiredTool in @('get_current_datetime','run_powershell','quick_web','get_skill')) {
    if ($toolNames -notcontains $requiredTool) { throw "GPT function tool definition is missing: $requiredTool" }
}
if ($toolDefinitions.Count -ne 4) { throw 'Unexpected GPT local tool definition count.' }

$toolCallItem = [pscustomobject]@{
    type = 'function_call'
    name = 'run_powershell'
    call_id = 'call_gemma_test'
    arguments = '{"command":"Get-Date"}'
}
$toolHistory = @(
    [pscustomobject]@{ role = 'model'; parts = @(); response_items = @($toolCallItem) },
    [pscustomobject]@{
        role = 'user'
        parts = @(
            [pscustomobject]@{
                functionResponse = [pscustomobject]@{
                    id = 'call_gemma_test'
                    response = [pscustomobject]@{ approved = $true; output = 'synthetic output' }
                }
            }
        )
    }
)
$toolInput = @(ConvertTo-GptResponsesInput -History $toolHistory)
if ($toolInput.Count -ne 2 -or $toolInput[0].type -ne 'function_call' -or
    $toolInput[1].type -ne 'function_call_output' -or
    $toolInput[1].call_id -ne 'call_gemma_test') {
    throw 'Responses API function_call/function_call_output history conversion failed.'
}
$toolOutputObject = $toolInput[1].output | ConvertFrom-Json
if (-not $toolOutputObject.approved -or $toolOutputObject.output -ne 'synthetic output') {
    throw 'Function tool output was not serialized correctly.'
}

$imageHistory = @(
    [pscustomobject]@{
        role = 'user'
        parts = @(
            [pscustomobject]@{ inline_data = [pscustomobject]@{ mime_type = 'image/png'; data = 'YWJj' } },
            [pscustomobject]@{ text = 'Describe this image.' }
        )
    }
)
$imageInput = @(ConvertTo-GptResponsesInput -History $imageHistory)
if ($imageInput.Count -ne 1 -or $imageInput[0].content.Count -ne 2 -or
    $imageInput[0].content[0].type -ne 'input_image' -or
    $imageInput[0].content[0].image_url -ne 'data:image/png;base64,YWJj' -or
    $imageInput[0].content[1].type -ne 'input_text') {
    throw 'ChatGPT Responses image input conversion failed.'
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
    'AllowReadStreamBuffering = $false',
    'ErrorDetails.Message',
    'openai-request-id',
    'x-request-id',
    'ProtectedData]::Protect',
    'ProtectedData]::Unprotect',
    "type = 'additional_tools'",
    "type = 'function_call_output'",
    "type = 'input_image'",
    "type = 'web_search'",
    'reasoning = @{ effort = $script:Effort }',
    "$MIRA_DEFAULT_MODEL = ''",
    'Invoke-GptModelSwitcher',
    'Invoke-GemmaWebSearchCommand',
    'Get-GptObjectProperty',
    'ChatGPT plan usage is not authorized for this account/workspace'
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
    'SentinelExpiresUtc',
    'Antigravity',
    'Gemini',
    'GEMINI_APIJ',
    'AGY_',
    'generativelanguage.googleapis.com',
    'daily-cloudcode-pa.googleapis.com',
    'MIRA_DEFAULT_PROVIDER',
    'script:Provider',
    '.provider',
    '.grounding',
    'Get-Antigravity',
    'Invoke-Gemini',
    'Save-GeminiCodeBlocks'
)) {
    if ($sourceText.Contains($forbidden)) { throw "Obsolete HAR/private-endpoint implementation remains: $forbidden" }
}

Write-Host 'GPT-only tests OK: OAuth/PKCE, scope gating, account model catalogue, Responses API streaming, local function tools, web search, image input, DPAPI storage, and removal of Gemini/Antigravity/HAR paths.' -ForegroundColor Green
exit 0
