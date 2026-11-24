#requires -Version 5.1

$repoRoot = Split-Path -Parent $PSScriptRoot
$modules = @(
    (Join-Path $repoRoot 'gemma\config\Cli.ps1'),
    (Join-Path $repoRoot 'gemma\config\Defaults.ps1'),
    (Join-Path $repoRoot 'gemma\providers\GeminiApi.ps1'),
    (Join-Path $repoRoot 'gemma\providers\OpenAI.ps1'),
    (Join-Path $repoRoot 'gemma\providers\Antigravity.ps1'),
    (Join-Path $repoRoot 'gemma\ui\ModelPicker.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Execution.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Settings.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Skills.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Tools.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Conversation.ps1'),
    (Join-Path $repoRoot 'gemma\windows\Native.ps1'),
    (Join-Path $repoRoot 'gemma\ui\Output.ps1'),
    (Join-Path $repoRoot 'gemma\agent\ChatLoop.ps1'),
    (Join-Path $repoRoot 'gemma\ui\LineEditor.ps1')
)

foreach ($modulePath in $modules) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Missing Gemma component: $modulePath"
    }
    . $modulePath
}

$requiredFunctions = @(
    'Get-GeminiModels',
    'Get-GemmaCliArgs',
    'Initialize-GemmaCliMode',
    'Start-GemmaChatLoop',
    'Get-AntigravityModels',
    'Test-GemmaSearchIntent',
    'Invoke-GemmaAntigravityGoogleSearchPreflight',
    'Invoke-GemmaWebSearch',
    'Invoke-GemmaPermissionCommand',
    'Invoke-GemmaPowerShellTool',
    'Invoke-GemmaQuickWeb',
    'Get-GemmaSkill',
    'Get-GemmaToolConfiguration',
    'Invoke-GemmaToolCall',
    'Initialize-GemmaNativeWindows',
    'Confirm-GemmaDirectAction',
    'Invoke-GemmaDirectCommand',
    'Invoke-GemmaEffortCommand',
    'Invoke-GemmaStreamingCommand',
    'Invoke-GemmaProviderCommand',
    'Add-GemmaUsageRecord',
    'Invoke-GemmaUsageCommand',
    'Build-GeminiPayload',
    'Build-GemmaOpenAIResponsesPayload',
    'ConvertFrom-GemmaOpenAIResponsesResponse',
    'Format-GemmaOpenAIWebCitations',
    'Rollback-MiraTurn',
    'Save-GeminiCodeBlocks',
    'Normalize-MiraReply',
    'Read-GemmaModelSelection',
    'Invoke-GeminiModelSwitcher',
    'Read-GemLineConsole',
    'Read-GemLineFallback',
    'Add-GemUndoSnapshot',
    'Get-GemWordStart',
    'Get-GemWordEnd',
    'Find-GemHistoryMatch',
    'Get-GemHistorySearchPrompt'
)

if ($MIRA_DEFAULT_PROVIDER -notin @('antigravity','gemini')) {
    throw 'Gemma defaults did not initialize a supported provider.'
}
if ([string]::IsNullOrWhiteSpace($MIRA_DEFAULT_MODEL)) {
    throw 'Gemma defaults did not initialize the selected model.'
}

if ($script:StreamingMode -notin @('off','line','delta')) {
    throw 'Gemma defaults did not initialize a supported streaming mode.'
}

# Parse Turn.ps1 without executing the interactive request loop.
$turnPath = Join-Path $repoRoot 'gemma\agent\Turn.ps1'
$turnTokens = $null
$turnErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($turnPath, [ref]$turnTokens, [ref]$turnErrors) | Out-Null
if ($turnErrors.Count -gt 0) {
    $firstTurnError = $turnErrors[0]
    throw ("Turn.ps1 syntax error at line {0}, column {1}: {2}" -f $firstTurnError.Extent.StartLineNumber, $firstTurnError.Extent.StartColumnNumber, $firstTurnError.Message)
}

# Verify the line/delta/off streaming mode command changes runtime state.
$oldStreamingMode = $script:StreamingMode
try {
    Invoke-GemmaStreamingCommand -Argument 'delta'
    if ($script:StreamingMode -ne 'delta') { throw '.streaming delta did not update the active mode.' }
    Invoke-GemmaStreamingCommand -Argument 'line'
    if ($script:StreamingMode -ne 'line') { throw '.streaming line did not update the active mode.' }
    Invoke-GemmaStreamingCommand -Argument 'off'
    if ($script:StreamingMode -ne 'off') { throw '.streaming off did not disable streaming.' }
} finally {
    $script:StreamingMode = $oldStreamingMode
}

# Verify .usage accumulates provider-reported tokens and never needs a probe request.
$oldUsageStats = $script:MiraUsageStats
try {
    $script:MiraUsageStats = @{
        StartedAt = Get-Date
        Requests = 0
        SuccessfulRequests = 0
        FailedRequests = 0
        HttpAttempts = 0
        InputTokens = 0
        OutputTokens = 0
        ByProvider = @{}
        LastRequest = $null
        OpenAIRateLimits = @{}
    }
    Add-GemmaUsageRecord -Provider 'openai' -Model 'gpt-6-luna' -Succeeded $true -InputTokens 123 -OutputTokens 45 -HttpAttempts 2 -KeyIndex 1 -KeyCount 3 -KeySlotsTried @(2,3) -RateLimitHeaders @{ 'x-ratelimit-limit-tokens' = '100000'; 'x-ratelimit-remaining-tokens' = '50000'; 'x-ratelimit-reset-tokens' = '1m' } -RequestId 'req_usage_test' -HttpStatus 200
    if ($script:MiraUsageStats.Requests -ne 1 -or
        $script:MiraUsageStats.SuccessfulRequests -ne 1 -or
        $script:MiraUsageStats.InputTokens -ne 123 -or
        $script:MiraUsageStats.OutputTokens -ne 45 -or
        $script:MiraUsageStats.HttpAttempts -ne 2) {
        throw '.usage did not accumulate successful request and token totals.'
    }
    if ($script:MiraUsageStats.LastRequest.KeySlot -ne 2 -or
        $script:MiraUsageStats.LastRequest.KeyCount -ne 3 -or
        $script:MiraUsageStats.OpenAIRateLimits['x-ratelimit-remaining-tokens'] -ne '50000') {
        throw '.usage did not retain the used key slot or OpenAI rate-limit headers.'
    }
    Add-GemmaUsageRecord -Provider 'openai' -Model 'gpt-6-luna' -Succeeded $false -HttpAttempts 1 -KeyIndex 2 -KeyCount 3 -KeySlotsTried @(3) -HttpStatus 429 -ErrorMessage 'TPM limit'
    if ($script:MiraUsageStats.Requests -ne 2 -or
        $script:MiraUsageStats.FailedRequests -ne 1 -or
        $script:MiraUsageStats.ByProvider['openai'].FailedRequests -ne 1 -or
        $script:MiraUsageStats.LastRequest.ErrorMessage -ne 'TPM limit') {
        throw '.usage did not record a failed request.'
    }
} finally {
    $script:MiraUsageStats = $oldUsageStats
}

foreach ($functionName in $requiredFunctions) {
    $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Gemma component did not load expected function: $functionName"
    }
}

# Verify -p, -e and Explorer Run with PowerShell argument handling.
$normalPrompt = Initialize-GemmaCliMode -Prompt 'hello' -ExplainCommand '' -RemainingArgs @('--sample')
if ($script:OneShot -ne $true -or $script:CommandMode -ne $false -or $normalPrompt -ne 'hello') {
    throw 'Normal one-shot prompt mode was not initialized correctly.'
}
if ($script:RemainingCliArgs.Count -ne 1 -or $script:RemainingCliArgs[0] -ne '--sample') {
    throw 'Remaining CLI arguments were not preserved.'
}
$commandPrompt = Initialize-GemmaCliMode -Prompt '' -ExplainCommand 'Get-ChildItem' -RemainingArgs @()
if ($script:OneShot -ne $true -or $script:CommandMode -ne $true -or $commandPrompt -ne 'Get-ChildItem') {
    throw 'Command-generation mode was not initialized correctly.'
}
$wrappedArgs = @('-Command','if((Get-ExecutionPolicy) -ne AllSigned) { Set-ExecutionPolicy -Scope Process Bypass }','-File','gemma.ps1')
$cleanArgs = @(Get-GemmaCliArgs -RawArgs $wrappedArgs)
if ($cleanArgs.Count -ne 2 -or $cleanArgs[0] -ne '-File' -or $cleanArgs[1] -ne 'gemma.ps1') {
    throw 'Explorer Run with PowerShell argument wrapper was not stripped correctly.'
}

# Verify the explicit Gemini API-key candidate list used by Defaults.ps1.
$defaultsPath = Join-Path $repoRoot 'gemma\config\Defaults.ps1'
$oldGeminiApiKey = $env:GEMINI_API_KEY
$oldGeminiApiJ = $env:GEMINI_APIJ
try {
    $env:GEMINI_API_KEY = 'primary-test-key'
    $env:GEMINI_APIJ = 'secondary-test-key'
    . $defaultsPath
    $geminiCandidates = @($script:GeminiApiKeys)
    if ($geminiCandidates.Count -ne 2 -or
        $geminiCandidates[0] -ne 'primary-test-key' -or
        $geminiCandidates[1] -ne 'secondary-test-key') {
        throw 'Gemini API key candidates were not loaded in the configured order.'
    }

    $env:GEMINI_API_KEY = ''
    . $defaultsPath
    $geminiCandidates = @($script:GeminiApiKeys)
    if ($geminiCandidates.Count -ne 1 -or $geminiCandidates[0] -ne 'secondary-test-key') {
        throw 'Gemini API key candidate filtering did not preserve the remaining key.'
    }
} finally {
    $env:GEMINI_API_KEY = $oldGeminiApiKey
    $env:GEMINI_APIJ = $oldGeminiApiJ
    . $defaultsPath
}

# Verify the shared agent tool registry respects provider and command mode.
$oldProvider = $script:Provider
$oldCommandMode = $script:CommandMode
$oldGrounding = $script:GoogleSearchGrounding
$oldAgenticSearch = $script:AgenticWebSearchEnabled
try {
    $script:CommandMode = $false
    $script:Provider = 'antigravity'
    $script:GoogleSearchGrounding = $true
    $script:AgenticWebSearchEnabled = $true
    $toolSet = Get-GemmaToolConfiguration
    $toolNames = @($toolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($toolNames -contains 'web_search') {
        throw 'Antigravity tools must not expose Gemini API web_search.'
    }
    foreach ($requiredTool in @('get_current_datetime','run_powershell','quick_web','get_skill')) {
        if ($toolNames -notcontains $requiredTool) {
            throw "Shared tool registry omitted $requiredTool."
        }
    }

    $dateResult = Invoke-GemmaToolCall -Call @{ name = 'get_current_datetime'; args = @{} }
    if ([string]::IsNullOrWhiteSpace([string]$dateResult.iso8601) -or
        [string]::IsNullOrWhiteSpace([string]$dateResult.timezone_id)) {
        throw 'Local date/time tool returned incomplete data.'
    }

    $unknownResult = Invoke-GemmaToolCall -Call @{ name = 'not_a_real_tool'; args = @{} }
    if (-not $unknownResult.error) {
        throw 'Unknown tool dispatch must return a structured error.'
    }

    $script:CommandMode = $true
    $commandToolSet = Get-GemmaToolConfiguration
    if ($null -ne $commandToolSet.Tools -or $null -ne $commandToolSet.ToolConfig) {
        throw 'Command-generation mode must disable local tool declarations.'
    }
} finally {
    $script:Provider = $oldProvider
    $script:CommandMode = $oldCommandMode
    $script:GoogleSearchGrounding = $oldGrounding
    $script:AgenticWebSearchEnabled = $oldAgenticSearch
}

# Verify Luna receives OpenAI-hosted web_search beside GEMMA's local functions.
$oldOpenAIModel = $script:MODEL
$oldOpenAIProvider = $script:Provider
$oldOpenAICommandMode = $script:CommandMode
$oldGeminiTools = $GeminiTools
try {
    $script:Provider = 'openai'
    $script:MODEL = 'gpt-6-luna'
    $script:CommandMode = $false
    $GeminiTools = (Get-GemmaToolConfiguration).Tools

    $lunaPayload = Build-GemmaOpenAIResponsesPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    $nativeSearchTools = @($lunaPayload.tools | Where-Object { $_.type -eq 'web_search' })
    if ($nativeSearchTools.Count -ne 1) {
        throw 'Luna Responses payload must include exactly one native web_search tool.'
    }
    if ($nativeSearchTools[0].search_context_size -ne 'medium' -or
        $nativeSearchTools[0].external_web_access -ne $true -or
        $nativeSearchTools[0].user_location.type -ne 'approximate') {
        throw 'Luna native web_search defaults were not configured correctly.'
    }
    if ($lunaPayload.tool_choice -ne 'auto') {
        throw 'Luna native web_search must use automatic tool selection.'
    }
    if ($lunaPayload.instructions -notmatch '(?i)native web_search tool') {
        throw 'Luna system instructions must direct current-information requests to native web_search.'
    }
    $localToolNames = @($lunaPayload.tools | Where-Object { $_.type -eq 'function' } | ForEach-Object { $_.name })
    foreach ($localTool in @('get_current_datetime','run_powershell','quick_web','get_skill')) {
        if ($localToolNames -notcontains $localTool) {
            throw "Adding native web_search removed Luna's local $localTool function."
        }
    }

    $chatPayload = Build-GemmaOpenAIChatPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    if (@($chatPayload.tools | Where-Object { $_.type -eq 'web_search' }).Count -gt 0) {
        throw 'Native Responses web_search must not leak into Chat Completions requests.'
    }

    $script:CommandMode = $true
    $GeminiTools = $null
    $commandPayload = Build-GemmaOpenAIResponsesPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    if ($null -ne $commandPayload.tools -or $null -ne $commandPayload.tool_choice) {
        throw 'Luna command-generation mode must keep hosted and local tools disabled.'
    }

    $fixtureResponse = [pscustomobject]@{
        error = $null
        status = 'completed'
        id = 'resp_test'
        model = 'gpt-6-luna'
        usage = [pscustomobject]@{ input_tokens = 20; output_tokens = 8 }
        output = @(
            [pscustomobject]@{
                type = 'message'
                content = @(
                    [pscustomobject]@{
                        type = 'output_text'
                        text = 'Example answer [1]'
                        annotations = @(
                            [pscustomobject]@{
                                type = 'url_citation'
                                url = 'https://example.com/article'
                                title = 'Example Article'
                                start_index = 15
                                end_index = 18
                            },
                            [pscustomobject]@{
                                type = 'url_citation'
                                url = 'https://example.com/article'
                                title = 'Example Article'
                                start_index = 15
                                end_index = 18
                            }
                        )
                    }
                )
            }
        )
    }
    $convertedResponse = ConvertFrom-GemmaOpenAIResponsesResponse -OpenAIResponse $fixtureResponse
    if (@($convertedResponse.webCitations).Count -ne 1) {
        throw 'Luna Responses converter did not deduplicate and retain URL citations.'
    }
    if ($convertedResponse.candidates[0].content.parts[0].text -ne 'Example answer [1]') {
        throw 'Luna Responses converter changed the model answer while extracting citations.'
    }
    $formattedSources = Format-GemmaOpenAIWebCitations -Citations @($convertedResponse.webCitations)
    if ($formattedSources -notmatch 'Example Article' -or
        $formattedSources -notmatch 'https://example.com/article') {
        throw 'Luna web citations were not formatted as visible source links.'
    }
} finally {
    $script:MODEL = $oldOpenAIModel
    $script:Provider = $oldOpenAIProvider
    $script:CommandMode = $oldOpenAICommandMode
    $GeminiTools = $oldGeminiTools
}

# Keep Antigravity native Search conditional on the current user request.
$searchCases = @(
    @{ Request = 'test'; Expected = $false },
    @{ Request = 'll'; Expected = $false },
    @{ Request = 'ok'; Expected = $false },
    @{ Request = 'what?'; Expected = $false },
    @{ Request = 'search latest hour news for kyiv'; Expected = $true },
    @{ Request = 'search news, show dates and sources for each news'; Expected = $true },
    @{ Request = 'show latest lviv news in last hours'; Expected = $true },
    @{ Request = 'why you searching again? talk like engineer, what made you continue searching data'; Expected = $false },
    @{ Request = '.grounding off'; Expected = $false },
    @{ Request = "tell me today's date"; Expected = $false },
    @{ Request = 'show weather in Lviv'; Expected = $false },
    @{ Request = 'search weather in Lviv'; Expected = $true }
)
foreach ($case in $searchCases) {
    $actual = [bool](Test-GemmaSearchIntent -Text $case.Request)
    if ($actual -ne [bool]$case.Expected) {
        throw "Search-intent classifier mismatch for '$($case.Request)': expected $($case.Expected), got $actual."
    }
}

# Verify common cursor-word calculations independently of terminal interaction.
if ((Get-GemWordStart -Text 'one two' -Position 7) -ne 4) {
    throw 'Readline backward-word calculation failed.'
}
if ((Get-GemWordEnd -Text 'one two' -Position 4) -ne 7) {
    throw 'Readline forward-word calculation failed.'
}

# Verify reverse/forward substring history search against a deterministic history.
$script:MiraInputHistory = New-Object 'System.Collections.Generic.List[string]'
[void]$script:MiraInputHistory.Add('open notes.txt')
[void]$script:MiraInputHistory.Add('get process list')
[void]$script:MiraInputHistory.Add('open report.txt')
if ((Find-GemHistoryMatch -Term 'open' -Start 3 -Direction -1) -ne 2) {
    throw 'Readline reverse history search failed.'
}
if ((Find-GemHistoryMatch -Term 'open' -Start 0 -Direction 1) -ne 2) {
    throw 'Readline forward history search failed.'
}
$searchPrompt = Get-GemHistorySearchPrompt -Direction -1 -Term 'a long search query that should be clipped' -Width 30
if ($searchPrompt.Length -gt 30) {
    throw 'Readline history-search prompt exceeded the terminal width.'
}

Write-Host 'Gemma components and Readline helpers loaded successfully in Windows PowerShell 5.1.'
