#requires -Version 5.1

$repoRoot = Split-Path -Parent $PSScriptRoot
$modules = @(
    (Join-Path $repoRoot 'gemma\config\Cli.ps1'),
    (Join-Path $repoRoot 'gemma\config\Defaults.ps1'),
    (Join-Path $repoRoot 'gemma\providers\GeminiApi.ps1'),
    (Join-Path $repoRoot 'gemma\providers\Antigravity.ps1'),
    (Join-Path $repoRoot 'gemma\ui\ModelPicker.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Execution.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Settings.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Skills.ps1'),
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
    'Initialize-GemmaNativeWindows',
    'Confirm-GemmaDirectAction',
    'Invoke-GemmaDirectCommand',
    'Invoke-GemmaEffortCommand',
    'Invoke-GemmaProviderCommand',
    'Build-GeminiPayload',
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

# Verify canonical and migration API-key environment variables.
$defaultsPath = Join-Path $repoRoot 'gemma\config\Defaults.ps1'
$oldGeminiApi = $env:GEMINI_API
$oldGeminiApiKey = $env:GEMINI_API_KEY
$oldGeminiApiJ = $env:GEMINI_APIJ
try {
    $env:GEMINI_API = 'canonical-test-key'
    $env:GEMINI_API_KEY = 'standard-test-key'
    $env:GEMINI_APIJ = 'legacy-test-key'
    . $defaultsPath
    if ($API_KEY -ne 'canonical-test-key') {
        throw 'GEMINI_API must take precedence for API key selection.'
    }

    $env:GEMINI_API = ''
    . $defaultsPath
    if ($API_KEY -ne 'standard-test-key') {
        throw 'GEMINI_API_KEY compatibility alias did not load.'
    }

    $env:GEMINI_API_KEY = ''
    . $defaultsPath
    if ($API_KEY -ne 'legacy-test-key') {
        throw 'GEMINI_APIJ legacy compatibility alias did not load.'
    }
} finally {
    $env:GEMINI_API = $oldGeminiApi
    $env:GEMINI_API_KEY = $oldGeminiApiKey
    $env:GEMINI_APIJ = $oldGeminiApiJ
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
