function Build-GeminiPayload {
    param(
        [object]$SystemInstruction,
        [object]$Contents
    )

    $payload = [ordered]@{
        systemInstruction = $SystemInstruction
        contents          = $Contents
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

    # Gemini 3 uses thinkingLevel; Gemini 2.5 uses thinkingBudget.
    # This payload is shared by Gemini Developer API and Antigravity OAuth.
    if ($script:MODEL -match '(?i)gemini[-.]?3') {
        if ($null -eq $payload.generationConfig) { $payload.generationConfig = @{} }
        $payload.generationConfig.thinkingConfig = @{ thinkingLevel = $script:Effort.ToUpperInvariant(); includeThoughts = [bool]$script:VerboseOutput }
    } elseif ($script:MODEL -match '(?i)gemini[-.]?2.5') {
        if ($null -eq $payload.generationConfig) { $payload.generationConfig = @{} }
        $thinkingBudget = switch ($script:Effort) {
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
