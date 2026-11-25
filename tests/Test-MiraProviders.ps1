#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\mira.ps1')
)

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
$source = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw 'mira.ps1 has parser errors; run Test-ScriptSyntax.ps1 for details.'}

function Assert-MiraTest([bool]$Condition,[string]$Message){
    if(-not $Condition){throw ('MIRA provider test failed: '+$Message)}
}

# Load only the editable settings assignment, not the interactive application.
$configStart = $source.IndexOf('$script:MiraSettings = [ordered]@{')
$configEnd = $source.IndexOf('# Normalize the Windows 7 Explorer', $configStart)
if($configStart -lt 0 -or $configEnd -le $configStart){throw 'Could not locate the MIRA settings block.'}
Invoke-Expression $source.Substring($configStart,$configEnd-$configStart)

$functionNames = @(
    'New-BuiltinProviders',
    'Get-Provider',
    'Get-ProviderKeyEnvironmentNames',
    'Get-ProviderKey',
    'Get-ProviderRefreshKey',
    'New-MiraAntigravityEnvelope',
    'ConvertFrom-MiraGoogleStreamEvent',
    'Get-MiraAntigravityModels',
    'Show-Response'
)
foreach($functionName in $functionNames){
    $functionAsts = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    },$true))
    if($functionAsts.Count -eq 0){throw ('Missing MIRA function: '+$functionName)}
    # PowerShell executes the last definition in the file, so test that copy.
    $functionAst = $functionAsts[$functionAsts.Count - 1]
    Invoke-Expression $functionAst.Extent.Text
}

Assert-MiraTest ($script:MiraSettings.DefaultProvider -eq 'gemini') 'default provider changed unexpectedly'
Assert-MiraTest ($script:MiraSettings.DefaultModel -eq 'gemini-flash-lite-latest') 'default model changed unexpectedly'
Assert-MiraTest ($script:MiraSettings.UiRendering -eq $false) 'UI rendering must default off'
Assert-MiraTest ($script:MiraSettings.Streaming -eq $true) 'streaming must default on'
$configText = $source.Substring($configStart,$configEnd-$configStart)
foreach($match in [regex]::Matches($source,"'[A-Z0-9_]+_API_KEY'")){
    Assert-MiraTest ($configText.Contains($match.Value)) ('API-key environment name is hardcoded outside the settings block: '+$match.Value)
}
$googleStreamAst = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Send-GoogleStream'},$true)
Assert-MiraTest ($null -ne $googleStreamAst) 'Google SSE streaming function is missing'

$script:Providers = @(New-BuiltinProviders)
$antigravity = Get-Provider 'antigravity'
Assert-MiraTest ($null -ne $antigravity) 'Antigravity is missing from the provider registry'
Assert-MiraTest ($antigravity.type -eq 'antigravity') 'Antigravity has the wrong provider type'
Assert-MiraTest (@($antigravity.api_key_envs).Count -eq 0) 'Antigravity must not be configured as an API-key provider'

# Verify that multiple environment-variable names are tried in configured order.
$primaryName = 'MIRA_TEST_OPENAI_KEY_PRIMARY'
$secondaryName = 'MIRA_TEST_OPENAI_KEY_SECONDARY'
$oldPrimary = [Environment]::GetEnvironmentVariable($primaryName,[EnvironmentVariableTarget]::Process)
$oldSecondary = [Environment]::GetEnvironmentVariable($secondaryName,[EnvironmentVariableTarget]::Process)
try{
    $script:MiraSettings.ApiKeyEnvironmentVariables['openai'] = @($primaryName,$secondaryName)
    $script:Providers = @(New-BuiltinProviders)
    [Environment]::SetEnvironmentVariable($primaryName,'primary-test-value',[EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($secondaryName,'secondary-test-value',[EnvironmentVariableTarget]::Process)
    $openai = Get-Provider 'openai'
    Assert-MiraTest ((Get-ProviderKey $openai) -eq 'primary-test-value') 'the first configured API-key variable was not preferred'
    $refreshKey = Get-ProviderRefreshKey $openai
    Assert-MiraTest ($refreshKey.Name -eq $primaryName) 'model refresh did not report the selected API-key variable'
    [Environment]::SetEnvironmentVariable($primaryName,$null,[EnvironmentVariableTarget]::Process)
    Assert-MiraTest ((Get-ProviderKey $openai) -eq 'secondary-test-value') 'the second configured API-key variable was not used as a fallback'
}finally{
    [Environment]::SetEnvironmentVariable($primaryName,$oldPrimary,[EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($secondaryName,$oldSecondary,[EnvironmentVariableTarget]::Process)
}

# The Antigravity adapter must create its own envelope without mutating the
# ordinary Gemini payload shared by MIRA.
$geminiPayload = [ordered]@{
    systemInstruction = [ordered]@{parts=@([ordered]@{text='session summary'})}
    contents = @([ordered]@{role='user';parts=@([ordered]@{text='hello'})})
    safetySettings = @([ordered]@{category='HARM_CATEGORY_HATE_SPEECH';threshold='BLOCK_NONE'})
}
$envelope = New-MiraAntigravityEnvelope -Payload $geminiPayload -Model 'test-model' -Project 'test-project'
Assert-MiraTest ($envelope.project -eq 'test-project') 'Antigravity project was not included in the envelope'
Assert-MiraTest ($envelope.model -eq 'test-model') 'selected model was not included in the envelope'
Assert-MiraTest ($envelope.userAgent -eq 'antigravity' -and $envelope.requestType -eq 'agent') 'Antigravity envelope metadata is incomplete'
Assert-MiraTest ($envelope.requestId.StartsWith('agent-')) 'Antigravity request ID has the wrong prefix'
Assert-MiraTest ($null -eq $envelope.request.safetySettings) 'Gemini API safetySettings leaked into the Antigravity request'
Assert-MiraTest ($envelope.request.systemInstruction.role -eq 'user') 'Antigravity systemInstruction role was not normalized'
Assert-MiraTest ($null -eq $geminiPayload.systemInstruction.role) 'envelope normalization mutated MIRA original systemInstruction'
Assert-MiraTest ($null -ne $geminiPayload.safetySettings) 'envelope normalization mutated MIRA original safetySettings'
$payloadWithoutSummary = [ordered]@{contents=@([ordered]@{role='user';parts=@([ordered]@{text='hello'})})}
$defaultEnvelope = New-MiraAntigravityEnvelope -Payload $payloadWithoutSummary -Model 'test-model' -Project 'test-project'
Assert-MiraTest ($defaultEnvelope.request.systemInstruction.role -eq 'user') 'default Antigravity system instruction is missing'
Assert-MiraTest ($defaultEnvelope.request.systemInstruction.parts[0].text -eq $script:MiraSettings.AntigravityOAuth.SystemInstruction) 'default Antigravity system instruction does not match configuration'

$eventJson = '{"candidates":[{"content":{"parts":[{"text":"Hello"},{"text":" world"},{"text":"hidden thought","thought":true}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":2}}'
$event = ConvertFrom-MiraGoogleStreamEvent -EventJson $eventJson
Assert-MiraTest ($event.Text -eq 'Hello world') 'Google SSE parser did not assemble text parts or filtered thought text incorrectly'
Assert-MiraTest ($event.FinishReason -eq 'STOP') 'Google SSE parser did not read finishReason'
Assert-MiraTest ($event.PromptTokens -eq 11 -and $event.CompletionTokens -eq 2) 'Google SSE parser did not read usage metadata'

# Stub the three network/auth dependencies to test account model-catalog parsing
# without contacting Google or requiring user credentials.
function Get-MiraAntigravityAccessToken { return 'test-access-token' }
function Get-MiraAntigravityProject { return 'test-project' }
function Invoke-MiraAntigravityPost {
    param([string]$Method,[hashtable]$Body,[string]$AccessToken)
    return [pscustomobject]@{
        models = @(
            [pscustomobject]@{catalogId='models/zeta-test';displayName='Zeta Test'}
            [pscustomobject]@{modelId='models/alpha-test';displayName='Alpha Test'}
        )
    }
}
$catalogModels = @(Get-MiraAntigravityModels)
Assert-MiraTest ($catalogModels.Count -eq 2) 'Antigravity model catalog returned the wrong number of models'
Assert-MiraTest ($catalogModels[0].name -eq 'alpha-test' -and $catalogModels[1].name -eq 'zeta-test') 'Antigravity model IDs were not normalized and sorted'

$geminiResponse = [pscustomobject]@{
    usageMetadata = [pscustomobject]@{promptTokenCount=7;candidatesTokenCount=3}
    candidates = @(
        [pscustomobject]@{
            content = [pscustomobject]@{parts=@([pscustomobject]@{text='Antigravity reply'})}
            finishReason = 'STOP'
        }
    )
}
$parsed = Show-Response $geminiResponse 'antigravity'
Assert-MiraTest ($parsed.Text -eq 'Antigravity reply') 'Antigravity Gemini-compatible response text was not parsed'
Assert-MiraTest ($parsed.PromptTokens -eq 7 -and $parsed.CompletionTokens -eq 3) 'Antigravity usage metadata was not parsed'

Write-Host 'MIRA provider configuration and Antigravity adapter tests passed.' -ForegroundColor Green
