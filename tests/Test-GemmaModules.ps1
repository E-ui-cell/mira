#requires -Version 5.1

$repoRoot = Split-Path -Parent $PSScriptRoot
$modules = @(
    (Join-Path $repoRoot 'gemma\providers\GeminiApi.ps1'),
    (Join-Path $repoRoot 'gemma\providers\Antigravity.ps1'),
    (Join-Path $repoRoot 'gemma\ui\ModelPicker.ps1'),
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
    'Get-AntigravityModels',
    'Invoke-GemmaAntigravityGoogleSearchPreflight',
    'Invoke-GemmaWebSearch',
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

foreach ($functionName in $requiredFunctions) {
    $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Gemma component did not load expected function: $functionName"
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
