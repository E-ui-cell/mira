# WINDOWS POWERSHELL 5.1
# Groq provider: OpenAI-compatible Chat Completions with native reasoning controls.

function Get-GroqApiKeys {
    return @($script:GroqApiKeys)
}

function Test-GemmaGroqReasoningEffortModel {
    param([string]$Model)

    $id = ([string]$Model).Trim()
    return ($id -match '(?i)^(openai/gpt-oss-(20b|120b)|qwen/qwen3\.8-27b|meta-models/muse-spark-open)$')
}

function Test-GemmaGroqReasoningModel {
    param([string]$Model)

    $id = ([string]$Model).Trim()
    return ($id -match '(?i)^(openai/gpt-oss-(20b|120b|safeguard-20b)|qwen/qwen3\.8-27b|minimaxai/minimax-m2\.7|meta-models/muse-spark-open)$')
}

function Get-GroqModels {
    $keys = @(Get-GroqApiKeys)
    if ($keys.Count -eq 0) { return @() }

    $lastFailure = ''
    for ($offset = 0; $offset -lt $keys.Count; $offset++) {
        $keyIndex = ($script:MiraGroqApiKeyIndex + $offset) % $keys.Count
        try {
            $response = Invoke-RestMethod -Uri 'https://api.groq.com/openai/v1/models' -Method Get -Headers @{
                Authorization = ('Bearer ' + [string]$keys[$keyIndex])
            } -TimeoutSec 20 -ErrorAction Stop

            $models = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in @($response.data)) {
                if ($null -eq $item) { continue }
                $id = ([string]$item.id).Trim()
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                if ($null -ne $item.active -and -not [bool]$item.active) { continue }
                # The model-list endpoint also advertises audio/embedding models;
                # this picker is specifically for chat-completion models.
                if ($id -match '(?i)(whisper|transcrib|text-to-speech|tts|embedding)') { continue }
                [void]$models.Add([pscustomobject]@{
                    name = $id
                    displayName = $id
                    contextWindow = $item.context_window
                    maxCompletionTokens = $item.max_completion_tokens
                })
            }
            return @($models.ToArray())
        } catch {
            $lastFailure = [string]$_.Exception.Message
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            $retryable = ($status -in @(0,401,403,408,429,500,502,503,504)) -or
                ($lastFailure -match '(?i)timeout|connection reset|connection closed|name resolution')
            if (-not $retryable -or $offset -ge ($keys.Count - 1)) { break }
        }
    }

    throw ('Groq model catalogue request failed: ' + $lastFailure)
}

function Build-GemmaGroqChatPayload {
    param(
        [object]$SystemInstruction,
        [System.Collections.IList]$Contents,
        [bool]$Streaming = $false
    )

    $payload = [ordered]@{
        model = [string]$script:MODEL
        messages = (ConvertTo-GemmaOpenAIMessages -SystemInstruction $SystemInstruction -Contents $Contents)
    }

    $tools = @(ConvertTo-GemmaOpenAITools -GeminiTools $GeminiTools)
    if ($tools.Count -gt 0) {
        $payload.tools = $tools
        $payload.tool_choice = 'auto'
    }

    $effortResolution = Get-GemmaEffortResolution -Provider 'groq' -Model $script:MODEL
    if (Test-GemmaGroqReasoningModel -Model $script:MODEL) {
        if ($effortResolution.Supported) {
            $payload.reasoning_effort = [string]$effortResolution.Effort
        }
        if ([string]$script:MODEL -match '(?i)^openai/gpt-oss-') {
            # GPT-OSS does not accept reasoning_format; use its separate flag.
            $payload.include_reasoning = [bool]$script:VerboseOutput
        } else {
            # Other reasoning models expose parsed reasoning in a dedicated field.
            $payload.reasoning_format = if ($script:VerboseOutput) { 'parsed' } else { 'hidden' }
        }
    }

    if ($null -ne $MIRA_GROQ_MAX_COMPLETION_TOKENS) {
        $payload.max_completion_tokens = [int]$MIRA_GROQ_MAX_COMPLETION_TOKENS
    }
    if ($null -ne $MIRA_GROQ_TEMPERATURE) {
        $payload.temperature = [double]$MIRA_GROQ_TEMPERATURE
    }
    if ($null -ne $MIRA_GROQ_TOP_P) {
        $payload.top_p = [double]$MIRA_GROQ_TOP_P
    }
    if ($null -ne $MIRA_GROQ_RESPONSE_FORMAT) {
        $payload.response_format = $MIRA_GROQ_RESPONSE_FORMAT
    }

    if ($Streaming) {
        $payload.stream = $true
    }

    return $payload
}
