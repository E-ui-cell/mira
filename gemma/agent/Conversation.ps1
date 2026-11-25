function Get-GemmaEffectiveEffort {
    param([ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider)

    $override = switch ($Provider) {
        'openai' { $MIRA_OPENAI_EFFORT }
        'gemini' { $MIRA_GEMINI_EFFORT }
        'antigravity' { $MIRA_ANTIGRAVITY_EFFORT }
    }
    $value = if ([string]::IsNullOrWhiteSpace([string]$override)) { [string]$script:Effort } else { [string]$override }
    $value = $value.Trim().ToLowerInvariant()

    $allowed = if ($Provider -eq 'openai') { @('none','minimal','low','medium','high','xhigh','max') } else { @('low','medium','high') }
    if ($value -notin $allowed) {
        throw "Invalid $Provider reasoning effort '$value'. Allowed values: $($allowed -join ', ')."
    }
    return $value
}

function Get-GemmaRequestEffort {
    param([ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider)

    $value = Get-GemmaEffectiveEffort -Provider $Provider
    # GPT-6 Luna Chat Completions can use function calling only at effort=none.
    # Use Responses API to remove this restriction while retaining tools.
    if ($Provider -eq 'openai' -and @(ConvertTo-GemmaOpenAITools -GeminiTools $GeminiTools).Count -gt 0) {
        return 'none'
    }
    return $value
}

function Build-GeminiPayload {
    param(
        [object]$SystemInstruction,
        [object]$Contents
    )

    # OpenAI Responses history can carry provider-only fields such as
    # openaiOutputItems. Gemini Content accepts only role/parts at this level.
    # Project each turn into the Gemini schema without mutating the shared
    # history: the original OpenAI items are still needed if the user switches
    # back to GPT-6 Luna later.
    $geminiContents = @(
        foreach ($turn in $Contents) {
            if ($null -eq $turn) { continue }
            [ordered]@{
                role  = [string]$turn.role
                parts = @($turn.parts)
            }
        }
    )

    $payload = [ordered]@{
        systemInstruction = $SystemInstruction
        contents          = $geminiContents
    }

    if ($null -ne $GeminiTools) {
        $payload.tools = $GeminiTools
    }

    if ($null -ne $GeminiToolConfig) {
        $payload.toolConfig = $GeminiToolConfig
    }

    if ($null -ne $GeminiSafetySettings) {
        $payload.safetySettings = $GeminiSafetySettings
    }

    if ($null -ne $GeminiGenerationConfig) {
        $payload.generationConfig = $GeminiGenerationConfig
    }

    # Resolve the provider override first, then the live .effort setting.
    # This payload is shared by Gemini Developer API and Antigravity OAuth.
    $effortProvider = if ($script:Provider -eq 'antigravity') { 'antigravity' } else { 'gemini' }
    $effectiveEffort = Get-GemmaEffectiveEffort -Provider $effortProvider
    if ($script:MODEL -match '(?i)gemini[-.]?3') {
        if ($null -eq $payload.generationConfig) { $payload.generationConfig = @{} }
        $payload.generationConfig.thinkingConfig = @{ thinkingLevel = $effectiveEffort.ToUpperInvariant(); includeThoughts = [bool]$script:VerboseOutput }
    } elseif ($script:MODEL -match '(?i)gemini[-.]?2.5') {
        if ($null -eq $payload.generationConfig) { $payload.generationConfig = @{} }
        $thinkingBudget = switch ($effectiveEffort) {
            'low' { 1024 }
            'medium' { 8192 }
            'high' { 24576 }
        }
        $payload.generationConfig.thinkingConfig = @{ thinkingBudget = $thinkingBudget; includeThoughts = [bool]$script:VerboseOutput }
    }

    if (-not [string]::IsNullOrWhiteSpace($GeminiCachedContent)) {
        $payload.cachedContent = $GeminiCachedContent
    }

    return $payload
}

function Rollback-MiraTurn {
    param(
        [System.Collections.ArrayList]$History,
        [int]$StartCount
    )

    while ($History.Count -gt $StartCount) {
        $History.RemoveAt($History.Count - 1)
    }
}
