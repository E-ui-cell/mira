    $toolConfiguration = Get-GemmaToolConfiguration
    $GeminiTools = $toolConfiguration.Tools
    $GeminiToolConfig = $toolConfiguration.ToolConfig

    # Everything added for this user turn is rolled back on cancellation or
    # request failure. This prevents stale/empty context on the next loop.

    # A request can require one or more tool calls before Gemini produces the
    # final answer. Keep the tool exchange inside the same user turn.
    $toolLoop = $true
    $toolRounds = 0
    $maxToolRounds = $MIRA_MAX_TOOL_ROUNDS
    # One stopwatch and token accumulator cover the entire turn, including
    # function-call rounds, so the final header reports total request time.
    $turnStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $turnPromptTokens = 0
    $turnCompletionTokens = 0

    try {
        # Native Search is conditional, not mandatory for ordinary conversation.
        # Only an explicit/current-information request invokes the Search phase.
        # Follow-up chat and simple requests go directly to the selected model.
        if ($script:Provider -eq 'antigravity' -and -not $script:CommandMode -and
            (Test-GemmaSearchIntent -Text $rawInput)) {
            Invoke-GemmaAntigravityGoogleSearchPreflight
        }

        while ($toolLoop) {
        $toolRounds++
        if ($toolRounds -gt $maxToolRounds) {
            throw "Tool loop exceeded $maxToolRounds rounds; aborting this turn to prevent an infinite request cycle."
        }

        $usingOpenAI = ($script:Provider -eq 'openai')
        $usingOpenAIResponses = ($usingOpenAI -and [string]$script:MODEL -ieq 'gpt-6-luna')
        if ($usingOpenAIResponses) {
            $payloadObj = Build-GemmaOpenAIResponsesPayload -SystemInstruction $SystemInstruction -Contents $Contents
        } elseif ($usingOpenAI) {
            $payloadObj = Build-GemmaOpenAIChatPayload -SystemInstruction $SystemInstruction -Contents $Contents
        } else {
            $payloadObj = Build-GeminiPayload -SystemInstruction $SystemInstruction -Contents $Contents
        }
        $streamMode = [string]$script:StreamingMode
        $streamOpenAIResponses = ($usingOpenAIResponses -and $streamMode -ne 'off')
        $streamGoogle = (-not $usingOpenAI -and $streamMode -ne 'off')
        $streamingActive = ($streamOpenAIResponses -or $streamGoogle)
        if ($streamOpenAIResponses) {
            # Luna uses the Responses API SSE stream when streaming is enabled.
            $payloadObj.stream = $true
        }
        $usingAntigravityOAuth = ($script:Provider -eq 'antigravity')
        $requestApiKeys = @()
        $requestKeyIndex = 0
        $requestProviderName = 'gemini'

        if ($usingAntigravityOAuth) {
            $requestProviderName = 'antigravity'
            $accessToken = Get-AntigravityAccessToken
            $project = Get-AntigravityProject
            $payloadObj.systemInstruction.role = "user"
            if ($payloadObj.Contains("safetySettings")) { [void]$payloadObj.Remove("safetySettings") }
            $requestEnvelope = @{
                project = $project
                requestId = "agent-" + [guid]::NewGuid().ToString("N")
                request = $payloadObj
                model = $MODEL
                userAgent = "antigravity"
                requestType = "agent"
            }
            $jsonPayload = $requestEnvelope | ConvertTo-Json -Depth 30
            if ($streamGoogle) { $url = "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse" }
            else { $url = "https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent" }
            $requestHeaders = Get-AntigravityHeaders -AccessToken $accessToken
        } elseif ($usingOpenAI) {
            $requestApiKeys = @(Get-GemmaOpenAIApiKeys)
            if ($requestApiKeys.Count -eq 0) { throw 'OpenAI API key is not configured in the OpenAI candidate list in Defaults.ps1.' }
            if ($null -ne $script:MiraOpenAIApiKeyIndex) { $requestKeyIndex = [int]($script:MiraOpenAIApiKeyIndex % $requestApiKeys.Count) }
            $jsonPayload = $payloadObj | ConvertTo-Json -Depth 30
            if ($usingOpenAIResponses) { $url = 'https://api.openai.com/v1/responses' }
            else { $url = 'https://api.openai.com/v1/chat/completions' }
            $requestHeaders = @{}
            $requestProviderName = 'openai'
        } else {
            $requestApiKeys = @(Get-GeminiApiKeys)
            if ($requestApiKeys.Count -eq 0) { throw 'Gemini API keys are not configured in the Gemini candidate list in Defaults.ps1.' }
            if ($null -ne $script:MiraGeminiApiKeyIndex) { $requestKeyIndex = [int]($script:MiraGeminiApiKeyIndex % $requestApiKeys.Count) }
            $jsonPayload = $payloadObj | ConvertTo-Json -Depth 30
            if ($streamGoogle) { $url = "https://generativelanguage.googleapis.com/v1beta/models/$($MODEL):streamGenerateContent?alt=sse" }
            else { $url = "https://generativelanguage.googleapis.com/v1beta/models/$($MODEL):generateContent" }
            $requestHeaders = @{ 'x-goog-api-key' = $requestApiKeys[$requestKeyIndex] }
        }

        $requestStats = [hashtable]::Synchronized(@{
            HttpAttempts = 0
            LastKeyIndex = -1
            KeyCount = [int]$requestApiKeys.Count
            KeySlotsTried = (New-Object System.Collections.ArrayList)
            RateLimitHeaders = @{}
            RequestId = ''
            HttpStatus = 0
            ErrorCode = ''
            ErrorType = ''
            StreamEventType = ''
            ErrorMessage = ''
        })

        $oldTreatControlCAsInput = $null
        $runspace = $null
        $powershell = $null

        try {
            $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
            $frames = @('.  ', '.. ', '...', '   ')
            $i = 0
            $sw = [Diagnostics.Stopwatch]::StartNew()

            $streamQueue = $null
            $streamState = $null
            if ($streamingActive) {
                $streamQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
                $streamState = [hashtable]::Synchronized(@{
                    TextStarted = $false
                    Request = $null
                })
            }

            $canReadConsoleKeys = $false
            try {
                $canReadConsoleKeys = -not [Console]::IsInputRedirected
                if ($canReadConsoleKeys) {
                    $oldTreatControlCAsInput = [Console]::TreatControlCAsInput
                    [Console]::TreatControlCAsInput = $true
                }
            } catch {
                $canReadConsoleKeys = $false
                $oldTreatControlCAsInput = $null
            }

            $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open()
            $powershell = [Management.Automation.PowerShell]::Create()
            $powershell.Runspace = $runspace
            [void]$powershell.AddScript({
                param($u, $b, $h, $keyPool, $keyStart, $providerName, $streamResponses, $streamQueue, $streamState, $streamGoogle, $includeThoughts, $requestStats, $keyRotationErrorCodes)
                $getOpenAIRateHeaders = {
                    param($Headers)
                    $snapshot = @{}
                    foreach ($headerName in @(
                        'x-ratelimit-limit-requests',
                        'x-ratelimit-remaining-requests',
                        'x-ratelimit-reset-requests',
                        'x-ratelimit-limit-tokens',
                        'x-ratelimit-remaining-tokens',
                        'x-ratelimit-reset-tokens',
                        'x-ratelimit-limit-project-tokens',
                        'x-ratelimit-remaining-project-tokens',
                        'x-ratelimit-reset-project-tokens',
                        'retry-after',
                        'x-request-id'
                    )) {
                        $headerValue = ''
                        try { $headerValue = [string]$Headers[$headerName] } catch {}
                        if (-not [string]::IsNullOrWhiteSpace($headerValue)) {
                            $snapshot[$headerName] = $headerValue
                        }
                    }
                    return $snapshot
                }
                if ($streamGoogle) {
                    $lastFailure = ''
                    $keyCount = if ($providerName -eq 'gemini') { [int]$keyPool.Count } else { 1 }
                    if ($keyCount -lt 1) { throw 'Gemini streaming has no configured API key candidates.' }

                    # Replay after recoverable interruptions and suppress the exact
                    # prefix already shown, avoiding duplicated visible text.
                    $retryState = @{ Text = ''; ReplayLimit = 0; ReplayOffset = 0 }
                    $convertFunctionCall = {
                        param($Call)
                        $callMap = @{}
                        $argsSource = $null
                        if ($Call -is [System.Collections.IDictionary]) {
                            foreach ($callKey in $Call.Keys) {
                                if ([string]$callKey -eq 'args') { $argsSource = $Call[$callKey] }
                                else { $callMap[[string]$callKey] = $Call[$callKey] }
                            }
                        } elseif ($null -ne $Call) {
                            foreach ($callProperty in $Call.PSObject.Properties) {
                                if ($callProperty.Name -eq 'args') { $argsSource = $callProperty.Value }
                                else { $callMap[$callProperty.Name] = $callProperty.Value }
                            }
                        }
                        $argsMap = @{}
                        if ($argsSource -is [System.Collections.IDictionary]) {
                            foreach ($argKey in $argsSource.Keys) { $argsMap[[string]$argKey] = $argsSource[$argKey] }
                        } elseif ($null -ne $argsSource) {
                            foreach ($argProperty in $argsSource.PSObject.Properties) { $argsMap[$argProperty.Name] = $argProperty.Value }
                        }
                        $callMap['args'] = $argsMap
                        return $callMap
                    }
                    $emitGoogleText = {
                        param([string]$Value, [int]$CurrentAttempt)
                        if ([string]::IsNullOrEmpty($Value)) { return }
                        if ($retryState.ReplayLimit -gt 0 -and $retryState.ReplayOffset -lt $retryState.ReplayLimit) {
                            $matched = 0
                            while ($matched -lt $Value.Length -and
                                   $retryState.ReplayOffset -lt $retryState.ReplayLimit -and
                                   $Value[$matched] -ceq $retryState.Text[$retryState.ReplayOffset]) {
                                $matched++
                                $retryState.ReplayOffset++
                            }
                            if ($matched -gt 0) { $Value = $Value.Substring($matched) }
                            if ($Value.Length -gt 0 -and $retryState.ReplayOffset -lt $retryState.ReplayLimit) {
                                # Preserve both streams if regenerated text diverges.
                                $retryState.ReplayOffset = $retryState.ReplayLimit
                            }
                        }
                        if (-not [string]::IsNullOrEmpty($Value)) {
                            $retryState.Text += $Value
                            $streamState.TextStarted = $true
                            $streamQueue.Enqueue($Value)
                        }
                    }
                    $processGoogleEvent = {
                        param(
                            [string]$EventJson,
                            [hashtable]$ParseState,
                            [int]$CurrentAttempt,
                            [scriptblock]$EmitText,
                            [scriptblock]$ConvertCall,
                            [bool]$IncludeThoughts
                        )
                        $EventJson = $EventJson.Trim()
                        if ([string]::IsNullOrWhiteSpace($EventJson) -or $EventJson -eq '[DONE]') { return }
                        try { $eventObject = $EventJson | ConvertFrom-Json -ErrorAction Stop }
                        catch { throw "Google returned malformed streaming data: $($_.Exception.Message)" }

                        if ($null -ne $eventObject.error) {
                            $eventMessage = [string]$eventObject.error.message
                            if ([string]::IsNullOrWhiteSpace($eventMessage)) { $eventMessage = $EventJson }
                            throw "Google streaming API error: $eventMessage"
                        }

                        # Public Gemini sends candidates at the top level. Antigravity
                        # wraps the same GenerateContent response in { response: ... }.
                        if ($null -ne $eventObject.response -and $null -ne $eventObject.response.error) {
                            $eventMessage = [string]$eventObject.response.error.message
                            if ([string]::IsNullOrWhiteSpace($eventMessage)) { $eventMessage = $EventJson }
                            throw "Google streaming API error: $eventMessage"
                        }

                        $chunkResponse = $eventObject
                        if ($null -ne $eventObject.response -and @($eventObject.response.candidates).Count -gt 0) {
                            $chunkResponse = $eventObject.response
                        }
                        if ($null -ne $eventObject.response -and $null -ne $eventObject.response.usageMetadata) {
                            $ParseState.Usage = $eventObject.response.usageMetadata
                        } elseif ($null -ne $eventObject.usageMetadata) {
                            $ParseState.Usage = $eventObject.usageMetadata
                        }
                        $candidates = @($chunkResponse.candidates)
                        if ($candidates.Count -eq 0) { return }

                        $candidate = $candidates[0]
                        foreach ($candidateProperty in $candidate.PSObject.Properties) {
                            if ($candidateProperty.Name -notin @('content','finishReason','finishMessage','groundingMetadata')) {
                                $ParseState.Candidate[$candidateProperty.Name] = $candidateProperty.Value
                            }
                        }
                        if ($null -ne $candidate.content) {
                            foreach ($contentProperty in $candidate.content.PSObject.Properties) {
                                if ($contentProperty.Name -notin @('role','parts')) {
                                    $ParseState.Candidate.content[$contentProperty.Name] = $contentProperty.Value
                                }
                            }
                        }
                        if ($null -ne $candidate.content -and -not [string]::IsNullOrWhiteSpace([string]$candidate.content.role)) {
                            $ParseState.Candidate.content.role = [string]$candidate.content.role
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$candidate.finishReason)) {
                            $ParseState.Candidate.finishReason = [string]$candidate.finishReason
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$candidate.finishMessage)) {
                            $ParseState.Candidate.finishMessage = [string]$candidate.finishMessage
                        }
                        if ($null -ne $candidate.groundingMetadata) {
                            $ParseState.Candidate.groundingMetadata = $candidate.groundingMetadata
                        }

                        $incomingParts = @()
                        if ($null -ne $candidate.content -and $null -ne $candidate.content.parts) {
                            $incomingParts = @($candidate.content.parts)
                        }
                        for ($partIndex = 0; $partIndex -lt $incomingParts.Count; $partIndex++) {
                            $incomingPart = $incomingParts[$partIndex]
                            if ($null -eq $incomingPart) { continue }

                            $incomingCallMap = $null
                            if ($null -ne $incomingPart.functionCall) {
                                $incomingCallMap = & $ConvertCall $incomingPart.functionCall
                            }

                            if ($null -ne $incomingCallMap) {
                                $existingPartIndex = -1
                                $incomingCallId = [string]$incomingCallMap.id
                                if (-not [string]::IsNullOrWhiteSpace($incomingCallId)) {
                                    for ($existingIndex = 0; $existingIndex -lt $ParseState.Candidate.content.parts.Count; $existingIndex++) {
                                        $existingPart = $ParseState.Candidate.content.parts[$existingIndex]
                                        if ($null -ne $existingPart.functionCall -and [string]$existingPart.functionCall.id -eq $incomingCallId) {
                                            $existingPartIndex = $existingIndex
                                            break
                                        }
                                    }
                                } elseif ($ParseState.AnonymousCalls.ContainsKey($partIndex)) {
                                    $existingPartIndex = [int]$ParseState.AnonymousCalls[$partIndex]
                                }

                                if ($existingPartIndex -ge 0) {
                                    $existingPart = $ParseState.Candidate.content.parts[$existingPartIndex]
                                    $existingCall = $existingPart.functionCall
                                    if ($existingCall -isnot [System.Collections.IDictionary]) {
                                        $existingCall = & $ConvertCall $existingCall
                                    }
                                    foreach ($callField in @('id','name')) {
                                        if (-not [string]::IsNullOrWhiteSpace([string]$incomingCallMap[$callField])) {
                                            $existingCall[$callField] = $incomingCallMap[$callField]
                                        }
                                    }
                                    if ($existingCall.args -isnot [System.Collections.IDictionary]) {
                                        $existingCall.args = @{}
                                    }
                                    foreach ($argKey in $incomingCallMap.args.Keys) {
                                        $existingCall.args[[string]$argKey] = $incomingCallMap.args[$argKey]
                                    }
                                    $existingPart.functionCall = $existingCall
                                    if (-not [string]::IsNullOrWhiteSpace([string]$incomingPart.thoughtSignature)) {
                                        $existingPart.thoughtSignature = [string]$incomingPart.thoughtSignature
                                    }
                                } else {
                                    $partCopy = @{}
                                    if ($incomingPart -is [System.Collections.IDictionary]) {
                                        foreach ($partKey in $incomingPart.Keys) { $partCopy[[string]$partKey] = $incomingPart[$partKey] }
                                    } else {
                                        foreach ($partProperty in $incomingPart.PSObject.Properties) { $partCopy[$partProperty.Name] = $partProperty.Value }
                                    }
                                    $partCopy.functionCall = $incomingCallMap
                                    if ([string]::IsNullOrWhiteSpace($incomingCallId)) {
                                        $ParseState.AnonymousCalls[$partIndex] = $ParseState.Candidate.content.parts.Count
                                    }
                                    [void]$ParseState.Candidate.content.parts.Add($partCopy)
                                }
                                $ParseState.HasToolCall = $true
                            } else {
                                # Text fragments remain separate response parts, as
                                # Gemini streams them. Only function-call fragments
                                # are coalesced for tool execution/history.
                                $partCopy = @{}
                                if ($incomingPart -is [System.Collections.IDictionary]) {
                                    foreach ($partKey in $incomingPart.Keys) { $partCopy[[string]$partKey] = $incomingPart[$partKey] }
                                } else {
                                    foreach ($partProperty in $incomingPart.PSObject.Properties) { $partCopy[$partProperty.Name] = $partProperty.Value }
                                }
                                [void]$ParseState.Candidate.content.parts.Add($partCopy)
                            }

                            $isThought = [bool]$incomingPart.thought
                            if ($isThought) { $ParseState.HasThoughts = $true }
                            if (-not $isThought -and -not [string]::IsNullOrEmpty([string]$incomingPart.text)) {
                                $ParseState.HasResponseText = $true
                            }

                            if (-not [string]::IsNullOrEmpty([string]$incomingPart.text) -and (-not $isThought -or $IncludeThoughts)) {
                                if ($isThought -and -not $ParseState.LastPartWasThought) {
                                    & $EmitText '[Thought summary]' $CurrentAttempt
                                    & $EmitText ([string][char]10) $CurrentAttempt
                                }
                                & $EmitText ([string]$incomingPart.text) $CurrentAttempt
                            }
                            $ParseState.LastPartWasThought = $isThought
                        }
                    }

                    for ($keyOffset = 0; $keyOffset -lt $keyCount; $keyOffset++) {
                        $keyIndex = if ($providerName -eq 'gemini') { ($keyStart + $keyOffset) % $keyCount } else { -1 }
                        for ($attempt = 0; $attempt -lt 4; $attempt++) {
                            $requestStats.HttpAttempts = [int]$requestStats.HttpAttempts + 1
                            $requestStats.LastKeyIndex = $keyIndex
                            $requestStats.KeyCount = $keyCount
                            if ($keyIndex -ge 0 -and -not $requestStats.KeySlotsTried.Contains($keyIndex + 1)) {
                                [void]$requestStats.KeySlotsTried.Add($keyIndex + 1)
                            }
                            $httpRequest = $null
                            $httpResponse = $null
                            $sseReader = $null
                            try {
                                $retryState.ReplayLimit = $retryState.Text.Length
                                $retryState.ReplayOffset = 0
                                $parseState = @{
                                    Candidate = @{
                                        content = @{
                                            role = 'model'
                                            parts = [System.Collections.ArrayList]::new()
                                        }
                                        finishReason = ''
                                        finishMessage = ''
                                        groundingMetadata = $null
                                    }
                                    AnonymousCalls = @{}
                                    Usage = $null
                                    HasToolCall = $false
                                    HasThoughts = $false
                                    HasResponseText = $false
                                    LastPartWasThought = $false
                                }

                                $httpRequest = [System.Net.HttpWebRequest]::Create($u)
                                $httpRequest.Method = 'POST'
                                $httpRequest.ContentType = 'application/json; charset=utf-8'
                                $httpRequest.Accept = 'text/event-stream'
                                $httpRequest.Timeout = 180000
                                $httpRequest.ReadWriteTimeout = 180000
                                $httpRequest.ContentLength = [long]$b.Length
                                $httpRequest.AllowReadStreamBuffering = $false

                                if ($providerName -eq 'gemini') {
                                    $httpRequest.Headers['x-goog-api-key'] = [string]$keyPool[$keyIndex]
                                } else {
                                    foreach ($headerName in $h.Keys) {
                                        if ([string]$headerName -ieq 'User-Agent') {
                                            $httpRequest.UserAgent = [string]$h[$headerName]
                                        } elseif ([string]$headerName -ieq 'Authorization') {
                                            $httpRequest.Headers['Authorization'] = [string]$h[$headerName]
                                        } elseif ([string]$headerName -ieq 'Accept' -or [string]$headerName -ieq 'Content-Type') {
                                            continue
                                        } else {
                                            $httpRequest.Headers[[string]$headerName] = [string]$h[$headerName]
                                        }
                                    }
                                }
                                $streamState.Request = $httpRequest

                                $requestStream = $httpRequest.GetRequestStream()
                                try { $requestStream.Write($b, 0, $b.Length) }
                                finally { $requestStream.Dispose() }

                                $httpResponse = $httpRequest.GetResponse()
                                if ([int]$httpResponse.StatusCode -ge 300) {
                                    throw "Google streaming endpoint returned HTTP $([int]$httpResponse.StatusCode) $($httpResponse.StatusDescription)"
                                }
                                $responseStream = $httpResponse.GetResponseStream()
                                $sseReader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8, $true)
                                $eventData = New-Object 'System.Collections.Generic.List[string]'

                                while (($sseLine = $sseReader.ReadLine()) -ne $null) {
                                    if ($sseLine.Length -eq 0) {
                                        if ($eventData.Count -eq 0) { continue }
                                        $eventJson = [string]::Join(([string][char]10), $eventData.ToArray())
                                        $eventData.Clear()
                                        & $processGoogleEvent $eventJson $parseState $attempt $emitGoogleText $convertFunctionCall ([bool]$includeThoughts)
                                    } elseif ($sseLine.StartsWith(':')) {
                                        continue
                                    } elseif ($sseLine.StartsWith('data:')) {
                                        [void]$eventData.Add($sseLine.Substring(5).TrimStart())
                                    }
                                }
                                if ($eventData.Count -gt 0) {
                                    $eventJson = [string]::Join(([string][char]10), $eventData.ToArray())
                                    $eventData.Clear()
                                    & $processGoogleEvent $eventJson $parseState $attempt $emitGoogleText $convertFunctionCall ([bool]$includeThoughts)
                                }

                                $streamParts = @($parseState.Candidate.content.parts)
                                if ($streamParts.Count -eq 0) {
                                    throw 'Google streaming response ended without candidate content.'
                                }
                                if (-not $parseState.HasToolCall -and -not $parseState.HasResponseText) {
                                    if ($parseState.HasThoughts) {
                                        throw 'Google streaming response contained thought summaries but no final response text.'
                                    }
                                    if ([string]$parseState.Candidate.finishReason -match '(?i)MAX_TOKENS') {
                                        throw 'Google streaming response reached MAX_TOKENS without response text.'
                                    }
                                    throw 'Google streaming response finished without response text or function calls.'
                                }

                                $completedResponse = [pscustomobject]@{
                                    candidates = @($parseState.Candidate)
                                    usageMetadata = $parseState.Usage
                                }
                                if ($providerName -eq 'gemini') {
                                    return ($completedResponse | Add-Member -NotePropertyName _gemmaKeyIndex -NotePropertyValue $keyIndex -Force -PassThru)
                                }
                                return [pscustomobject]@{ response = $completedResponse }
                            } catch {
                                $failure = $_
                                $responseObject = $failure.Exception.Response
                                $status = 0
                                $retryAfter = 0
                                $errorBody = ''
                                $errorReason = ''
                                if ($null -ne $responseObject) {
                                    try { $status = [int]$responseObject.StatusCode } catch {}
                                    try { [void][int]::TryParse([string]$responseObject.Headers['Retry-After'],[ref]$retryAfter) } catch {}
                                    try {
                                        $errorStream = $responseObject.GetResponseStream()
                                        if ($null -ne $errorStream) {
                                            $errorReader = New-Object System.IO.StreamReader($errorStream)
                                            $errorBody = $errorReader.ReadToEnd()
                                            $errorReader.Dispose()
                                            $errorStream.Dispose()
                                        }
                                    } catch {}
                                    try { $responseObject.Close() } catch {}
                                }
                                try {
                                    $errorObject = $errorBody | ConvertFrom-Json -ErrorAction Stop
                                    $errorReason = [string]$errorObject.error.status
                                    if ([string]::IsNullOrWhiteSpace($errorReason)) { $errorReason = [string]$errorObject.error.code }
                                } catch {}
                                $lastFailure = "HTTP $status $errorReason $($failure.Exception.Message) $errorBody"

                                if ($status -eq 429 -and $errorReason -match '(?i)BILLING_DISABLED') {
                                    throw $lastFailure
                                }
                                $invalidGeminiKey = ($status -eq 401 -or
                                    ($status -in @(400,403) -and
                                        ($errorReason -match '(?i)PERMISSION_DENIED|API_KEY_INVALID|API_KEY_SERVICE_BLOCKED' -or
                                         $errorBody -match '(?i)api.?key|permission denied')))
                                if ($providerName -eq 'gemini' -and $invalidGeminiKey) {
                                    if ($keyOffset -lt ($keyCount - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($status -eq 403) { throw $lastFailure }

                                $failureMessage = [string]$failure.Exception.Message
                                $transient = ($status -in @(408,429,499,500,502,503,504)) -or
                                    ($status -eq 0 -and $failureMessage -match '(?i)timeout|connection reset|connection aborted|connection closed|underlying connection was closed|unable to read data from the transport connection|unexpected end|unexpected eof|unexpected error occurred on a receive|broken pipe|name resolution|forcibly closed|stream reset|goaway')
                                if (-not $transient) { throw $lastFailure }
                                if ($attempt -ge 3) {
                                    if ($keyOffset -lt ($keyCount - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($retryAfter -gt 0) {
                                    if ($retryAfter -gt 60) { throw "Google Retry-After is $retryAfter seconds; deferring request. $lastFailure" }
                                    $delay = $retryAfter
                                } else {
                                    $delay = [Math]::Min(8,[Math]::Pow(2,$attempt))
                                }
                                Start-Sleep -Seconds ([int]$delay)
                            } finally {
                                if ($null -ne $sseReader) { try { $sseReader.Dispose() } catch {} }
                                if ($null -ne $httpResponse) { try { $httpResponse.Close() } catch {} }
                                if ($null -ne $httpRequest) { try { $httpRequest.Abort() } catch {} }
                                if ($null -ne $streamState) { $streamState.Request = $null }
                            }
                        }
                    }
                    throw "Google streaming request failed with all available credentials. $lastFailure"
                }
                if ($providerName -eq 'gemini') {
                    $lastFailure = ''
                    for ($keyOffset = 0; $keyOffset -lt $keyPool.Count; $keyOffset++) {
                        $keyIndex = ($keyStart + $keyOffset) % $keyPool.Count
                        $keyHeaders = @{ 'x-goog-api-key' = [string]$keyPool[$keyIndex] }
                        for ($attempt = 0; $attempt -lt 3; $attempt++) {
                            $requestStats.HttpAttempts = [int]$requestStats.HttpAttempts + 1
                            $requestStats.LastKeyIndex = $keyIndex
                            $requestStats.KeyCount = $keyPool.Count
                            if (-not $requestStats.KeySlotsTried.Contains($keyIndex + 1)) {
                                [void]$requestStats.KeySlotsTried.Add($keyIndex + 1)
                            }
                            try { $successResponse = Invoke-RestMethod -Uri $u -Method Post -Headers $keyHeaders -ContentType 'application/json; charset=utf-8' -Body $b -TimeoutSec 180 -ErrorAction Stop; return ($successResponse | Add-Member -NotePropertyName _gemmaKeyIndex -NotePropertyValue $keyIndex -Force -PassThru) }
                            catch {
                                $failure = $_; $response = $failure.Exception.Response; $status = 0; $retryAfter = 0; $bodyText = ''; $reason = ''
                                if ($null -ne $response) {
                                    try { $status = [int]$response.StatusCode } catch {}
                                    try { [void][int]::TryParse([string]$response.Headers['Retry-After'],[ref]$retryAfter) } catch {}
                                    try {
                                        $stream = $response.GetResponseStream()
                                        if ($null -ne $stream) { $reader = New-Object System.IO.StreamReader($stream); $bodyText = $reader.ReadToEnd(); $reader.Dispose(); $stream.Dispose() }
                                    } catch {}
                                }
                                try { $parsedError = $bodyText | ConvertFrom-Json -ErrorAction Stop; $reason = [string]$parsedError.error.status } catch {}
                                $lastFailure = "HTTP $status $reason $($failure.Exception.Message) $bodyText"
                                if ($status -eq 401 -or ($status -eq 403 -and ($reason -match '(?i)PERMISSION_DENIED|API_KEY_INVALID|API_KEY_SERVICE_BLOCKED' -or $bodyText -match '(?i)api.?key|permission denied'))) {
                                    if ($keyOffset -lt ($keyPool.Count - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($status -eq 403) { throw $lastFailure }
                                if ($status -eq 429 -and $reason -match '(?i)BILLING_DISABLED|QUOTA_EXCEEDED|RESOURCE_EXHAUSTED') {
                                    if ($reason -match '(?i)BILLING_DISABLED') { throw $lastFailure }
                                }
                                $transient = ($status -in @(0,408,429,500,502,503,504)) -or ([string]$failure.Exception.Message -match '(?i)timeout|connection reset|connection closed|name resolution')
                                if (-not $transient) { throw $lastFailure }
                                if ($attempt -ge 2) {
                                    if ($keyOffset -lt ($keyPool.Count - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($retryAfter -gt 0) { if ($retryAfter -gt 60) { throw "Gemini Retry-After is $retryAfter seconds; deferring request. $lastFailure" }; $delay = $retryAfter }
                                else { $delay = [Math]::Min(8,[Math]::Pow(2,$attempt)) }
                                Start-Sleep -Seconds ([int]$delay)
                            }
                        }
                    }
                    throw "Gemini request failed with all configured API keys. $lastFailure"
                }
                if ($providerName -eq 'openai') {
                    $lastFailure = ''
                    $openAIReplayState = @{ Text = ''; ReplayLimit = 0; ReplayOffset = 0 }
                    $emitOpenAIText = {
                        param([string]$Value)
                        if ([string]::IsNullOrEmpty($Value)) { return }
                        if ($openAIReplayState.ReplayLimit -gt 0 -and $openAIReplayState.ReplayOffset -lt $openAIReplayState.ReplayLimit) {
                            $matched = 0
                            while ($matched -lt $Value.Length -and
                                   $openAIReplayState.ReplayOffset -lt $openAIReplayState.ReplayLimit -and
                                   $Value[$matched] -ceq $openAIReplayState.Text[$openAIReplayState.ReplayOffset]) {
                                $matched++
                                $openAIReplayState.ReplayOffset++
                            }
                            if ($matched -gt 0) { $Value = $Value.Substring($matched) }
                            if ($Value.Length -gt 0 -and $openAIReplayState.ReplayOffset -lt $openAIReplayState.ReplayLimit) {
                                # The regenerated prefix diverged; keep the visible
                                # first attempt and append only the new suffix.
                                $openAIReplayState.ReplayOffset = $openAIReplayState.ReplayLimit
                            }
                        }
                        if (-not [string]::IsNullOrEmpty($Value)) {
                            $openAIReplayState.Text += $Value
                            $streamState.TextStarted = $true
                            $streamQueue.Enqueue($Value)
                        }
                    }
                    for ($keyOffset = 0; $keyOffset -lt $keyPool.Count; $keyOffset++) {
                        $keyIndex = ($keyStart + $keyOffset) % $keyPool.Count
                        $authHeaders = @{ Authorization = ('Bearer ' + [string]$keyPool[$keyIndex]) }
                        for ($attempt = 0; $attempt -lt 3; $attempt++) {
                            $requestStats.ErrorCode = ''
                            $requestStats.ErrorType = ''
                            $requestStats.StreamEventType = ''
                            $requestStats.ErrorMessage = ''
                            if ($openAIReplayState.Text.Length -gt 0) {
                                $openAIReplayState.ReplayLimit = $openAIReplayState.Text.Length
                                $openAIReplayState.ReplayOffset = 0
                            }
                            $requestStats.HttpAttempts = [int]$requestStats.HttpAttempts + 1
                            $requestStats.LastKeyIndex = $keyIndex
                            $requestStats.KeyCount = $keyPool.Count
                            if (-not $requestStats.KeySlotsTried.Contains($keyIndex + 1)) {
                                [void]$requestStats.KeySlotsTried.Add($keyIndex + 1)
                            }
                            $httpResponse = $null
                            $httpRequest = $null
                            $sseReader = $null
                            try {
                                if (-not $streamResponses) {
                                    $httpRequest = [System.Net.HttpWebRequest]::Create($u)
                                    $httpRequest.Method = 'POST'
                                    $httpRequest.ContentType = 'application/json; charset=utf-8'
                                    $httpRequest.Accept = 'application/json'
                                    $httpRequest.Headers['Authorization'] = ('Bearer ' + [string]$keyPool[$keyIndex])
                                    $httpRequest.Timeout = 180000
                                    $httpRequest.ReadWriteTimeout = 180000
                                    $httpRequest.ContentLength = [long]$b.Length
                                    $requestStream = $httpRequest.GetRequestStream()
                                    try { $requestStream.Write($b,0,$b.Length) }
                                    finally { $requestStream.Dispose() }
                                    $httpResponse = $httpRequest.GetResponse()
                                    $requestStats.HttpStatus = [int]$httpResponse.StatusCode
                                    $requestStats.RateLimitHeaders = & $getOpenAIRateHeaders $httpResponse.Headers
                                    $requestStats.RequestId = [string]$httpResponse.Headers['x-request-id']
                                    $responseStream = $httpResponse.GetResponseStream()
                                    $responseReader = New-Object System.IO.StreamReader($responseStream,[System.Text.Encoding]::UTF8,$true)
                                    $responseText = $responseReader.ReadToEnd()
                                    $responseReader.Dispose()
                                    $successResponse = $responseText | ConvertFrom-Json -ErrorAction Stop
                                    if ([string]$successResponse.status -eq 'failed' -or $null -ne $successResponse.error) {
                                        if ($null -ne $successResponse.error) {
                                            $requestStats.ErrorCode = [string]$successResponse.error.code
                                            $requestStats.ErrorType = [string]$successResponse.error.type
                                            $requestStats.ErrorMessage = [string]$successResponse.error.message
                                        }
                                        if ([string]::IsNullOrWhiteSpace([string]$requestStats.ErrorCode) -and
                                            [string]$requestStats.ErrorMessage -match '(?i)rate limit reached|tokens per minute|tokens per min') {
                                            $requestStats.ErrorCode = 'rate_limit_exceeded'
                                        }
                                        throw ("OpenAI Responses request failed: " + [string]$requestStats.ErrorMessage)
                                    }
                                    return ($successResponse | Add-Member -NotePropertyName _gemmaKeyIndex -NotePropertyValue $keyIndex -Force -PassThru)
                                }

                                # PowerShell 5.1 has no native SSE client. Read the
                                # Responses event stream directly from HttpWebRequest.
                                $httpRequest = [System.Net.HttpWebRequest]::Create($u)
                                $httpRequest.Method = 'POST'
                                $httpRequest.ContentType = 'application/json; charset=utf-8'
                                $httpRequest.Accept = 'text/event-stream'
                                $httpRequest.Headers['Authorization'] = ('Bearer ' + [string]$keyPool[$keyIndex])
                                $httpRequest.Timeout = 180000
                                $httpRequest.ReadWriteTimeout = 180000
                                $httpRequest.ContentLength = [long]$b.Length
                                $httpRequest.AllowReadStreamBuffering = $false
                                $streamState.Request = $httpRequest

                                $requestStream = $httpRequest.GetRequestStream()
                                try { $requestStream.Write($b, 0, $b.Length) }
                                finally { $requestStream.Dispose() }

                                $httpResponse = $httpRequest.GetResponse()
                                $requestStats.HttpStatus = [int]$httpResponse.StatusCode
                                $requestStats.RateLimitHeaders = & $getOpenAIRateHeaders $httpResponse.Headers
                                $requestStats.RequestId = [string]$httpResponse.Headers['x-request-id']
                                $responseStream = $httpResponse.GetResponseStream()
                                $sseReader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8, $true)
                                $eventData = New-Object 'System.Collections.Generic.List[string]'
                                $completedResponse = $null

                                while (($sseLine = $sseReader.ReadLine()) -ne $null) {
                                    if ($sseLine.Length -eq 0) {
                                        if ($eventData.Count -eq 0) { continue }
                                        $eventJson = [string]::Join("`n", $eventData.ToArray())
                                        $eventData.Clear()
                                        if ($eventJson -eq '[DONE]') { continue }

                                        try { $sseEvent = $eventJson | ConvertFrom-Json -ErrorAction Stop }
                                        catch { throw "OpenAI returned malformed Responses SSE data: $($_.Exception.Message)" }

                                        $eventType = [string]$sseEvent.type
                                        if ($eventType -eq 'response.output_text.delta' -or $eventType -eq 'response.refusal.delta') {
                                            $deltaText = [string]$sseEvent.delta
                                            if (-not [string]::IsNullOrEmpty($deltaText)) {
                                                & $emitOpenAIText $deltaText
                                            }
                                        } elseif ($eventType -eq 'response.completed') {
                                            $completedResponse = $sseEvent.response
                                            break
                                        } elseif ($eventType -eq 'response.failed' -or $eventType -eq 'response.incomplete' -or $eventType -eq 'error') {
                                            $streamError = ''
                                            $streamErrorCode = ''
                                            $streamErrorType = ''
                                            $streamErrorObject = $null
                                            if ($null -ne $sseEvent.response -and $null -ne $sseEvent.response.error) {
                                                $streamErrorObject = $sseEvent.response.error
                                            } elseif ($null -ne $sseEvent.error) {
                                                $streamErrorObject = $sseEvent.error
                                            }
                                            if ($null -ne $streamErrorObject) {
                                                $streamError = [string]$streamErrorObject.message
                                                $streamErrorCode = [string]$streamErrorObject.code
                                                $streamErrorType = [string]$streamErrorObject.type
                                            }
                                            if ([string]::IsNullOrWhiteSpace($streamError) -and $null -ne $sseEvent.response.incomplete_details) {
                                                $streamError = [string]$sseEvent.response.incomplete_details.reason
                                            }
                                            if ([string]::IsNullOrWhiteSpace($streamError)) { $streamError = $eventJson }
                                            if ([string]::IsNullOrWhiteSpace($streamErrorCode)) {
                                                if ($streamError -match '(?i)rate limit reached|tokens per minute|tokens per min|requests per minute|requests per min') {
                                                    $streamErrorCode = 'rate_limit_exceeded'
                                                } elseif ($streamError -match '(?i)invalid api key|incorrect api key') {
                                                    $streamErrorCode = 'invalid_api_key'
                                                } elseif ($streamError -match '(?i)credit balance exhausted') {
                                                    $streamErrorCode = 'credit_balance_exhausted'
                                                } elseif ($streamError -match '(?i)insufficient quota') {
                                                    $streamErrorCode = 'insufficient_quota'
                                                }
                                            }
                                            $requestStats.StreamEventType = $eventType
                                            $requestStats.ErrorCode = $streamErrorCode
                                            $requestStats.ErrorType = $streamErrorType
                                            $requestStats.ErrorMessage = $streamError
                                            throw "OpenAI Responses stream failed: $streamError"
                                        }
                                    } elseif ($sseLine.StartsWith('data:')) {
                                        [void]$eventData.Add($sseLine.Substring(5).TrimStart())
                                    }
                                }

                                if ($null -eq $completedResponse) {
                                    throw 'OpenAI Responses stream ended before response.completed.'
                                }
                                if ([string]$completedResponse.status -ne 'completed') {
                                    $incompleteReason = ''
                                    if ($null -ne $completedResponse.incomplete_details) {
                                        $incompleteReason = [string]$completedResponse.incomplete_details.reason
                                    }
                                    if ($null -ne $completedResponse.error -and $completedResponse.error.message) {
                                        $incompleteReason = [string]$completedResponse.error.message
                                    }
                                    throw "OpenAI Responses stream finished with status '$($completedResponse.status)'. $incompleteReason"
                                }

                                return ($completedResponse | Add-Member -NotePropertyName _gemmaKeyIndex -NotePropertyValue $keyIndex -Force -PassThru)
                            } catch {
                                $failure = $_
                                $response = $failure.Exception.Response
                                if ($null -eq $response -and $null -ne $httpResponse) { $response = $httpResponse }
                                $status = 0; $retryAfter = 0; $errorCode = ''; $errorBody = ''
                                if ($null -ne $response) {
                                    try { $status = [int]$response.StatusCode } catch {}
                                    $requestStats.HttpStatus = $status
                                    try {
                                        $requestStats.RateLimitHeaders = & $getOpenAIRateHeaders $response.Headers
                                        $requestStats.RequestId = [string]$response.Headers['x-request-id']
                                    } catch {}
                                    try { [void][int]::TryParse([string]$response.Headers['Retry-After'],[ref]$retryAfter) } catch {}
                                    try {
                                        if ($null -ne $failure.Exception.Response) {
                                            $errorStream = $response.GetResponseStream()
                                            if ($null -ne $errorStream) {
                                                $errorReader = New-Object System.IO.StreamReader($errorStream)
                                                $errorBody = $errorReader.ReadToEnd()
                                                $errorReader.Dispose(); $errorStream.Dispose()
                                            }
                                        }
                                    } catch {}
                                }
                                try {
                                    $httpError = $errorBody | ConvertFrom-Json -ErrorAction Stop
                                    if ([string]::IsNullOrWhiteSpace([string]$requestStats.ErrorCode)) {
                                        $requestStats.ErrorCode = [string]$httpError.error.code
                                    }
                                    if ([string]::IsNullOrWhiteSpace([string]$requestStats.ErrorType)) {
                                        $requestStats.ErrorType = [string]$httpError.error.type
                                    }
                                } catch {}
                                $errorCode = [string]$requestStats.ErrorCode
                                $errorType = [string]$requestStats.ErrorType
                                $errorMessage = [string]$requestStats.ErrorMessage
                                if ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = [string]$failure.Exception.Message }
                                if ([string]::IsNullOrWhiteSpace($errorCode)) {
                                    if ($errorMessage -match '(?i)rate limit reached|tokens per minute|tokens per min|requests per minute|requests per min') {
                                        $errorCode = 'rate_limit_exceeded'
                                    } elseif ($errorMessage -match '(?i)invalid api key|incorrect api key') {
                                        $errorCode = 'invalid_api_key'
                                    } elseif ($errorMessage -match '(?i)credit balance exhausted') {
                                        $errorCode = 'credit_balance_exhausted'
                                    } elseif ($errorMessage -match '(?i)insufficient quota') {
                                        $errorCode = 'insufficient_quota'
                                    }
                                    $requestStats.ErrorCode = $errorCode
                                }
                                $lastFailure = "HTTP $status $errorCode $($failure.Exception.Message) $errorBody"
                                if ([string]::IsNullOrWhiteSpace([string]$requestStats.ErrorMessage)) { $requestStats.ErrorMessage = $lastFailure }

                                # These failures belong to a key/account/project candidate:
                                # try the next explicitly configured key immediately.
                                $rotateKey = ($keyRotationErrorCodes -contains $errorCode.ToLowerInvariant()) -or
                                    ($status -eq 401) -or
                                    ($status -eq 403 -and ($errorType -match '(?i)permission' -or
                                        $errorCode -match '(?i)permission|access|api_key' -or
                                        $errorMessage -match '(?i)api.?key|permission denied'))
                                if ($rotateKey) {
                                    if ($keyOffset -lt ($keyPool.Count - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($status -eq 403) { throw $lastFailure }

                                # Transient service/ramp-limit errors retry the same key first.
                                # The replay buffer suppresses text already shown to the user.
                                $retryErrorCodes = @('rate_limit_error','slow_down','server_error','server_overloaded','server_is_overloaded','internal_server_error','service_unavailable_error')
                                $transient = ($status -in @(0,408,409,429,500,502,503,504)) -or
                                    ($retryErrorCodes -contains $errorCode.ToLowerInvariant()) -or
                                    ($retryErrorCodes -contains $errorType.ToLowerInvariant()) -or
                                    ([string]$failure.Exception.Message -match '(?i)timeout|connection reset|connection closed|name resolution|stream ended before response.completed|unexpected end|unexpected eof')
                                if (-not $transient) { throw $lastFailure }
                                if ($attempt -ge 2) {
                                    if ($keyOffset -lt ($keyPool.Count - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($retryAfter -gt 0) {
                                    if ($retryAfter -gt 60) { throw "OpenAI Retry-After is $retryAfter seconds; deferring request. $lastFailure" }
                                    $delay = $retryAfter
                                } else { $delay = [Math]::Min(8,[Math]::Pow(2,$attempt)) }
                                Start-Sleep -Seconds ([int]$delay)
                            } finally {
                                if ($null -ne $sseReader) { try { $sseReader.Dispose() } catch {} }
                                if ($null -ne $httpResponse) { try { $httpResponse.Close() } catch {} }
                                if ($null -ne $httpRequest) { try { $httpRequest.Abort() } catch {} }
                                if ($null -ne $streamState) { $streamState.Request = $null }
                            }
                        }
                    }
                    throw "OpenAI request failed with all configured API keys. $lastFailure"
                }
                for ($attempt = 0; $attempt -lt 4; $attempt++) {
                    $requestStats.HttpAttempts = [int]$requestStats.HttpAttempts + 1
                    try { return Invoke-RestMethod -Uri $u -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body $b -TimeoutSec 180 -ErrorAction Stop }
                    catch {
                        $failure = $_; $response = $failure.Exception.Response; $status = 0; $retryAfter = 0
                        if ($null -ne $response) {
                            try { $status = [int]$response.StatusCode } catch {}
                            try { [void][int]::TryParse([string]$response.Headers['Retry-After'],[ref]$retryAfter) } catch {}
                        }
                        $message = [string]$failure.Exception.Message
                        $transient = ($status -in @(408,429,500,502,503,504)) -or ($message -match '(?i)timeout|temporarily unavailable|connection reset|connection closed|name resolution')
                        if (-not $transient -or $attempt -ge 3) { throw }
                        if ($retryAfter -gt 0) { $delay = [Math]::Min(30,$retryAfter) } else { $delay = [Math]::Min(12,2 * [Math]::Pow(2,$attempt)) }
                        Start-Sleep -Seconds ([int]$delay)
                    }
                }
            }).AddArgument($url).AddArgument($utf8Bytes).AddArgument($requestHeaders).AddArgument($requestApiKeys).AddArgument($requestKeyIndex).AddArgument($requestProviderName).AddArgument([bool]$streamOpenAIResponses).AddArgument($streamQueue).AddArgument($streamState).AddArgument([bool]$streamGoogle).AddArgument([bool]$script:VerboseOutput).AddArgument($requestStats).AddArgument(@($script:OpenAIKeyRotationErrorCodes))
            $asyncResult = $powershell.BeginInvoke()

            $cancelled = $false
            $streamTextThisRequest = $false
            $streamDelta = ''
            $streamDisplayState = @{
                Mode = $streamMode
                LineBuffer = ''
                OutputText = ''
                HasOutput = $false
                LastChar = [char]0
                CommandMode = [bool]$script:CommandMode
                ShowFrame = (-not $script:CommandMode -and -not $script:OneShot)
                HeaderDrawn = $false
                HeaderLeft = 0
                HeaderTop = -1
            }
            $writeStreamFrameHeader = {
                if (-not $streamDisplayState.ShowFrame -or $streamDisplayState.HeaderDrawn) { return }

                # Clear the request spinner, then put the frame header above
                # the first visible streamed text (the old non-streaming layout).
                Write-Host (" " * 60) -NoNewline
                Write-Host ([string][char]13) -NoNewline

                try { $frameWidth = [Console]::WindowWidth }
                catch { $frameWidth = $Host.UI.RawUI.WindowWidth }
                if ($frameWidth -le 10) { $frameWidth = 80 }
                $headerWidth = [Math]::Max(1,$frameWidth - 1)
                $headerElapsed = ([Math]::Round($turnStopwatch.Elapsed.TotalSeconds,1)).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)
                $headerLeft = ([string][char]0x250C) + ([string][char]0x2500 * 2) + ' ' + $headerElapsed + 's'
                $headerModel = [string]$script:MODEL
                $headerRight = 'STREAMING'
                $headerFixed = $headerLeft.Length + $headerRight.Length + 2
                $headerMaxModel = [Math]::Max(1,$headerWidth - $headerFixed - 2)
                if ($headerModel.Length -gt $headerMaxModel) {
                    if ($headerMaxModel -gt 3) { $headerModel = $headerModel.Substring(0,$headerMaxModel - 3) + '...' }
                    else { $headerModel = $headerModel.Substring(0,$headerMaxModel) }
                }
                $headerGap = $headerWidth - $headerLeft.Length - $headerModel.Length - $headerRight.Length - 2
                if ($headerGap -lt 1) { $headerGap = 1 }
                $headerLine = $headerLeft + (' ' * $headerGap) + $headerModel + '  ' + $headerRight
                if ($headerLine.Length -gt $headerWidth) { $headerLine = $headerLine.Substring(0,$headerWidth) }

                try {
                    $streamDisplayState.HeaderLeft = [Console]::CursorLeft
                    $streamDisplayState.HeaderTop = [Console]::CursorTop
                } catch {
                    $streamDisplayState.HeaderTop = -1
                }
                Write-Host $headerLine -ForegroundColor DarkGray
                $streamDisplayState.HeaderDrawn = $true
            }
            $writeStreamChunk = {
                param([string]$Chunk)
                if ([string]::IsNullOrEmpty($Chunk)) { return }
                $Chunk = $Chunk.Replace(([string][char]9),'    ')
                $streamDisplayState.OutputText += $Chunk
                if ($streamDisplayState.Mode -eq 'delta') {
                    if (-not $streamDisplayState.HasOutput) {
                        & $writeStreamFrameHeader
                        $streamDisplayState.HasOutput = $true
                    }
                    if ($streamDisplayState.CommandMode) {
                        [Console]::Out.Write($Chunk)
                        [Console]::Out.Flush()
                    } else {
                        Write-Host $Chunk -NoNewline -ForegroundColor Cyan
                    }
                    $streamDisplayState.LastChar = $Chunk[$Chunk.Length - 1]
                    return
                }

                $streamDisplayState.LineBuffer += $Chunk
                while (($newlineIndex = $streamDisplayState.LineBuffer.IndexOf([char]10)) -ge 0) {
                    $completeLine = $streamDisplayState.LineBuffer.Substring(0,$newlineIndex + 1)
                    $streamDisplayState.LineBuffer = $streamDisplayState.LineBuffer.Substring($newlineIndex + 1)
                    if (-not $streamDisplayState.HasOutput) {
                        & $writeStreamFrameHeader
                        $streamDisplayState.HasOutput = $true
                    }
                    if ($streamDisplayState.CommandMode) {
                        [Console]::Out.Write($completeLine)
                        [Console]::Out.Flush()
                    } else {
                        Write-Host $completeLine.TrimEnd([char]13,[char]10) -ForegroundColor Cyan
                    }
                    $streamDisplayState.LastChar = [char]10
                }
            }
            while (-not $asyncResult.IsCompleted) {
                if ($streamingActive -and $null -ne $streamQueue) {
                    while ($streamQueue.TryDequeue([ref]$streamDelta)) {
                        & $writeStreamChunk $streamDelta
                    }
                }
                if ($canReadConsoleKeys -and [Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                        $cancelled = $true
                        if ($streamState -and $null -ne $streamState.Request) {
                            try { $streamState.Request.Abort() } catch {}
                        }
                        Write-Host "`rStopping request...                                           " -NoNewline -ForegroundColor Yellow
                        try { $powershell.Stop() } catch {}
                        break
                    }
                }

                if (-not $streamDisplayState.HasOutput) {
                    $frame = $frames[$i % $frames.Length]
                    $elapsed = [int]$sw.ElapsedMilliseconds
                    Write-Host "`r$frame  $([math]::Round($elapsed/1000, 1))s " -NoNewline -ForegroundColor DarkGray
                    $i++
                }
                if ($streamDisplayState.HasOutput) { Start-Sleep -Milliseconds 25 }
                else { Start-Sleep -Milliseconds $MIRA_SPINNER_INTERVAL_MS }
            }

            # Drain the final chunks queued immediately before worker completion.
            if (-not $cancelled -and $streamingActive -and $null -ne $streamQueue) {
                while ($streamQueue.TryDequeue([ref]$streamDelta)) {
                    & $writeStreamChunk $streamDelta
                }
            }
            if (-not $cancelled -and $streamingActive -and
                $streamDisplayState.Mode -eq 'line' -and
                $streamDisplayState.LineBuffer.Length -gt 0) {
                if (-not $streamDisplayState.HasOutput) {
                    & $writeStreamFrameHeader
                    $streamDisplayState.HasOutput = $true
                }
                $remainingLine = $streamDisplayState.LineBuffer
                $streamDisplayState.LineBuffer = ''
                if ($streamDisplayState.CommandMode) {
                    [Console]::Out.Write($remainingLine)
                    [Console]::Out.WriteLine()
                    [Console]::Out.Flush()
                } else {
                    Write-Host $remainingLine -ForegroundColor Cyan
                }
                $streamDisplayState.LastChar = [char]10
            }
            if ($streamingActive -and $streamDisplayState.HasOutput -and
                [char]$streamDisplayState.LastChar -ne [char]10) {
                if ($streamDisplayState.CommandMode) {
                    [Console]::Out.WriteLine()
                    [Console]::Out.Flush()
                } else {
                    Write-Host ""
                }
                $streamDisplayState.LastChar = [char]10
            }
            $streamTextThisRequest = [bool]$streamDisplayState.HasOutput
            $sw.Stop()

            if ($cancelled) {
                try { $powershell.EndInvoke($asyncResult) | Out-Null }
                catch [Management.Automation.PipelineStoppedException] {}
                catch {}

                Rollback-MiraTurn -History $Contents -StartCount $turnStartCount

                Write-Host "`r" -NoNewline
                Write-Host (" " * 60) -NoNewline
                Write-Host "`r[Request cancelled]" -ForegroundColor Yellow

                $toolLoop = $false
                break
            }

            if (-not $streamTextThisRequest) {
                Write-Host (" " * 40) -NoNewline
                Write-Host "`r" -NoNewline
            }

            $response = $null
            $endInvokeFailure = $null
            try {
                $response = $powershell.EndInvoke($asyncResult)
            } catch {
                # EndInvoke throws on terminating HTTP errors before the error
                # stream can be inspected. Preserve the original exception.
                $endInvokeFailure = $_
            }
            $hasRunspaceError = ($null -ne $endInvokeFailure -or $powershell.Streams.Error.Count -gt 0)
            $runspaceErrors = @($powershell.Streams.Error)

            if ($hasRunspaceError) {
                if ($usingOpenAI -and $requestApiKeys.Count -gt 1 -and
                    $requestStats.KeySlotsTried.Count -gt 1 -and $requestStats.LastKeyIndex -ge 0) {
                    $script:MiraOpenAIApiKeyIndex = ($requestStats.LastKeyIndex + 1) % $requestApiKeys.Count
                }
                Add-GemmaUsageRecord -Provider $requestProviderName -Model ([string]$script:MODEL) -Succeeded $false -HttpAttempts ([int]$requestStats.HttpAttempts) -KeyIndex ([int]$requestStats.LastKeyIndex) -KeyCount ([int]$requestStats.KeyCount) -KeySlotsTried @($requestStats.KeySlotsTried.ToArray()) -RateLimitHeaders $requestStats.RateLimitHeaders -RequestId ([string]$requestStats.RequestId) -HttpStatus ([int]$requestStats.HttpStatus) -ErrorCode ([string]$requestStats.ErrorCode) -ErrorMessage ([string]$requestStats.ErrorMessage)
                if ($null -ne $endInvokeFailure) {
                    # EndInvoke may wrap the WebException in one or more
                    # MethodInvocationException/RuntimeException layers.
                    # Walk the full chain so HTTP status and response body are
                    # not lost (especially important for OpenAI 4xx responses).
                    $responseException = $endInvokeFailure.Exception
                    $responseObject = $null
                    $exceptionCursor = $responseException
                    while ($null -ne $exceptionCursor) {
                        if ($null -ne $exceptionCursor.Response) {
                            $responseObject = $exceptionCursor.Response
                            break
                        }
                        $exceptionCursor = $exceptionCursor.InnerException
                    }

                    if ($null -ne $responseObject) {
                        $failureStatus = 0
                        $failureBody = ''
                        try {
                            $failureStatus = [int]$responseObject.StatusCode
                            $failureStream = $responseObject.GetResponseStream()
                            if ($null -ne $failureStream) {
                                $failureReader = New-Object System.IO.StreamReader($failureStream)
                                $failureBody = $failureReader.ReadToEnd()
                                $failureReader.Dispose()
                                $failureStream.Dispose()
                            }
                        } catch {}
                        $requestProviderLabel = if ($usingAntigravityOAuth) { 'Antigravity' } elseif ($usingOpenAI) { 'OpenAI' } else { 'Gemini API' }
                        if ($failureBody) {
                            Write-Host ("[{0} API Failure]: HTTP {1}" -f $requestProviderLabel,$failureStatus) -ForegroundColor Red
                            Write-Host $failureBody -ForegroundColor Gray
                        } else {
                            Write-Host ("[{0} API Failure]: HTTP {1} {2}" -f $requestProviderLabel,$failureStatus,$responseException.Message) -ForegroundColor Red
                        }
                        throw "$requestProviderLabel request failed with HTTP $failureStatus."
                    }

                    if (($usingOpenAI -or $streamGoogle) -and $runspaceErrors.Count -gt 0) {
                        $workerError = [string]$runspaceErrors[$runspaceErrors.Count - 1].Exception.Message
                        if (-not [string]::IsNullOrWhiteSpace($workerError)) {
                            $workerLabel = if ($usingAntigravityOAuth) { 'Antigravity' } elseif ($usingOpenAI) { 'OpenAI' } else { 'Gemini' }
                            throw "$workerLabel API Failure: $workerError"
                        }
                    }
                    throw "HTTP/REST Error: $($responseException.Message)"
                }

                $err = $runspaceErrors[0]
                $webResp = $err.Exception.Response
                if ($null -ne $webResp) {
                    $status = [int]$webResp.StatusCode
                    $body = ""
                    try {
                        $stream = $webResp.GetResponseStream()
                        if ($stream) {
                            $reader = New-Object System.IO.StreamReader($stream)
                            $body = $reader.ReadToEnd()
                            $reader.Close(); $stream.Close()
                        }
                    } catch {}
                    Write-Host "`n[API Failure]: HTTP $status $($webResp.StatusDescription)" -ForegroundColor Red
                    if ($body) {
                        Write-Host "Google API response:" -ForegroundColor Yellow
                        Write-Host $body -ForegroundColor Gray
                        try {
                            $errorObject = $body | ConvertFrom-Json -ErrorAction Stop
                            $errorDetails = @($errorObject.error.details)
                            foreach ($detail in $errorDetails) {
                                if ($detail.reason) {
                                    Write-Host "[API error reason] $($detail.reason)" -ForegroundColor Yellow
                                }
                                if ($detail.metadata.model) {
                                    Write-Host "[API error model] $($detail.metadata.model)" -ForegroundColor Yellow
                                }
                                if ($detail.retryDelay) {
                                    Write-Host "[API retry delay] $($detail.retryDelay)" -ForegroundColor Yellow
                                }
                            }
                        } catch {
                            # Preserve the raw response above when it is not Google Error JSON.
                        }
                    } else {
                        Write-Host "Google API response: <empty>" -ForegroundColor Gray
                    }
                    try {
                        if ($webResp.Headers["Retry-After"]) {
                            Write-Host "Retry-After: $($webResp.Headers["Retry-After"])" -ForegroundColor Yellow
                        }
                    } catch {}
                } else {
                    throw "HTTP/REST Error: $($err.Exception.Message)"
                }

                throw "Gemini API request failed with HTTP $status."
            }

            if ($usingAntigravityOAuth) {
                if ($null -eq $response.response) { throw "Antigravity returned an invalid response envelope." }
                $response = $response.response
            } elseif ($usingOpenAI) {
                $usedKeyIndex = $requestKeyIndex
                if ($null -ne $response._gemmaKeyIndex) { $usedKeyIndex = [int]$response._gemmaKeyIndex }
                $script:MiraOpenAIApiKeyIndex = ($usedKeyIndex + 1) % $requestApiKeys.Count
                $requestStats.LastKeyIndex = $usedKeyIndex
                $requestStats.KeyCount = $requestApiKeys.Count
                if ($usingOpenAIResponses) {
                    $response = ConvertFrom-GemmaOpenAIResponsesResponse -OpenAIResponse $response
                } else {
                    $response = ConvertFrom-GemmaOpenAIResponse -OpenAIResponse $response
                }
            } elseif ($requestProviderName -eq 'gemini') {
                $usedKeyIndex = $requestKeyIndex
                if ($null -ne $response._gemmaKeyIndex) { $usedKeyIndex = [int]$response._gemmaKeyIndex }
                $script:MiraGeminiApiKeyIndex = ($usedKeyIndex + 1) % $requestApiKeys.Count
                $requestStats.LastKeyIndex = $usedKeyIndex
                $requestStats.KeyCount = $requestApiKeys.Count
            }

            if ($null -eq $response) {
                Add-GemmaUsageRecord -Provider $requestProviderName -Model ([string]$script:MODEL) -Succeeded $false -HttpAttempts ([int]$requestStats.HttpAttempts) -KeyIndex ([int]$requestStats.LastKeyIndex) -KeyCount ([int]$requestStats.KeyCount) -KeySlotsTried @($requestStats.KeySlotsTried.ToArray()) -RateLimitHeaders $requestStats.RateLimitHeaders -RequestId ([string]$requestStats.RequestId) -HttpStatus ([int]$requestStats.HttpStatus) -ErrorCode ([string]$requestStats.ErrorCode) -ErrorMessage ([string]$requestStats.ErrorMessage)
                throw "The API returned a null or empty response object."
            }

            # Accumulate provider-reported usage for each successful model/tool round.
            $roundPromptTokens = 0
            $roundCompletionTokens = 0
            if ($null -ne $response.usageMetadata) {
                if ($null -ne $response.usageMetadata.promptTokenCount) {
                    $roundPromptTokens = [int]$response.usageMetadata.promptTokenCount
                    $turnPromptTokens += $roundPromptTokens
                }
                if ($null -ne $response.usageMetadata.candidatesTokenCount) {
                    $roundCompletionTokens = [int]$response.usageMetadata.candidatesTokenCount
                    $turnCompletionTokens += $roundCompletionTokens
                }
            }
            if ([int]$requestStats.HttpStatus -le 0) { $requestStats.HttpStatus = 200 }
            Add-GemmaUsageRecord -Provider $requestProviderName -Model ([string]$script:MODEL) -Succeeded $true -InputTokens $roundPromptTokens -OutputTokens $roundCompletionTokens -HttpAttempts ([int]$requestStats.HttpAttempts) -KeyIndex ([int]$requestStats.LastKeyIndex) -KeyCount ([int]$requestStats.KeyCount) -KeySlotsTried @($requestStats.KeySlotsTried.ToArray()) -RateLimitHeaders $requestStats.RateLimitHeaders -RequestId ([string]$requestStats.RequestId) -HttpStatus ([int]$requestStats.HttpStatus) -ErrorMessage ([string]$requestStats.ErrorMessage)

            if ($null -eq $response.candidates -or $response.candidates.Count -eq 0) {
                if ($null -ne $response.error) {
                    throw "API Error JSON: $($response.error.message)"
                }
                throw "No candidates returned. Possible safety filter block or malformed context."
            }

            $content = $response.candidates[0].content
            if ($null -eq $content -or $null -eq $content.parts -or $content.parts.Count -eq 0) {
                $reason = $response.candidates[0].finishReason
                throw "Generation halted by API. Finish Reason: $reason"
            }

            # Preserve every returned part exactly, including functionCall,
            # ids and any other fields required by Gemini's tool context.
            $modelParts = @($content.parts)

            $functionCalls = @(
                $modelParts | Where-Object { $null -ne $_.functionCall } |
                    ForEach-Object { $_.functionCall }
            )

            if ($functionCalls.Count -gt 0) {
                $modelToolTurn = @{
                    role  = "model"
                    parts = $modelParts
                }
                if ($usingOpenAIResponses -and $null -ne $response.openaiOutputItems) {
                    $modelToolTurn.openaiOutputItems = @($response.openaiOutputItems)
                }
                [void]$Contents.Add($modelToolTurn)

                foreach ($call in $functionCalls) {
                    $toolName = [string]$call.name

                    $toolResult = Invoke-GemmaToolCall -Call $call


                    # Gemini function_response.response must be a JSON object
                    # (google.protobuf.Struct), never a bare string or scalar.
                    if ($null -eq $toolResult) {
                        $toolResponseValue = @{}
                    } elseif ($toolResult -is [System.Collections.IDictionary] -or
                              $toolResult -is [pscustomobject]) {
                        $toolResponseValue = $toolResult
                    } else {
                        $toolResponseValue = @{ result = $toolResult }
                    }

                    $functionResponse = @{
                        name     = $toolName
                        response = $toolResponseValue
                    }

                    if ($null -ne $call.id -and -not [string]::IsNullOrEmpty([string]$call.id)) {
                        $functionResponse.id = [string]$call.id
                    }

                    $toolTurn = @{
                        role  = "user"
                        parts = @(
                            @{
                                functionResponse = $functionResponse
                            }
                        )
                    }
                    [void]$Contents.Add($toolTurn)
                }

                # Send the same turn context back to Gemini for the final answer.
                continue
            }

            # No tool call: this is the final natural-language response.
            $toolLoop = $false
            $webCitationText = ''
            if ($usingOpenAIResponses -and $null -ne $response.webCitations) {
                $webCitationText = Format-GemmaOpenAIWebCitations -Citations @($response.webCitations)
            }
            $replyTextParts = @(
                $modelParts | Where-Object { $null -ne $_.text -and ($script:VerboseOutput -or -not $_.thought) } |
                    ForEach-Object {
                        if ($_.thought) { "[Thought summary]`n$([string]$_.text)" } else { [string]$_.text }
                    }
            )
            $streamedFinalResponse = ($streamTextThisRequest -and $streamingActive)
            if ($streamedFinalResponse) {
                # Store exactly the text emitted by the active stream, including
                # retry-prefix suppression and the selected display mode.
                $reply = ([string]$streamDisplayState.OutputText).Trim()
            } else {
                $reply = Normalize-MiraReply ($replyTextParts -join "`n")
            }
            if ($script:CommandMode -and -not $streamedFinalResponse) { $reply = [regex]::Replace($reply.Trim(),'(?s)^```[a-zA-Z0-9_-]*\s*|\s*```$','').Trim() }
            $script:LastAssistantReply = $reply

            try {
                $width = [Console]::WindowWidth
            } catch {
                $width = $Host.UI.RawUI.WindowWidth
            }
            if ($width -le 10) { $width = 80 }

            if ($turnStopwatch.IsRunning) { $turnStopwatch.Stop() }
            $elapsedSeconds = ([Math]::Round($turnStopwatch.Elapsed.TotalSeconds,1)).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)
            $frameCorner = [string][char]0x250C
            $frameHorizontal = [string][char]0x2500
            $leftStatus = $frameCorner + ($frameHorizontal * 2) + ' ' + $elapsedSeconds + 's'
            $modelStatus = [string]$script:MODEL
            $upArrow = [string][char]0x2191
            $downArrow = [string][char]0x2193
            $rightStatus = ('{0} {1}  {2} {3}' -f $upArrow,[string]$turnPromptTokens,$downArrow,[string]$turnCompletionTokens)
            $statusWidth = [Math]::Max(1,$width - 1)
            $fixedWidth = $leftStatus.Length + $rightStatus.Length + 2
            $maxModelWidth = [Math]::Max(1,$statusWidth - $fixedWidth - 2)
            if ($modelStatus.Length -gt $maxModelWidth) {
                if ($maxModelWidth -gt 3) { $modelStatus = $modelStatus.Substring(0,$maxModelWidth - 3) + '...' }
                else { $modelStatus = $modelStatus.Substring(0,$maxModelWidth) }
            }
            $statusGap = $statusWidth - $leftStatus.Length - $modelStatus.Length - $rightStatus.Length - 2
            if ($statusGap -lt 1) { $statusGap = 1 }
            $topBoxLine = $leftStatus + (' ' * $statusGap) + $modelStatus + '  ' + $rightStatus
            if ($topBoxLine.Length -gt $statusWidth) { $topBoxLine = $topBoxLine.Substring(0,$statusWidth) }
            $bottomRule = $frameHorizontal * 36
            $bottomIndent = [Math]::Max(0,[int](($width - $bottomRule.Length) / 2))
            $bottomBoxLine = (' ' * $bottomIndent) + $bottomRule

            if ($streamedFinalResponse) {
                # The provisional header was drawn before the first response
                # chunk. Replace it with final elapsed/token stats when it is
                # still visible, then close the frame below the streamed body.
                if (-not [string]::IsNullOrWhiteSpace($webCitationText)) {
                    Write-Host $webCitationText -ForegroundColor DarkCyan
                }
                if ($streamDisplayState.ShowFrame) {
                    if ($streamDisplayState.HeaderDrawn -and $streamDisplayState.HeaderTop -ge 0) {
                        try {
                            $restoreLeft = [Console]::CursorLeft
                            $restoreTop = [Console]::CursorTop
                            $headerVisible = ($streamDisplayState.HeaderTop -ge [Console]::WindowTop -and
                                $streamDisplayState.HeaderTop -lt ([Console]::WindowTop + [Console]::WindowHeight))
                            if ($headerVisible) {
                                try {
                                    [Console]::SetCursorPosition([int]$streamDisplayState.HeaderLeft,[int]$streamDisplayState.HeaderTop)
                                    Write-Host $topBoxLine.PadRight($statusWidth) -NoNewline -ForegroundColor DarkGray
                                } finally {
                                    try { [Console]::SetCursorPosition($restoreLeft,$restoreTop) } catch {}
                                }
                            }
                        } catch {
                            # Keep the already-drawn streaming header if cursor
                            # positioning is unsupported by the active host.
                        }
                    }
                    Write-Host $bottomBoxLine -ForegroundColor DarkGray
                }
            } elseif ($script:CommandMode) { [Console]::Out.WriteLine($reply) }
            elseif ($script:OneShot) {
                Write-Host $reply -ForegroundColor Cyan
                if (-not [string]::IsNullOrWhiteSpace($webCitationText)) {
                    Write-Host $webCitationText -ForegroundColor DarkCyan
                }
            } else {
                Write-Host $topBoxLine -ForegroundColor DarkGray
                Write-Host $reply -ForegroundColor Cyan
                if (-not [string]::IsNullOrWhiteSpace($webCitationText)) {
                    Write-Host $webCitationText -ForegroundColor DarkCyan
                }
                Write-Host $bottomBoxLine -ForegroundColor DarkGray
            }
            $modelTurn = @{ role = "model"; parts = @( @{ text = $reply } ) }
            if ($usingOpenAIResponses -and $null -ne $response.openaiOutputItems) {
                $modelTurn.openaiOutputItems = @($response.openaiOutputItems)
            }
            [void]$Contents.Add($modelTurn)
            if ($script:OneShot) { $script:OneShotCompleted = $true }
        }
        finally {
            if ($null -ne $oldTreatControlCAsInput) {
                try { [Console]::TreatControlCAsInput = $oldTreatControlCAsInput } catch {}
            }
            if ($null -ne $powershell) {
                try { $powershell.Dispose() } catch {}
            }
            if ($null -ne $runspace) {
                try { $runspace.Dispose() } catch {}
            }
        }
    }
    }
    catch {
        Rollback-MiraTurn -History $Contents -StartCount $turnStartCount
        $errMsg = $_.Exception.Message
        Write-Host "`n[API Failure]: $errMsg" -ForegroundColor Red
        if ($script:OneShot) { $script:OneShotCompleted = $true }
        # Exit only this turn; the interactive CLI remains alive.
    }
