# WINDOWS POWERSHELL 5.1
# OpenAI Chat Completions provider. No SDK or external runtime dependency.

function Get-GemmaOpenAIApiKeys {
    # Return only the explicit candidates configured in Defaults.ps1.
    return @($script:OpenAIApiKeys)
}

function ConvertTo-GemmaOpenAIMessageContent {
    param([object[]]$Parts)
    $content = New-Object System.Collections.Generic.List[object]
    foreach ($part in @($Parts)) {
        if ($null -eq $part) { continue }
        if ($null -ne $part.text -and -not [string]::IsNullOrWhiteSpace([string]$part.text)) {
            [void]$content.Add(@{ type='text'; text=[string]$part.text })
        }
        $imageData = $null
        $mimeType = 'image/png'
        if ($null -ne $part.inline_data) {
            $imageData = [string]$part.inline_data.data
            if ($part.inline_data.mime_type) { $mimeType = [string]$part.inline_data.mime_type }
        } elseif ($null -ne $part.inlineData) {
            $imageData = [string]$part.inlineData.data
            if ($part.inlineData.mimeType) { $mimeType = [string]$part.inlineData.mimeType }
        }
        if (-not [string]::IsNullOrWhiteSpace($imageData)) {
            if ($mimeType -notlike 'image/*') { throw "OpenAI Chat Completions currently supports image attachments, not '$mimeType'. Use Gemini for PDF, audio, or video attachments." }
            [void]$content.Add(@{ type='image_url'; image_url=@{ url=("data:{0};base64,{1}" -f $mimeType,$imageData) } })
        }
    }
    if ($content.Count -eq 0) { return '' }
    if ($content.Count -eq 1 -and $content[0].type -eq 'text') { return [string]$content[0].text }
    return ,@($content.ToArray())
}

function ConvertTo-GemmaOpenAIMessages {
    param([object]$SystemInstruction,[System.Collections.IList]$Contents)
    $messages = New-Object System.Collections.Generic.List[object]
    $systemText = ''
    if ($null -ne $SystemInstruction -and $null -ne $SystemInstruction.parts) {
        $systemText = (@($SystemInstruction.parts | Where-Object { $_.text } | ForEach-Object { [string]$_.text }) -join [Environment]::NewLine)
    }
    if (-not [string]::IsNullOrWhiteSpace($systemText)) { [void]$messages.Add(@{ role='system'; content=$systemText }) }

    foreach ($turn in $Contents) {
        if ($null -eq $turn -or $null -eq $turn.parts) { continue }
        if ($turn.role -eq 'user') {
            $toolResponses = @($turn.parts | Where-Object { $null -ne $_.functionResponse })
            if ($toolResponses.Count -gt 0) {
                foreach ($part in $toolResponses) {
                    $response = $part.functionResponse
                    $toolCallId = [string]$response.id
                    if ([string]::IsNullOrWhiteSpace($toolCallId)) { $toolCallId = [string]$response.name }
                    $toolContent = $response.response | ConvertTo-Json -Depth 20 -Compress
                    [void]$messages.Add(@{ role='tool'; tool_call_id=$toolCallId; content=$toolContent })
                }
                continue
            }
            $content = ConvertTo-GemmaOpenAIMessageContent -Parts @($turn.parts)
            if ($content -is [array]) { [void]$messages.Add(@{ role='user'; content=$content }) }
            else { [void]$messages.Add(@{ role='user'; content=[string]$content }) }
            continue
        }
        if ($turn.role -eq 'model') {
            $textParts = @($turn.parts | Where-Object { $null -ne $_.text -and -not $_.thought } | ForEach-Object { [string]$_.text })
            $calls = @($turn.parts | Where-Object { $null -ne $_.functionCall } | ForEach-Object { $_.functionCall })
            $message = @{ role='assistant' }
            if ($textParts.Count -gt 0) { $message.content = ($textParts -join [Environment]::NewLine) }
            elseif ($calls.Count -eq 0) { $message.content = '' }
            if ($calls.Count -gt 0) {
                $toolCalls = New-Object System.Collections.Generic.List[object]
                foreach ($call in $calls) {
                    $callId = if ($call.id) { [string]$call.id } else { 'call_' + [guid]::NewGuid().ToString('N') }
                    $arguments = $call.args | ConvertTo-Json -Depth 20 -Compress
                    [void]$toolCalls.Add(@{ id=$callId; type='function'; function=@{ name=[string]$call.name; arguments=$arguments } })
                }
                $message.tool_calls = @($toolCalls.ToArray())
            }
            [void]$messages.Add($message)
        }
    }
    return ,@($messages.ToArray())
}

function ConvertTo-GemmaOpenAITools {
    param([object]$GeminiTools)
    $declarations = New-Object System.Collections.Generic.List[object]
    foreach ($toolGroup in @($GeminiTools)) {
        foreach ($declaration in @($toolGroup.functionDeclarations)) {
            if ($null -eq $declaration) { continue }
            $parameters = $declaration.parameters
            if ($null -eq $parameters) { $parameters = @{ type='object'; properties=@{} } }
            [void]$declarations.Add(@{ type='function'; function=@{ name=[string]$declaration.name; description=[string]$declaration.description; parameters=$parameters } })
        }
    }
    return $declarations.ToArray()
}

function Build-GemmaOpenAIChatPayload {
    param([object]$SystemInstruction,[System.Collections.IList]$Contents)
    $payload = [ordered]@{
        model = [string]$script:MODEL
        messages = (ConvertTo-GemmaOpenAIMessages -SystemInstruction $SystemInstruction -Contents $Contents)
    }
    $tools = @(ConvertTo-GemmaOpenAITools -GeminiTools $GeminiTools)
    if ($tools.Count -gt 0) { $payload.tools = $tools; $payload.tool_choice = 'auto' }
    $effectiveEffort = Get-GemmaRequestEffort -Provider 'openai'
    if ([string]$script:MODEL -ieq 'gpt-6-luna' -and -not [string]::IsNullOrWhiteSpace([string]$MIRA_OPENAI_LUNA_EFFORT)) {
        $effectiveEffort = ([string]$MIRA_OPENAI_LUNA_EFFORT).Trim().ToLowerInvariant()
    }
    $payload.reasoning_effort = $effectiveEffort
    if ($null -ne $MIRA_OPENAI_MAX_COMPLETION_TOKENS) { $payload.max_completion_tokens = [int]$MIRA_OPENAI_MAX_COMPLETION_TOKENS }
    # GPT-6 reasoning requests reject sampling controls such as temperature.
    if ($effectiveEffort -eq 'none' -and $null -ne $MIRA_OPENAI_TEMPERATURE) { $payload.temperature = [double]$MIRA_OPENAI_TEMPERATURE }
    if ($null -ne $MIRA_OPENAI_RESPONSE_FORMAT) { $payload.response_format = $MIRA_OPENAI_RESPONSE_FORMAT }
    return $payload
}

function ConvertFrom-GemmaOpenAIResponse {
    param([Parameter(Mandatory=$true)]$OpenAIResponse)
    if ($null -eq $OpenAIResponse.choices -or $OpenAIResponse.choices.Count -eq 0) {
        $detail = if ($OpenAIResponse.error.message) { [string]$OpenAIResponse.error.message } else { 'No choices returned.' }
        throw "OpenAI returned no chat completion choices. $detail"
    }
    $choice = $OpenAIResponse.choices[0]
    $message = $choice.message
    $parts = New-Object System.Collections.Generic.List[object]
    if ($null -ne $message.content) {
        if ($message.content -is [string] -and -not [string]::IsNullOrWhiteSpace($message.content)) {
            [void]$parts.Add(@{ text=[string]$message.content })
        } elseif ($message.content -is [array]) {
            foreach ($item in $message.content) { if ($item.type -eq 'text' -and $item.text) { [void]$parts.Add(@{ text=[string]$item.text }) } }
        }
    }
    foreach ($toolCall in @($message.tool_calls)) {
        $arguments = @{}
        try { if ($toolCall.function.arguments) { $arguments = [string]$toolCall.function.arguments | ConvertFrom-Json -ErrorAction Stop } }
        catch { $arguments = @{ _raw_arguments=[string]$toolCall.function.arguments } }
        [void]$parts.Add(@{ functionCall=@{ id=[string]$toolCall.id; name=[string]$toolCall.function.name; args=$arguments } })
    }
    if ($null -ne $message.function_call) {
        $legacyArgs = @{}
        try { $legacyArgs = [string]$message.function_call.arguments | ConvertFrom-Json -ErrorAction Stop } catch {}
        [void]$parts.Add(@{ functionCall=@{ name=[string]$message.function_call.name; args=$legacyArgs } })
    }
    $usage = $OpenAIResponse.usage
    return [pscustomobject]@{
        candidates = @([pscustomobject]@{ content=[pscustomobject]@{ parts=@($parts.ToArray()) }; finishReason=[string]$choice.finish_reason })
        usageMetadata = [pscustomobject]@{
            promptTokenCount = if ($null -ne $usage) { [int]$usage.prompt_tokens } else { 0 }
            candidatesTokenCount = if ($null -ne $usage) { [int]$usage.completion_tokens } else { 0 }
        }
        openaiResponseId = [string]$OpenAIResponse.id
        openaiModel = [string]$OpenAIResponse.model
    }
}
