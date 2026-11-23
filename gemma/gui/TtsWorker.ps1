#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][string]$UserText,
    [Parameter(Mandatory = $true)][string]$AssistantText,
    [switch]$ReplayOnly
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $RootPath 'config\Defaults.ps1')
    . (Join-Path $RootPath 'agent\Tts.ps1')
    $Contents = [System.Collections.ArrayList]::new()
    [void]$Contents.Add(@{ role = 'user'; parts = @(@{ text = $UserText }) })
    [void]$Contents.Add(@{ role = 'model'; parts = @(@{ text = $AssistantText }) })
    if ($ReplayOnly) {
        Invoke-GemmaReplayLatest -Contents $Contents
    } else {
        Invoke-GemmaSpeakLatest -Contents $Contents
    }
    Write-Output 'TTS task completed.'
} catch {
    Write-Output ("TTS error: " + $_.Exception.Message)
}
