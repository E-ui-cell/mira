#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\mira.ps1')
)

$resolved = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
$version = $PSVersionTable.PSVersion
$isWindowsPowerShell51 = ($version.Major -eq 5 -and $version.Minor -eq 1)
$isPowerShell7 = ($version.Major -ge 7)
if (-not ($isWindowsPowerShell51 -or $isPowerShell7)) {
    throw "This test supports Windows PowerShell 5.1 and PowerShell 7. Detected: $version"
}

if ($isWindowsPowerShell51 -and [IO.Path]::GetFileName($resolved) -ieq 'gemma.ps1') {
    $scriptBytes = [IO.File]::ReadAllBytes($resolved)
    if ($scriptBytes.Length -lt 3 -or $scriptBytes[0] -ne 0xEF -or $scriptBytes[1] -ne 0xBB -or $scriptBytes[2] -ne 0xBF) {
        throw 'gemma.ps1 must be saved as UTF-8 with BOM for Windows PowerShell 5.1.'
    }
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

Write-Host ("Syntax OK ({0}): {1}" -f $version, $resolved)
exit 0
