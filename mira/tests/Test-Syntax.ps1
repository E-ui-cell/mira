$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$targets = New-Object System.Collections.Generic.List[string]
$mainScript = Join-Path $repoRoot 'mira.ps1'
if (Test-Path -LiteralPath $mainScript -PathType Leaf) { [void]$targets.Add($mainScript) }

$toolDirectory = Join-Path $repoRoot 'mira\tools'
if (Test-Path -LiteralPath $toolDirectory -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $toolDirectory -Filter '*.ps1' -File -ErrorAction Stop) {
        [void]$targets.Add($file.FullName)
    }
}
[void]$targets.Add($MyInvocation.MyCommand.Path)

$failed = $false
foreach ($path in $targets) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $failed = $true
        foreach ($parseError in $parseErrors) {
            Write-Host ('[PARSE ERROR] ' + $path + ':' + $parseError.Extent.StartLineNumber + ':' + $parseError.Extent.StartColumnNumber + ' ' + $parseError.Message) -ForegroundColor Red
        }
    } else {
        Write-Host ('[OK] ' + $path) -ForegroundColor Green
    }
}

if ($failed) { exit 1 }
Write-Host 'All MIRA PowerShell files parsed successfully.' -ForegroundColor Green
