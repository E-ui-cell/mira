#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\mira.ps1')
)

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path

if ($PSVersionTable.PSVersion -ne [version]'5.1') {
    throw "This test requires Windows PowerShell 5.1. Detected: $($PSVersionTable.PSVersion)"
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors) | Out-Null

if ($errors.Count -gt 0) {
    foreach ($errorRecord in $errors) {
        Write-Error ("Syntax error at line {0}, column {1}: {2}" -f $errorRecord.Extent.StartLineNumber, $errorRecord.Extent.StartColumnNumber, $errorRecord.Message)
    }
    exit 1
}

Write-Host ("Syntax OK: {0}" -f $resolved)
exit 0
