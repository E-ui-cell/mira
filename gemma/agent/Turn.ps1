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
                param($u, $b, $h, $keyPool, $keyStart, $providerName, $streamResponses, $streamQueue, $streamState, $streamGoogle, $includeThoughts)
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
                        $Value = $Value.Replace(([string][char]9),'    ')
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
                        $chunkResponse = $eventObject
                        if ($null -ne $eventObject.response) { $chunkResponse = $eventObject.response }
                        if ($null -ne $chunkResponse.error) {
                            $eventMessage = [string]$chunkResponse.error.message
                            if ([string]::IsNullOrWhiteSpace($eventMessage)) { $eventMessage = $EventJson }
                            throw "Google streaming API error: $eventMessage"
                        }

                        if ($null -ne $chunkResponse.usageMetadata) {
                            $ParseState.Usage = $chunkResponse.usageMetadata
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

                            if (-not $ParseState.PartMap.ContainsKey($partIndex)) {
                                $partCopy = @{}
                                if ($incomingPart -is [System.Collections.IDictionary]) {
                                    foreach ($partKey in $incomingPart.Keys) { $partCopy[[string]$partKey] = $incomingPart[$partKey] }
                                } else {
                                    foreach ($partProperty in $incomingPart.PSObject.Properties) { $partCopy[$partProperty.Name] = $partProperty.Value }
                                }
                                if ($null -ne $incomingPart.functionCall) {
                                    $partCopy.functionCall = & $ConvertCall $incomingPart.functionCall
                                    $ParseState.HasToolCall = $true
                                }
                                $ParseState.PartMap[$partIndex] = $partCopy
                                [void]$ParseState.Candidate.content.parts.Add($partCopy)
                            } else {
                                $partCopy = $ParseState.PartMap[$partIndex]
                                if (-not [string]::IsNullOrEmpty([string]$incomingPart.text)) {
                                    $partCopy.text = [string]$partCopy.text + [string]$incomingPart.text
                                }
                                if ([bool]$incomingPart.thought) { $partCopy.thought = $true }
                                if (-not [string]::IsNullOrWhiteSpace([string]$incomingPart.thoughtSignature)) {
                                    $partCopy.thoughtSignature = [string]$incomingPart.thoughtSignature
                                }
                                if ($null -ne $incomingPart.functionCall) {
                                    $incomingCallMap = & $ConvertCall $incomingPart.functionCall
                                    if ($null -eq $partCopy.functionCall) {
                                        $partCopy.functionCall = $incomingCallMap
                                    } else {
                                        if ($partCopy.functionCall -isnot [System.Collections.IDictionary]) {
                                            $partCopy.functionCall = & $ConvertCall $partCopy.functionCall
                                        }
                                        foreach ($callField in @('id','name')) {
                                            if (-not [string]::IsNullOrWhiteSpace([string]$incomingCallMap[$callField])) {
                                                $partCopy.functionCall[$callField] = $incomingCallMap[$callField]
                                            }
                                        }
                                        if ($partCopy.functionCall.args -isnot [System.Collections.IDictionary]) {
                                            $partCopy.functionCall.args = @{}
                                        }
                                        foreach ($argKey in $incomingCallMap.args.Keys) {
                                            $partCopy.functionCall.args[[string]$argKey] = $incomingCallMap.args[$argKey]
                                        }
                                    }
                                    $ParseState.HasToolCall = $true
                                }
                            }

                            $isThought = [bool]$incomingPart.thought
                            if ($isThought) { $ParseState.HasThoughts = $true }
                            if (-not $isThought -and -not [string]::IsNullOrEmpty([string]$incomingPart.text)) {
                                $ParseState.HasResponseText = $true
                            }

                            if (-not [string]::IsNullOrEmpty([string]$incomingPart.text) -and (-not $isThought -or $IncludeThoughts)) {
                                if ($ParseState.HasDisplayedPart -and [int]$ParseState.LastDisplayedPartIndex -ne $partIndex) {
                                    & $EmitText ([string][char]10) $CurrentAttempt
                                }
                                if ($isThought -and -not $ParseState.ThoughtLabelSent) {
                                    & $EmitText '[Thought summary]' $CurrentAttempt
                                    & $EmitText ([string][char]10) $CurrentAttempt
                                    $ParseState.ThoughtLabelSent = $true
                                }
                                & $EmitText ([string]$incomingPart.text) $CurrentAttempt
                                $ParseState.LastDisplayedPartIndex = $partIndex
                                $ParseState.HasDisplayedPart = $true
                            }
                        }
                    }

                    for ($keyOffset = 0; $keyOffset -lt $keyCount; $keyOffset++) {
                        $keyIndex = if ($providerName -eq 'gemini') { ($keyStart + $keyOffset) % $keyCount } else { -1 }
                        for ($attempt = 0; $attempt -lt 4; $attempt++) {
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
                                    PartMap = @{}
                                    Usage = $null
                                    HasToolCall = $false
                                    HasThoughts = $false
                                    HasResponseText = $false
                                    HasDisplayedPart = $false
                                    LastDisplayedPartIndex = -1
                                    ThoughtLabelSent = $false
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
                    for ($keyOffset = 0; $keyOffset -lt $keyPool.Count; $keyOffset++) {
                        $keyIndex = ($keyStart + $keyOffset) % $keyPool.Count
                        $authHeaders = @{ Authorization = ('Bearer ' + [string]$keyPool[$keyIndex]) }
                        for ($attempt = 0; $attempt -lt 3; $attempt++) {
                            $httpResponse = $null
                            $httpRequest = $null
                            $sseReader = $null
                            try {
                                if (-not $streamResponses) {
                                    $successResponse = Invoke-RestMethod -Uri $u -Method Post -Headers $authHeaders -ContentType 'application/json; charset=utf-8' -Body $b -TimeoutSec 180 -ErrorAction Stop
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
                                                $streamState.TextStarted = $true
                                                $streamQueue.Enqueue($deltaText)
                                            }
                                        } elseif ($eventType -eq 'response.completed') {
                                            $completedResponse = $sseEvent.response
                                            break
                                        } elseif ($eventType -eq 'response.failed' -or $eventType -eq 'response.incomplete' -or $eventType -eq 'error') {
                                            $streamError = ''
                                            if ($null -ne $sseEvent.response -and $null -ne $sseEvent.response.error) {
                                                $streamError = [string]$sseEvent.response.error.message
                                            }
                                            if ([string]::IsNullOrWhiteSpace($streamError) -and $null -ne $sseEvent.error) {
                                                $streamError = [string]$sseEvent.error.message
                                            }
                                            if ([string]::IsNullOrWhiteSpace($streamError) -and $null -ne $sseEvent.response.incomplete_details) {
                                                $streamError = [string]$sseEvent.response.incomplete_details.reason
                                            }
                                            if ([string]::IsNullOrWhiteSpace($streamError)) { $streamError = $eventJson }
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
                                try { $errorCode = [string](($errorBody | ConvertFrom-Json -ErrorAction Stop).error.code) } catch {}
                                $lastFailure = "HTTP $status $errorCode $($failure.Exception.Message) $errorBody"
                                if ($streamResponses -and $streamState.TextStarted) { throw $lastFailure }
                                if ($status -eq 429 -and $errorCode -match '(?i)insufficient_quota|credit_balance_exhausted|organization_usage_limit_exceeded') { throw $lastFailure }
                                if ($status -eq 401 -or ($status -eq 403 -and ($errorCode -match '(?i)permission|access|api_key' -or $errorBody -match '(?i)api.?key|permission denied'))) {
                                    if ($keyOffset -lt ($keyPool.Count - 1)) { break }
                                    throw $lastFailure
                                }
                                if ($status -eq 403) { throw $lastFailure }
                                $transient = ($status -in @(0,408,429,500,502,503,504)) -or ([string]$failure.Exception.Message -match '(?i)timeout|connection reset|connection closed|name resolution')
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
            }).AddArgument($url).AddArgument($utf8Bytes).AddArgument($requestHeaders).AddArgument($requestApiKeys).AddArgument($requestKeyIndex).AddArgument($requestProviderName).AddArgument([bool]$streamOpenAIResponses).AddArgument($streamQueue).AddArgument($streamState).AddArgument([bool]$streamGoogle).AddArgument([bool]$script:VerboseOutput)
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
            }
            $writeStreamChunk = {
                param([string]$Chunk)
                if ([string]::IsNullOrEmpty($Chunk)) { return }
                $streamDisplayState.OutputText += $Chunk
                if ($streamDisplayState.Mode -eq 'delta') {
                    if (-not $streamDisplayState.HasOutput) {
                        Write-Host (" " * 60) -NoNewline
                        Write-Host ([string][char]13) -NoNewline
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
                        Write-Host (" " * 60) -NoNewline
                        Write-Host ([string][char]13) -NoNewline
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
                    Write-Host (" " * 60) -NoNewline
                    Write-Host ([string][char]13) -NoNewline
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
                if ($usingOpenAIResponses) {
                    $response = ConvertFrom-GemmaOpenAIResponsesResponse -OpenAIResponse $response
                } else {
                    $response = ConvertFrom-GemmaOpenAIResponse -OpenAIResponse $response
                }
            } elseif ($requestProviderName -eq 'gemini') {
                $usedKeyIndex = $requestKeyIndex
                if ($null -ne $response._gemmaKeyIndex) { $usedKeyIndex = [int]$response._gemmaKeyIndex }
                $script:MiraGeminiApiKeyIndex = ($usedKeyIndex + 1) % $requestApiKeys.Count
            }

            if ($null -eq $response) {
                throw "The API returned a null or empty response object."
            }

            # Gemini usageMetadata is present on both Gemini API and
            # Antigravity responses. Accumulate each model/tool round.
            if ($null -ne $response.usageMetadata) {
                if ($null -ne $response.usageMetadata.promptTokenCount) {
                    $turnPromptTokens += [int]$response.usageMetadata.promptTokenCount
                }
                if ($null -ne $response.usageMetadata.candidatesTokenCount) {
                    $turnCompletionTokens += [int]$response.usageMetadata.candidatesTokenCount
                }
            }

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
                # The response body has already been printed incrementally.
                if (-not $script:CommandMode -and -not $script:OneShot) {
                    Write-Host $topBoxLine -ForegroundColor DarkGray
                    Write-Host $bottomBoxLine -ForegroundColor DarkGray
                }
            } elseif ($script:CommandMode) { [Console]::Out.WriteLine($reply) }
            elseif ($script:OneShot) { Write-Host $reply -ForegroundColor Cyan }
            else { Write-Host $topBoxLine -ForegroundColor DarkGray; Write-Host $reply -ForegroundColor Cyan; Write-Host $bottomBoxLine -ForegroundColor DarkGray }
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
