# WINDOWS POWERSHELL 5.1
# OpenAI provider: Responses API for gpt-6-luna; Chat Completions for other models. No SDK dependency.

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
    $effectiveEffort = Get-GemmaRequestEffort -Provider 'openai' -Model $script:MODEL
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
        throw "Chat Completions provider returned no choices. $detail"
    }
    $choice = $OpenAIResponse.choices[0]
    $message = $choice.message
    $parts = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace([string]$message.reasoning)) {
        [void]$parts.Add(@{ text=[string]$message.reasoning; thought=$true })
    }
    if ($null -ne $message.content) {
        if ($message.content -is [string] -and -not [string]::IsNullOrWhiteSpace($message.content)) {
            [void]$parts.Add(@{ text=[string]$message.content })
        } elseif ($message.content -is [array]) {
            foreach ($item in $message.content) { if ($item.type -eq 'text' -and $item.text) { [void]$parts.Add(@{ text=[string]$item.text }) } }
        }
    }
    foreach ($toolCall in @($message.tool_calls)) {
        # Text-only Chat Completions omit tool_calls; @($null) still contains one item.
        if ($null -eq $toolCall) { continue }
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

# GPT-6 Luna uses the Responses API. Keep its native output items in
# conversation history so reasoning/tool-call state survives each tool round.
function ConvertTo-GemmaOpenAIResponsesInput {
    param([object]$SystemInstruction,[System.Collections.IList]$Contents)

    $inputItems = New-Object System.Collections.Generic.List[object]
    # Gemini's functionCall.id and functionResponse.id are optional. When
    # importing such history into Responses, synthesize a paired ID locally.
    $pendingCallIdsByName = @{}
    foreach ($turn in $Contents) {
        if ($null -eq $turn -or $null -eq $turn.parts) { continue }

        if ($turn.role -eq 'user') {
            $toolResponses = @($turn.parts | Where-Object { $null -ne $_.functionResponse })
            if ($toolResponses.Count -gt 0) {
                foreach ($part in $toolResponses) {
                    $fr = $part.functionResponse
                    $callId = [string]$fr.id
                    $callName = [string]$fr.name
                    if ([string]::IsNullOrWhiteSpace($callId)) {
                        if ($pendingCallIdsByName.ContainsKey($callName) -and $pendingCallIdsByName[$callName].Count -gt 0) {
                            $callId = [string]$pendingCallIdsByName[$callName][0]
                            $pendingCallIdsByName[$callName].RemoveAt(0)
                        } else {
                            throw "OpenAI Responses API cannot match the previous tool call for '$callName'. Start a new session or use .oneshot."
                        }
                    } elseif ($pendingCallIdsByName.ContainsKey($callName)) {
                        for ($pendingIndex = $pendingCallIdsByName[$callName].Count - 1; $pendingIndex -ge 0; $pendingIndex--) {
                            if ([string]$pendingCallIdsByName[$callName][$pendingIndex] -eq $callId) {
                                $pendingCallIdsByName[$callName].RemoveAt($pendingIndex)
                                break
                            }
                        }
                    }
                    $output = $fr.response | ConvertTo-Json -Depth 30 -Compress
                    [void]$inputItems.Add(@{ type='function_call_output'; call_id=$callId; output=$output })
                }
                continue
            }

            $content = New-Object System.Collections.Generic.List[object]
            foreach ($part in @($turn.parts)) {
                if ($null -eq $part) { continue }
                if ($null -ne $part.text -and -not [string]::IsNullOrWhiteSpace([string]$part.text)) {
                    [void]$content.Add(@{ type='input_text'; text=[string]$part.text })
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
                    if ($mimeType -notlike 'image/*') {
                        throw "OpenAI Responses API currently supports image attachments, not '$mimeType'. Use Gemini for PDF, audio, or video attachments."
                    }
                    [void]$content.Add(@{ type='input_image'; image_url=("data:{0};base64,{1}" -f $mimeType,$imageData) })
                }
            }
            [void]$inputItems.Add(@{ type='message'; role='user'; content=@($content.ToArray()) })
            continue
        }

        if ($turn.role -eq 'model') {
            if ($null -ne $turn.openaiOutputItems -and @($turn.openaiOutputItems).Count -gt 0) {
                # Native Responses items retain reasoning and tool-call metadata.
                foreach ($item in @($turn.openaiOutputItems)) { [void]$inputItems.Add($item) }
            } else {
                # Rebuild normalized tool calls when history was created by
                # Gemini or OpenAI Chat Completions before switching to Luna.
                $textParts = @($turn.parts | Where-Object { $null -ne $_.text -and -not $_.thought } | ForEach-Object { [string]$_.text })
                if ($textParts.Count -gt 0) {
                    [void]$inputItems.Add(@{ type='message'; role='assistant'; content=($textParts -join [Environment]::NewLine) })
                }
                $calls = @($turn.parts | Where-Object { $null -ne $_.functionCall } | ForEach-Object { $_.functionCall })
                foreach ($call in $calls) {
                    $callId = [string]$call.id
                    if ([string]::IsNullOrWhiteSpace($callId)) {
                        $callId = 'call_' + [guid]::NewGuid().ToString('N')
                    }
                    $callName = [string]$call.name
                    if (-not $pendingCallIdsByName.ContainsKey($callName)) {
                        $pendingCallIdsByName[$callName] = New-Object System.Collections.ArrayList
                    }
                    [void]$pendingCallIdsByName[$callName].Add($callId)
                    $arguments = $call.args | ConvertTo-Json -Depth 30 -Compress
                    [void]$inputItems.Add(@{
                        type = 'function_call'
                        call_id = $callId
                        name = $callName
                        arguments = $arguments
                    })
                }
            }
        }
    }
    return ,@($inputItems.ToArray())
}

function Build-GemmaOpenAIResponsesPayload {
    param([object]$SystemInstruction,[System.Collections.IList]$Contents)

    $instructions = ''
    if ($null -ne $SystemInstruction -and $null -ne $SystemInstruction.parts) {
        $instructions = (@($SystemInstruction.parts | Where-Object { $_.text } | ForEach-Object { [string]$_.text }) -join [Environment]::NewLine)
    }

    $payload = [ordered]@{
        model = [string]$script:MODEL
        store = $false
        input = (ConvertTo-GemmaOpenAIResponsesInput -SystemInstruction $SystemInstruction -Contents $Contents)
    }
    if (-not $script:CommandMode) {
        $searchGuidance = 'For current or time-sensitive information, recent events, changing facts, prices or versions, and explicit requests to search online, use the native web_search tool. Cite the sources it returns. Do not claim that a web lookup occurred unless the tool was used. quick_web is only for its narrow utility actions, not general web search.'
        if ([string]::IsNullOrWhiteSpace($instructions)) {
            $instructions = $searchGuidance
        } else {
            $instructions = $instructions.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $searchGuidance
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($instructions)) { $payload.instructions = $instructions }

    $tools = @(ConvertTo-GemmaOpenAITools -GeminiTools $GeminiTools)
    $responsesTools = New-Object System.Collections.Generic.List[object]
    foreach ($tool in $tools) {
        [void]$responsesTools.Add(@{
            type = 'function'
            name = [string]$tool.function.name
            description = [string]$tool.function.description
            parameters = $tool.function.parameters
            strict = $false
        })
    }

    # Luna supports OpenAI-hosted web search directly through the Responses API.
    # This is independent of Gemini's Antigravity-backed web_search function.
    # Keep all tools disabled in command-generation mode.
    if (-not $script:CommandMode) {
        [void]$responsesTools.Add(@{
            type = 'web_search'
            search_context_size = 'medium'
            external_web_access = $true
            user_location = @{ type = 'approximate' }
        })
    }

    if ($responsesTools.Count -gt 0) {
        $payload.tools = @($responsesTools.ToArray())
        $payload.tool_choice = 'auto'
    }

    $effectiveEffort = Get-GemmaRequestEffort -Provider 'openai' -Model $script:MODEL
    $payload.reasoning = @{ effort = $effectiveEffort }
    if ($null -ne $MIRA_OPENAI_MAX_COMPLETION_TOKENS) {
        $payload.max_output_tokens = [int]$MIRA_OPENAI_MAX_COMPLETION_TOKENS
    }
    if ($null -ne $MIRA_OPENAI_RESPONSE_FORMAT) {
        $formatType = [string]$MIRA_OPENAI_RESPONSE_FORMAT.type
        if ($formatType -eq 'json_object') {
            $payload.text = @{ format = @{ type = 'json_object' } }
        } elseif ($formatType -eq 'json_schema') {
            # Chat Completions nests schema settings under json_schema;
            # Responses expects name/schema/strict directly under text.format.
            $schemaConfig = $MIRA_OPENAI_RESPONSE_FORMAT.json_schema
            if ($null -ne $schemaConfig) {
                $responsesFormat = [ordered]@{
                    type = 'json_schema'
                    name = [string]$schemaConfig.name
                    schema = $schemaConfig.schema
                }
                if ($null -ne $schemaConfig.strict) { $responsesFormat.strict = [bool]$schemaConfig.strict }
                if (-not [string]::IsNullOrWhiteSpace([string]$schemaConfig.description)) {
                    $responsesFormat.description = [string]$schemaConfig.description
                }
                $payload.text = @{ format = $responsesFormat }
            } else {
                # Also accept a Responses-shaped setting for direct configuration.
                $payload.text = @{ format = $MIRA_OPENAI_RESPONSE_FORMAT }
            }
        }
    }
    return $payload
}

function ConvertFrom-GemmaOpenAIResponsesResponse {
    param([Parameter(Mandatory=$true)]$OpenAIResponse)

    if ($null -ne $OpenAIResponse.error) {
        throw "OpenAI Responses API error: $($OpenAIResponse.error.message)"
    }
    $outputItems = @($OpenAIResponse.output)
    if ($outputItems.Count -eq 0) {
        throw "OpenAI Responses API returned no output items. Status: $($OpenAIResponse.status)"
    }

    $parts = New-Object System.Collections.Generic.List[object]
    $webCitations = New-Object System.Collections.Generic.List[object]
    $seenWebCitationUrls = @{}
    foreach ($item in $outputItems) {
        if ($item.type -eq 'message') {
            foreach ($content in @($item.content)) {
                if ($content.type -eq 'output_text' -and -not [string]::IsNullOrWhiteSpace([string]$content.text)) {
                    [void]$parts.Add(@{ text=[string]$content.text })
                    foreach ($annotation in @($content.annotations)) {
                        if ($annotation.type -ne 'url_citation') { continue }
                        $citationUrl = ([string]$annotation.url).Trim()
                        if ($citationUrl -notmatch '^https?://') { continue }
                        if ($seenWebCitationUrls.ContainsKey($citationUrl)) { continue }
                        $seenWebCitationUrls[$citationUrl] = $true
                        [void]$webCitations.Add([pscustomobject]@{
                            url = $citationUrl
                            title = [string]$annotation.title
                            startIndex = $annotation.start_index
                            endIndex = $annotation.end_index
                        })
                    }
                } elseif ($content.type -eq 'refusal' -and $content.refusal) {
                    [void]$parts.Add(@{ text=[string]$content.refusal })
                }
            }
        } elseif ($item.type -eq 'function_call') {
            $arguments = @{}
            try {
                if ($item.arguments) { $arguments = [string]$item.arguments | ConvertFrom-Json -ErrorAction Stop }
            } catch {
                $arguments = @{ _raw_arguments=[string]$item.arguments }
            }
            [void]$parts.Add(@{
                functionCall = @{
                    id = [string]$item.call_id
                    name = [string]$item.name
                    args = $arguments
                }
            })
        }
    }

    $usage = $OpenAIResponse.usage
    return [pscustomobject]@{
        candidates = @([pscustomobject]@{
            content = [pscustomobject]@{ parts=@($parts.ToArray()) }
            finishReason = [string]$OpenAIResponse.status
        })
        usageMetadata = [pscustomobject]@{
            promptTokenCount = if ($null -ne $usage) { [int]$usage.input_tokens } else { 0 }
            candidatesTokenCount = if ($null -ne $usage) { [int]$usage.output_tokens } else { 0 }
        }
        openaiResponseId = [string]$OpenAIResponse.id
        openaiModel = [string]$OpenAIResponse.model
        openaiOutputItems = $outputItems
        webCitations = @($webCitations.ToArray())
    }
}

function Format-GemmaOpenAIWebCitations {
    param([object[]]$Citations)

    $lines = New-Object System.Collections.Generic.List[string]
    $seenUrls = @{}
    foreach ($citation in @($Citations)) {
        if ($null -eq $citation) { continue }
        $url = ([string]$citation.url).Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        $parsedUri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsedUri)) { continue }
        if ($parsedUri.Scheme -ne 'http' -and $parsedUri.Scheme -ne 'https') { continue }
        if ($seenUrls.ContainsKey($url)) { continue }
        $seenUrls[$url] = $true

        $title = [regex]::Replace([string]$citation.title, '[\x00-\x1F\x7F]', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $url }
        $number = [int]($lines.Count / 2) + 1
        [void]$lines.Add(('[{0}] {1}' -f $number, $title))
        [void]$lines.Add(('    ' + $url))
    }

    if ($lines.Count -eq 0) { return '' }
    return ('Sources:' + [Environment]::NewLine + [string]::Join([Environment]::NewLine, $lines.ToArray()))
}
