function Invoke-GemmaPermissionCommand {
    param([ValidateSet('ask','autopilot')][string]$Mode)
    $script:ExecutionPermission = $Mode
    if ($Mode -eq 'ask') {
        Write-Host '[PowerShell permission mode: ASK | each command requires confirmation; Enter = Yes.]' -ForegroundColor Cyan
    } else {
        Write-Host '[PowerShell permission mode: AUTOPILOT | all model-requested PowerShell commands execute without confirmation.]' -ForegroundColor Yellow
    }
}

function Invoke-GemmaPowerShellTool {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'run_powershell requires a command.' }
    Write-Host "`n[PowerShell requested by model]:" -ForegroundColor DarkYellow
    Write-Host $Command -ForegroundColor Gray
    if ($script:ExecutionPermission -eq 'ask') {
        $approval = Read-Host 'Execute this PowerShell command? [Y/n]'
        if ($approval -match '^(?i:n|no)$') { return @{ approved=$false; output='User declined command execution.' } }
    }
    $previousProgressPreference = $ProgressPreference
    $previousInformationPreference = $InformationPreference
    $previousApprovedToolState = $script:InApprovedPowerShellTool
    try {
        $script:InApprovedPowerShellTool = $true
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'
        $output = Invoke-Expression $Command *>&1 | Out-String -Width $MIRA_POWERSHELL_OUTPUT_WIDTH
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) { $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + "`n[PowerShell output truncated]" }
        return @{ approved=$true; output=$output; current_location=(Get-Location).Path }
    } catch { return @{ approved=$true; error=$_.Exception.Message } }
    finally {
        $ProgressPreference = $previousProgressPreference
        $InformationPreference = $previousInformationPreference
        $script:InApprovedPowerShellTool = $previousApprovedToolState
    }
}


# ==============================================================================

function Invoke-GemmaQuickWeb {
    param([ValidateSet('weather','public-ip','cheatsheet')][string]$Action,[string]$Query = '')
    switch ($Action) {
        'weather' {
            $location = $Query.Trim()
            $url = if ($location) { 'https://wttr.in/' + [Uri]::EscapeDataString($location) + '?format=3' } else { 'https://wttr.in/?format=3' }
        }
        'public-ip' { $url = 'https://api.ipify.org' }
        'cheatsheet' {
            $topic = $Query.Trim().Trim('/')
            if (-not $topic) { $url = 'https://cht.sh/' }
            else {
                $encoded = (@($topic -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                $url = 'https://cht.sh/' + $encoded
            }
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        $result = & $curl.Source -fsS --max-time 15 --max-filesize 50000 $url 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "Quick web request failed (curl exit $exitCode): $([string]::Join(' ',@($result)))" }
        return [string]::Join([Environment]::NewLine,@($result))
    }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    return [string]$response.Content
}
