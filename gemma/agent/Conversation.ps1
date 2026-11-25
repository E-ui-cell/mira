function Get-GemmaEffortResolution {
    param(
        [ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider,
        [string]$Model = $script:MODEL
    )

    # Resolution order: shared .effort -> provider override -> model override.
    # A configured, more-specific override always takes precedence.
    $value = [string]$script:Effort
    $source = 'shared setting'
    $providerOverride = switch ($Provider) {
        'openai' { $MIRA_OPENAI_EFFORT }
        'gemini' { $MIRA_GEMINI_EFFORT }
        'antigravity' { $MIRA_ANTIGRAVITY_EFFORT }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$providerOverride)) {
        $value = [string]$providerOverride
        $source = "$Provider override"
    }

    if ($Provider -eq 'openai' -and $Model -ieq 'gpt-6-luna' -and
        -not [string]::IsNullOrWhiteSpace([string]$MIRA_OPENAI_LUNA_EFFORT)) {
        $value = [string]$MIRA_OPENAI_LUNA_EFFORT
        $source = 'gpt-6-luna model override'
    }

    $value = $value.Trim().ToLowerInvariant()
    $allowed = if ($Provider -eq 'openai') {
        @('none','minimal','low','medium','high','xhigh','max')
    } else {
        @('low','medium','high')
    }
    if ($value -notin $allowed) {
        throw "Invalid $Provider reasoning effort '$value'. Allowed values: $($allowed -join ', ')."
    }

    $parameter = $null
    if ($Provider -eq 'openai') {
        $parameter = if ($Model -ieq 'gpt-6-luna') { 'reasoning.effort' } else { 'reasoning_effort' }
    } elseif ($Model -match '(?i)gemini[-.]?3') {
        $parameter = 'generationConfig.thinkingConfig.thinkingLevel'
    } elseif ($Model -match '(?i)gemini[-.]?2.5') {
        $parameter = 'generationConfig.thinkingConfig.thinkingBudget'
    }

    return [pscustomobject]@{
        Provider = $Provider
        Model = $Model
        Effort = $value
        Source = $source
        Parameter = $parameter
        Supported = (-not [string]::IsNullOrWhiteSpace([string]$parameter))
    }
}

function Get-GemmaEffectiveEffort {
    param(
        [ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider,
        [string]$Model = $script:MODEL
    )
    return (Get-GemmaEffortResolution -Provider $Provider -Model $Model).Effort
}

function Get-GemmaRequestEffort {
    param(
        [ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider,
        [string]$Model = $script:MODEL
    )
    # Keep the reported value identical to the value serialized into the request.
    # Luna uses the Responses API, where reasoning effort and function tools coexist.
    return (Get-GemmaEffortResolution -Provider $Provider -Model $Model).Effort
}

function Get-GemmaEffortStatusText {
    param(
        [ValidateSet('openai','gemini','antigravity')][string]$Provider = $script:Provider,
        [string]$Model = $script:MODEL
    )
    $resolution = Get-GemmaEffortResolution -Provider $Provider -Model $Model
    if (-not $resolution.Supported) {
        return 'model default (this model exposes no reasoning-effort control)'
    }
    return ('{0} ({1})' -f $resolution.Effort,$resolution.Source)
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

    # This payload is shared by Gemini Developer API and Antigravity OAuth.
    $effortProvider = if ($script:Provider -eq 'antigravity') { 'antigravity' } else { 'gemini' }
    $effortResolution = Get-GemmaEffortResolution -Provider $effortProvider -Model $script:MODEL
    if ($effortResolution.Supported) {
        if ($null -eq $payload.generationConfig) { $payload.generationConfig = @{} }
        switch ($effortResolution.Parameter) {
            'generationConfig.thinkingConfig.thinkingLevel' {
                $payload.generationConfig.thinkingConfig = @{
                    thinkingLevel = $effortResolution.Effort.ToUpperInvariant()
                    includeThoughts = [bool]$script:VerboseOutput
                }
            }
            'generationConfig.thinkingConfig.thinkingBudget' {
                $thinkingBudget = switch ($effortResolution.Effort) {
                    'low' { 1024 }
                    'medium' { 8192 }
                    'high' { 24576 }
                }
                $payload.generationConfig.thinkingConfig = @{
                    thinkingBudget = $thinkingBudget
                    includeThoughts = [bool]$script:VerboseOutput
                }
            }
        }
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
