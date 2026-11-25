function Invoke-GemmaOneShotCommand {
    param([string]$Argument = '',[System.Collections.ArrayList]$Contents)

    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) {
        Write-Host ("[One-shot session mode: {0}]" -f $(if ($script:NoSession) { 'ON' } else { 'OFF' })) -ForegroundColor Cyan
        Write-Host 'Usage: .oneshot on | .oneshot off' -ForegroundColor DarkGray
        return
    }
    if ($value -notin @('on','off')) {
        Write-Host 'Usage: .oneshot on | .oneshot off' -ForegroundColor Yellow
        return
    }

    $script:NoSession = ($value -eq 'on')
    if ($script:NoSession -and $null -ne $Contents) { $Contents.Clear() }
    Write-Host ("[One-shot session mode: {0}]" -f $(if ($script:NoSession) { 'ON' } else { 'OFF' })) -ForegroundColor $(if ($script:NoSession) { 'Green' } else { 'Yellow' })
}

function Invoke-GemmaStreamingCommand {
    param([string]$Argument = '')

    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) {
        Write-Host "[Response streaming: $($script:StreamingMode.ToUpperInvariant())]" -ForegroundColor Cyan
        Write-Host 'Usage: .streaming line | .streaming delta | .streaming off' -ForegroundColor DarkGray
        return
    }
    if ($value -notin @('line','delta','off')) {
        Write-Host 'Usage: .streaming line | .streaming delta | .streaming off' -ForegroundColor Yellow
        return
    }

    $script:StreamingMode = $value
    $color = if ($value -eq 'off') { 'Yellow' } else { 'Green' }
    Write-Host "[Response streaming set to: $($value.ToUpperInvariant())]" -ForegroundColor $color
}

function Invoke-GemmaEffortCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) {
        $activeEffort = Get-GemmaEffortStatusText -Provider $script:Provider -Model $script:MODEL
        Write-Host "[Shared effort: $script:Effort]" -ForegroundColor Cyan
        Write-Host "[Active request: $activeEffort]" -ForegroundColor DarkGray
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor DarkGray
        return
    }
    if ($value -notin @('low','medium','high')) {
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor Yellow
        return
    }
    $script:Effort = $value
    $activeEffort = Get-GemmaEffortStatusText -Provider $script:Provider -Model $script:MODEL
    Write-Host "[Shared effort set to: $script:Effort | active request: $activeEffort]" -ForegroundColor Green
}

function Invoke-GemmaSystemPromptCommand {
    param([string]$Argument = '')

    $value = $Argument.Trim()
    $available = @('default')
    if (Test-Path -LiteralPath $script:GemmaPromptDirectory -PathType Container) {
        $available += @(
            Get-ChildItem -LiteralPath $script:GemmaPromptDirectory -Filter '*.md' -File |
                ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } |
                Sort-Object
        )
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host ("[System prompt: {0}]" -f $script:ActiveSystemPromptName) -ForegroundColor Cyan
        Write-Host ("Available presets: " + ($available -join ', ')) -ForegroundColor DarkGray
        Write-Host 'Usage: .sysprompt <name> | .sysprompt default' -ForegroundColor DarkGray
        return
    }

    if ($value -ieq 'default') {
        $SystemInstruction.parts[0].text = Get-GemmaSystemPromptText -BasePrompt $MIRA_DEFAULT_SYSTEM_PROMPT
        $script:ActiveSystemPromptName = 'default'
        Write-Host '[System prompt reset to default.]' -ForegroundColor Green
        return
    }

    if ($value -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Host 'Invalid preset name. Use .sysprompt to list available presets.' -ForegroundColor Yellow
        return
    }

    $promptPath = Join-Path $script:GemmaPromptDirectory ($value + '.md')
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        Write-Host ("Unknown system prompt '{0}'. Available: {1}" -f $value,($available -join ', ')) -ForegroundColor Yellow
        return
    }

    try {
        $promptText = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($promptText)) {
            Write-Host ("System prompt '{0}' is empty; active prompt unchanged." -f $value) -ForegroundColor Yellow
            return
        }
        $SystemInstruction.parts[0].text = Get-GemmaSystemPromptText -BasePrompt ($promptText.Trim())
        $script:ActiveSystemPromptName = [System.IO.Path]::GetFileNameWithoutExtension($promptPath)
        Write-Host ("[System prompt switched to: {0}]" -f $script:ActiveSystemPromptName) -ForegroundColor Green
    } catch {
        Write-Host ("[Could not load system prompt: {0}]" -f $_.Exception.Message) -ForegroundColor Red
    }
}


function Add-GemmaUsageRecord {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('openai','gemini','antigravity')][string]$Provider,
        [Parameter(Mandatory=$true)][string]$Model,
        [bool]$Succeeded = $true,
        [int]$InputTokens = 0,
        [int]$OutputTokens = 0,
        [int]$HttpAttempts = 0,
        [int]$KeyIndex = -1,
        [int]$KeyCount = 0,
        [int[]]$KeySlotsTried = @(),
        [hashtable]$RateLimitHeaders = $null,
        [string]$RequestId = '',
        [int]$HttpStatus = 0,
        [string]$ErrorCode = '',
        [string]$ErrorMessage = ''
    )

    if ($null -eq $script:MiraUsageStats) {
        $script:MiraUsageStats = @{
            StartedAt = Get-Date
            Requests = 0
            SuccessfulRequests = 0
            FailedRequests = 0
            HttpAttempts = 0
            InputTokens = 0
            OutputTokens = 0
            ByProvider = @{}
            LastRequest = $null
            ProviderRateLimits = @{}
            OpenAIRateLimits = @{}
        }
    }

    $stats = $script:MiraUsageStats
    if ($null -eq $stats.ProviderRateLimits) {
        $stats.ProviderRateLimits = @{}
        if ($null -ne $stats.OpenAIRateLimits -and $stats.OpenAIRateLimits.Count -gt 0) {
            $stats.ProviderRateLimits['openai'] = $stats.OpenAIRateLimits
        }
    }

    $inputCount = [Math]::Max(0,$InputTokens)
    $outputCount = [Math]::Max(0,$OutputTokens)
    $attemptCount = [Math]::Max(0,$HttpAttempts)
    $providerName = $Provider.ToLowerInvariant()

    $stats.Requests = [int]$stats.Requests + 1
    $stats.HttpAttempts = [int]$stats.HttpAttempts + $attemptCount
    $stats.InputTokens = [int64]$stats.InputTokens + $inputCount
    $stats.OutputTokens = [int64]$stats.OutputTokens + $outputCount
    if ($Succeeded) {
        $stats.SuccessfulRequests = [int]$stats.SuccessfulRequests + 1
    } else {
        $stats.FailedRequests = [int]$stats.FailedRequests + 1
    }

    if (-not $stats.ByProvider.ContainsKey($providerName)) {
        $stats.ByProvider[$providerName] = @{
            Requests = 0
            SuccessfulRequests = 0
            FailedRequests = 0
            InputTokens = 0
            OutputTokens = 0
        }
    }
    $providerStats = $stats.ByProvider[$providerName]
    $providerStats.Requests = [int]$providerStats.Requests + 1
    $providerStats.InputTokens = [int64]$providerStats.InputTokens + $inputCount
    $providerStats.OutputTokens = [int64]$providerStats.OutputTokens + $outputCount
    if ($Succeeded) {
        $providerStats.SuccessfulRequests = [int]$providerStats.SuccessfulRequests + 1
    } else {
        $providerStats.FailedRequests = [int]$providerStats.FailedRequests + 1
    }

    $keySlot = $null
    if ($KeyIndex -ge 0) { $keySlot = $KeyIndex + 1 }
    $stats.LastRequest = [pscustomobject]@{
        At = Get-Date
        Provider = $providerName
        Model = $Model
        Status = if ($Succeeded) { 'completed' } else { 'failed' }
        InputTokens = $inputCount
        OutputTokens = $outputCount
        HttpAttempts = $attemptCount
        KeySlot = $keySlot
        KeyCount = [Math]::Max(0,$KeyCount)
        KeySlotsTried = @($KeySlotsTried)
        HttpStatus = $HttpStatus
        RequestId = $RequestId
        ErrorCode = $ErrorCode
        ErrorMessage = $ErrorMessage
    }

    if ($null -ne $RateLimitHeaders -and $RateLimitHeaders.Count -gt 0) {
        $rateSnapshot = @{}
        foreach ($headerName in $RateLimitHeaders.Keys) {
            $rateSnapshot[[string]$headerName] = [string]$RateLimitHeaders[$headerName]
        }
        $stats.ProviderRateLimits[$providerName] = $rateSnapshot
        # Keep the old field as a compatibility alias for existing diagnostics.
        if ($providerName -eq 'openai') { $stats.OpenAIRateLimits = $rateSnapshot }
    }
}

function Invoke-GemmaUsageCommand {
    $stats = $script:MiraUsageStats
    if ($null -eq $stats) {
        $stats = @{
            StartedAt = Get-Date
            Requests = 0
            SuccessfulRequests = 0
            FailedRequests = 0
            HttpAttempts = 0
            InputTokens = 0
            OutputTokens = 0
            ByProvider = @{}
            LastRequest = $null
            ProviderRateLimits = @{}
            OpenAIRateLimits = @{}
        }
    }
    if ($null -eq $stats.ProviderRateLimits) {
        $stats.ProviderRateLimits = @{}
        if ($null -ne $stats.OpenAIRateLimits -and $stats.OpenAIRateLimits.Count -gt 0) {
            $stats.ProviderRateLimits['openai'] = $stats.OpenAIRateLimits
        }
    }

    $activeProvider = ([string]$script:Provider).Trim().ToLowerInvariant()
    $activeModel = [string]$script:MODEL
    $providerLabel = switch ($activeProvider) {
        'openai' { 'OpenAI' }
        'gemini' { 'Google AI Studio API' }
        'antigravity' { 'Antigravity' }
        default { if ($activeProvider) { $activeProvider } else { 'Unknown provider' } }
    }

    $totalTokens = [int64]$stats.InputTokens + [int64]$stats.OutputTokens
    $startedAt = [DateTime]$stats.StartedAt
    Write-Host ''
    Write-Host ("Session usage since {0}" -f $startedAt.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ("Active model: {0} | {1}" -f $providerLabel,$activeModel) -ForegroundColor Cyan
    Write-Host ("Requests: {0} total | {1} completed | {2} failed | {3} HTTP attempts" -f
        $stats.Requests,$stats.SuccessfulRequests,$stats.FailedRequests,$stats.HttpAttempts) -ForegroundColor Gray
    Write-Host ("Tokens: {0:N0} input | {1:N0} output | {2:N0} total" -f
        $stats.InputTokens,$stats.OutputTokens,$totalTokens) -ForegroundColor Gray

    if ($stats.ByProvider.Count -gt 0) {
        Write-Host 'By provider:' -ForegroundColor DarkGray
        foreach ($providerName in @($stats.ByProvider.Keys | Sort-Object)) {
            $providerStats = $stats.ByProvider[$providerName]
            $providerTotal = [int64]$providerStats.InputTokens + [int64]$providerStats.OutputTokens
            Write-Host ("  {0}: {1} requests ({2} failed) | {3:N0} in / {4:N0} out / {5:N0} total" -f
                $providerName,$providerStats.Requests,$providerStats.FailedRequests,
                $providerStats.InputTokens,$providerStats.OutputTokens,$providerTotal) -ForegroundColor Gray
        }
    }

    if ($null -ne $stats.LastRequest) {
        $last = $stats.LastRequest
        $keyText = ''
        if ($last.Provider -in @('openai','gemini') -and $last.KeyCount -gt 0) {
            $triedText = ''
            if (@($last.KeySlotsTried).Count -gt 0) {
                $triedText = ' (tried ' + ((@($last.KeySlotsTried) | ForEach-Object { [string]$_ }) -join ',') + ')'
            }
            $keyText = " | key slot $($last.KeySlot)/$($last.KeyCount)$triedText"
        }
        Write-Host ("Last request: {0}/{1} | {2} | {3} | HTTP {4} | {5} attempts{6}" -f
            $last.Provider,$last.Model,$last.Status,$last.At.ToString('HH:mm:ss'),
            $last.HttpStatus,$last.HttpAttempts,$keyText) -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace([string]$last.RequestId)) {
            Write-Host ("Request ID: {0}" -f $last.RequestId) -ForegroundColor DarkGray
        }
        if ($last.Status -eq 'failed' -and (-not [string]::IsNullOrWhiteSpace([string]$last.ErrorCode) -or -not [string]::IsNullOrWhiteSpace([string]$last.ErrorMessage))) {
            $failureText = [string]$last.ErrorMessage
            if ($failureText.Length -gt 240) { $failureText = $failureText.Substring(0,237) + '...' }
            if (-not [string]::IsNullOrWhiteSpace([string]$last.ErrorCode)) {
                Write-Host ("Failure [{0}]: {1}" -f $last.ErrorCode,$failureText) -ForegroundColor Yellow
            } else {
                Write-Host ("Failure: {0}" -f $failureText) -ForegroundColor Yellow
            }
        }
        Write-Host ("Last request tokens: {0:N0} input | {1:N0} output" -f $last.InputTokens,$last.OutputTokens) -ForegroundColor DarkGray
    } else {
        Write-Host 'No provider requests recorded in this session yet.' -ForegroundColor DarkGray
    }

    switch ($activeProvider) {
        'openai' {
            $activeKeys = @(Get-GemmaOpenAIApiKeys)
            $nextKeyIndex = 0
            if ($null -ne $script:MiraOpenAIApiKeyIndex -and $activeKeys.Count -gt 0) {
                $nextKeyIndex = [int]$script:MiraOpenAIApiKeyIndex % $activeKeys.Count
            }
            if ($activeKeys.Count -gt 0) {
                Write-Host ("OpenAI key candidates: {0} configured | next slot {1}/{2}" -f
                    $activeKeys.Count,($nextKeyIndex + 1),$activeKeys.Count) -ForegroundColor DarkGray
            } else {
                Write-Host 'OpenAI key candidates: none configured.' -ForegroundColor DarkGray
            }
        }
        'gemini' {
            $activeKeys = @(Get-GeminiApiKeys)
            $nextKeyIndex = 0
            if ($null -ne $script:MiraGeminiApiKeyIndex -and $activeKeys.Count -gt 0) {
                $nextKeyIndex = [int]$script:MiraGeminiApiKeyIndex % $activeKeys.Count
            }
            if ($activeKeys.Count -gt 0) {
                Write-Host ("Google AI Studio API key candidates: {0} configured | next slot {1}/{2}" -f
                    $activeKeys.Count,($nextKeyIndex + 1),$activeKeys.Count) -ForegroundColor DarkGray
            } else {
                Write-Host 'Google AI Studio API key candidates: none configured.' -ForegroundColor DarkGray
            }
        }
        'antigravity' {
            try {
                $tokenPath = Get-AntigravityTokenPath
                if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
                    Write-Host 'Antigravity OAuth: saved token file found (validity not checked; no refresh or probe).' -ForegroundColor DarkGray
                } else {
                    Write-Host 'Antigravity OAuth: not signed in (no saved token file).' -ForegroundColor Yellow
                }
            } catch {
                Write-Host 'Antigravity OAuth: could not inspect local token status.' -ForegroundColor Yellow
            }
        }
        default {
            Write-Host ("No credential diagnostics are defined for provider '{0}'." -f $activeProvider) -ForegroundColor DarkGray
        }
    }

    $limits = @{}
    if ($null -ne $stats.ProviderRateLimits -and $stats.ProviderRateLimits.ContainsKey($activeProvider)) {
        $limits = $stats.ProviderRateLimits[$activeProvider]
    } elseif ($activeProvider -eq 'openai' -and $null -ne $stats.OpenAIRateLimits) {
        $limits = $stats.OpenAIRateLimits
    }
    if ($null -ne $limits -and $limits.Count -gt 0) {
        Write-Host ("Last observed {0} rate-limit/response headers:" -f $providerLabel) -ForegroundColor DarkGray
        foreach ($headerName in @($limits.Keys | Sort-Object)) {
            Write-Host ("  {0}: {1}" -f $headerName,$limits[$headerName]) -ForegroundColor Gray
        }
    } else {
        Write-Host ("{0} rate-limit headers: not observed yet (no probe request is sent)." -f $providerLabel) -ForegroundColor DarkGray
    }

    Write-Host 'Chat/model calls only. Token totals use provider-reported usage; rate-limit headers appear only when returned. .usage sends no API request.' -ForegroundColor DarkGray
}
