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
    'Read-GemLineFallback'
)

foreach ($functionName in $requiredFunctions) {
    $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Gemma component did not load expected function: $functionName"
    }
}

Write-Host 'Gemma components loaded successfully in Windows PowerShell 5.1.'
