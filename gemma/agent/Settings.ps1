function Invoke-GemmaEffortCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) {
        Write-Host "[Effort: $script:Effort]" -ForegroundColor Cyan
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor DarkGray
        return
    }
    if ($value -notin @('low','medium','high')) {
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor Yellow
        return
    }
    $script:Effort = $value
    Write-Host "[Reasoning effort set to: $script:Effort]" -ForegroundColor Green
}

function Invoke-GemmaProviderCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) { Write-Host "[Provider: $script:Provider | Model: $script:MODEL]" -ForegroundColor Cyan; Write-Host 'Usage: .provider antigravity | .provider gemini' -ForegroundColor DarkGray; return }
    if ($value -notin @('antigravity','gemini')) { Write-Host 'Usage: .provider antigravity | .provider gemini' -ForegroundColor Yellow; return }
    if ($value -eq 'antigravity' -and -not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) { Write-Host '[Antigravity is not authenticated. Run .auth login first.]' -ForegroundColor Yellow; return }
    if ($value -eq 'gemini' -and [string]::IsNullOrWhiteSpace($API_KEY)) { Write-Host '[Gemini API key is not set. Set GEMINI_APIJ before switching.]' -ForegroundColor Yellow; return }
    $script:Provider = $value
    Write-Host "[Provider switched to: $script:Provider]" -ForegroundColor Green
    Write-Host '[Model name retained; use .model to select from this provider catalogue.]' -ForegroundColor DarkGray
    Write-Host "[Reasoning effort: $script:Effort | use .effort low/medium/high to change.]" -ForegroundColor DarkGray
}
