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
    throw ("GEMMA has PowerShell syntax errors; cookie tests cannot run. First error: {0}" -f $errors[0].Message)
}

# Load only the four functions under test. This avoids starting the interactive
# GEMMA loop or making any network request.
foreach ($functionName in @('Get-GptHarHeaderMap', 'Get-GptHeaderValue', 'Get-GptHarCookieHeader', 'New-GptWebRequest', 'Resolve-GptModel', 'Get-GptModels')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)

    if ($null -eq $functionAst) {
        throw "Required GEMMA function not found: $functionName"
    }

    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:GptSession = [pscustomobject]@{}
$gptModels = @(Get-GptModels)
if ($gptModels.Count -ne 1 -or [string]$gptModels[0].name -ne 'auto') {
    throw 'The experimental GPT model catalogue must expose only the automatic model selection.'
}
if ((Resolve-GptModel -Model 'auto') -ne 'auto') {
    throw 'The experimental GPT provider did not preserve automatic model routing.'
}
$rejectedPinnedModel = $false
try { [void](Resolve-GptModel -Model 'gpt-6-luna') } catch { $rejectedPinnedModel = $true }
if (-not $rejectedPinnedModel) {
    throw 'The experimental GPT provider must not silently pin gpt-6-luna when Auto is selected.'
}

$cookiePairs = New-Object System.Collections.Generic.List[string]
[void]$cookiePairs.Add('__Secure-next-auth.session-token=synthetic-session-token')
for ($i = 1; $i -le 27; $i++) {
    [void]$cookiePairs.Add(('test_cookie_{0:D2}=value{0:D2}' -f $i))
}
[void]$cookiePairs.Add('g_state={"i_l":0,"i_e":1700000000}')
$cookieHeader = [string]::Join('; ', $cookiePairs.ToArray())

$harEntry = [pscustomobject]@{
    request = [pscustomobject]@{
        headers = @([pscustomobject]@{ name = 'Cookie'; value = $cookieHeader })
        cookies = @()
    }
}

$importedCookieHeader = Get-GptHarCookieHeader -Entries @($harEntry)
if ($importedCookieHeader -ne $cookieHeader) {
    throw 'HAR Cookie header extraction changed the original cookie header.'
}

$session = [pscustomobject]@{
    UserAgent = 'Mozilla/5.0'
    Referer = 'https://chatgpt.com/'
    Cookie = $importedCookieHeader
    Authorization = 'Bearer synthetic-test-token'
    Headers = @{}
    Origin = 'https://chatgpt.com'
}

$request = New-GptWebRequest -Uri 'https://chatgpt.com/backend-api/models' -Method 'GET' -Session $session
$jar = $request.CookieContainer.GetCookies([uri]'https://chatgpt.com/')

if ($jar.Count -ne 28) {
    throw "Expected 28 usable cookies after ignoring g_state; found $($jar.Count)."
}
if ($null -eq $jar['__Secure-next-auth.session-token']) {
    throw 'The ChatGPT session cookie was not retained.'
}
if ($null -ne $jar['g_state']) {
    throw 'The unrelated JSON-valued g_state cookie should not be sent.'
}
if ($jar.Count -le 20) {
    throw 'CookieContainer capacity test failed; the HAR has more than 20 usable cookies.'
}

$fallbackEntry = [pscustomobject]@{
    request = [pscustomobject]@{
        headers = @()
        cookies = @(
            [pscustomobject]@{ name = 'session'; value = 'fallback-token' },
            [pscustomobject]@{ name = 'oai-did'; value = 'synthetic-device-id' }
        )
    }
}
$fallbackHeader = Get-GptHarCookieHeader -Entries @($fallbackEntry)
if ($fallbackHeader -notmatch 'session=fallback-token' -or $fallbackHeader -notmatch 'oai-did=synthetic-device-id') {
    throw 'HAR request.cookies fallback did not reconstruct the cookie header.'
}

Write-Host 'GPT provider tests OK: Auto model routing selected; HAR cookie handling retains the session, ignores g_state, supports 28 cookies, and uses request.cookies fallback.' -ForegroundColor Green
exit 0
