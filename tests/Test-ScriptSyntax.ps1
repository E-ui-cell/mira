#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\mira.ps1')
)

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "This test requires Windows PowerShell 5.1. Detected: $($PSVersionTable.PSVersion)"
}

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
if (Test-Path -LiteralPath $resolved -PathType Container) {
    $scripts = @(Get-ChildItem -LiteralPath $resolved -Filter '*.ps1' -File -Recurse | Sort-Object FullName)
} else {
    $scripts = @(Get-Item -LiteralPath $resolved -ErrorAction Stop)
}

if ($scripts.Count -eq 0) {
    throw "No PowerShell scripts found at: $resolved"
}

$failed = $false
foreach ($scriptFile in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $failed = $true
        foreach ($errorRecord in $errors) {
            Write-Error ("Syntax error in {0} at line {1}, column {2}: {3}" -f $scriptFile.FullName, $errorRecord.Extent.StartLineNumber, $errorRecord.Extent.StartColumnNumber, $errorRecord.Message)
        }
    } else {
        Write-Host ("Syntax OK: {0}" -f $scriptFile.FullName)
    }
}

if ($failed) { exit 1 }
exit 0
