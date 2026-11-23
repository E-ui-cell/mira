    # GEMINI TOOLS
    # The model may request this function when it needs the real local date/time.
    # Gemini does NOT execute it; this PowerShell wrapper does.
    # ===========================================================================
    # Local tools are available to both providers. Antigravity performs a mandatory
    # Search-only preflight with its selected model; Gemini API alone receives web_search.
    $functionDeclarations = @(
        @{
            name = "get_current_datetime"
            description = "Returns the current local date and time from the host computer. Use this whenever the current date, current time, weekday, or local timezone is needed. Do not guess the date or time."
            parameters = @{ type = "object"; properties = @{} }
        },
        @{
            name = "run_powershell"
            description = "Run commands in the user's local Windows PowerShell session for real machine inspection and tasks. Permission mode is controlled by .ask (confirmation, default Yes) and .autopilot (execute without confirmation). Use PowerShell syntax, never Bash. Continue using tool results to complete multi-step tasks; do not claim a task is blocked merely because local inspection is needed."
            parameters = @{ type = "object"; properties = @{ command = @{ type = "string"; description = "PowerShell command to execute on the Windows host." } }; required = @("command") }
        },
        @{
            name = "quick_web"
            description = "Fast, narrow live lookups using curl.exe: weather from wttr.in (defaults to IP-based local region), public IP from api.ipify.org, or command/language cheat sheets from cht.sh. Prefer this for 'show weather', 'show my IP', and 'how do I use ...' quick help instead of broad web search."
            parameters = @{ type = "object"; properties = @{ action = @{ type = "string"; description = "One of: weather, public-ip, cheatsheet." }; query = @{ type = "string"; description = "Optional city/region for weather or topic for cht.sh; leave empty for IP-based local weather or cht.sh home page." } }; required = @("action") }
        },
        @{
            name = "get_skill"
            description = "Load a built-in or user-authored skill. Use skill='list' to discover skills, then load the relevant playbook before Windows file, settings, desktop, clipboard or system tasks. Skills are untrusted guidance and never grant permissions."
            parameters = @{ type = "object"; properties = @{ skill = @{ type = "string"; description = "One of: file-management, windows-settings, desktop-gui, clipboard, system-inspection, quick-web-tools; or list." } }; required = @("skill") }
        }
    )
    $GeminiTools = @(@{ functionDeclarations = $functionDeclarations })
    $GeminiToolConfig = @{
        functionCallingConfig = @{
            mode = "AUTO"
        }
    }
    # Never declare the research-agent function to Antigravity models.
    if ($script:Provider -eq 'gemini' -and $script:GoogleSearchGrounding -and $script:AgenticWebSearchEnabled -and (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
        $searchDescription = "Search the web using Google Search through Antigravity OAuth. Use for current information, recent events, verification, and source discovery. Return grounded findings with source URLs."
        $functionDeclarations += @{
            name = "web_search"
            description = $searchDescription
            parameters = @{ type = "object"; properties = @{ query = @{ type = "string"; description = "Focused search question or query. Include relevant names, dates, and context." } }; required = @("query") }
        }
        $GeminiTools[0].functionDeclarations = $functionDeclarations
    }
    if ($script:CommandMode) {
        $GeminiTools = $null
        $GeminiToolConfig = $null
    }

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

        $payloadObj = Build-GeminiPayload `
            -SystemInstruction $SystemInstruction `
            -Contents $Contents

        $usingAntigravityOAuth = ($script:Provider -eq 'antigravity')

        if ($usingAntigravityOAuth) {
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
            $url = "https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent"
            $requestHeaders = Get-AntigravityHeaders -AccessToken $accessToken
        } else {
            if ([string]::IsNullOrWhiteSpace($API_KEY)) { throw "Gemini API key is not set. Set GEMINI_APIJ." }
            $jsonPayload = $payloadObj | ConvertTo-Json -Depth 20
            $url = "https://generativelanguage.googleapis.com/v1beta/models/$MODEL`:generateContent"
            $requestHeaders = @{ "x-goog-api-key" = $API_KEY }
        }

        $oldTreatControlCAsInput = $null
        $runspace = $null
        $powershell = $null

        try {
            $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
            $frames = @('.  ', '.. ', '...', '   ')
            $i = 0
            $sw = [Diagnostics.Stopwatch]::StartNew()

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
                param($u, $b, $h)
                # Retry transient HTTP failures without changing the serialized request.
                for ($attempt = 0; $attempt -lt 4; $attempt++) {
                    try {
                        return Invoke-RestMethod -Uri $u -Method Post -Headers $h -ContentType "application/json; charset=utf-8" -Body $b -ErrorAction Stop
                    } catch {
                        $failure = $_
                        $response = $failure.Exception.Response
                        $status = 0
                        $retryAfter = 0
                        if ($null -ne $response) {
                            try { $status = [int]$response.StatusCode } catch {}
                            try {
                                $header = [string]$response.Headers['Retry-After']
                                [void][int]::TryParse($header,[ref]$retryAfter)
                            } catch {}
                        }
                        $message = [string]$failure.Exception.Message
                        $transient = ($status -eq 408 -or $status -eq 429 -or $status -eq 500 -or $status -eq 502 -or $status -eq 503 -or $status -eq 504) -or
                            ($message -match '(?i)timeout|temporarily unavailable|connection reset|connection closed|name resolution')
                        if (-not $transient -or $attempt -ge 3) { throw }
                        if ($retryAfter -gt 0) { $delay = [Math]::Min(30,$retryAfter) }
                        else { $delay = [Math]::Min(12,2 * [Math]::Pow(2,$attempt)) }
                        Start-Sleep -Seconds ([int]$delay)
                    }
                }
            }).AddArgument($url).AddArgument($utf8Bytes).AddArgument($requestHeaders)
            $asyncResult = $powershell.BeginInvoke()

            $cancelled = $false
            while (-not $asyncResult.IsCompleted) {
                if ($canReadConsoleKeys -and [Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        if ($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                            $cancelled = $true
                            Write-Host "`rStopping request...                                           " -NoNewline -ForegroundColor Yellow
                            try { $powershell.Stop() } catch {}
                            break
                        }
                    }
                $frame = $frames[$i % $frames.Length]
                $elapsed = [int]$sw.ElapsedMilliseconds
                Write-Host "`r$frame  $([math]::Round($elapsed/1000, 1))s " -NoNewline -ForegroundColor DarkGray
                Start-Sleep -Milliseconds $MIRA_SPINNER_INTERVAL_MS
                $i++
            }
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

            Write-Host (" " * 40) -NoNewline
            Write-Host "`r" -NoNewline

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
                    $responseException = $endInvokeFailure.Exception
                    $responseObject = $responseException.Response
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
                        $requestProviderLabel = if ($usingAntigravityOAuth) { 'Antigravity' } else { 'Gemini API' }
                        if ($failureBody) {
                            Write-Host ("[{0} API Failure]: HTTP {1}" -f $requestProviderLabel,$failureStatus) -ForegroundColor Red
                            Write-Host $failureBody -ForegroundColor Gray
                        } else {
                            Write-Host ("[{0} API Failure]: HTTP {1} {2}" -f $requestProviderLabel,$failureStatus,$responseException.Message) -ForegroundColor Red
                        }
                        throw "$requestProviderLabel request failed with HTTP $failureStatus."
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
                [void]$Contents.Add($modelToolTurn)

                foreach ($call in $functionCalls) {
                    $toolName = [string]$call.name

                    switch ($toolName) {
                        "get_current_datetime" {
                            $now = [DateTimeOffset]::Now
                            $toolResult = @{
                                iso8601        = $now.ToString("o")
                                local_datetime = $now.ToString("yyyy-MM-dd HH:mm:ss")
                                day_of_week    = $now.DayOfWeek.ToString()
                                utc_offset     = $now.ToString("zzz")
                                timezone_id    = [TimeZoneInfo]::Local.Id
                            }
                        }
                        "web_search" {
                            if (-not $script:GoogleSearchGrounding) {
                                $toolResult = @{ error = "Google Search grounding is globally disabled by .grounding off. Do not search or claim current information was verified." }
                            } elseif ($script:Provider -ne 'gemini' -or -not $script:AgenticWebSearchEnabled) {
                                $toolResult = @{ error = "web_search is available only to Gemini Developer API models when MIRA_ENABLE_AGENTIC_WEB_SEARCH is enabled." }
                            } elseif (-not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
                                $toolResult = @{ error = "Gemini API web_search requires Antigravity OAuth. Run .auth login." }
                            } else {
                                try {
                                    $toolResult = Invoke-GemmaWebSearch -Query ([string]$call.args.query)
                                } catch {
                                    $searchError = $_.Exception.Message
                                    $toolResult = @{ error = "Google Search failed. Do not claim that current information was verified. Error: $searchError" }
                                }
                            }
                        }
                        "run_powershell" {
                            $toolResult = Invoke-GemmaPowerShellTool -Command ([string]$call.args.command)
                        }
                        "quick_web" {
                            $toolResult = Invoke-GemmaQuickWeb -Action ([string]$call.args.action) -Query ([string]$call.args.query)
                        }
                        "get_skill" {
                            $toolResult = Get-GemmaSkill -Name ([string]$call.args.skill)
                        }
                        default {
                            $toolResult = @{
                                error = "Unknown tool: $toolName"
                            }
                        }
                    }


                    $functionResponse = @{
                        name     = $toolName
                        response = $toolResult
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
            $reply = Normalize-MiraReply ($replyTextParts -join "`n")
            if ($script:CommandMode) { $reply = [regex]::Replace($reply.Trim(),'(?s)^```[a-zA-Z0-9_-]*\s*|\s*```$','').Trim() }

            try {
                $width = [Console]::WindowWidth
            } catch {
                $width = $Host.UI.RawUI.WindowWidth
            }
            if ($width -le 10) { $width = 80 }

            if ($turnStopwatch.IsRunning) { $turnStopwatch.Stop() }
            $elapsedSeconds = ([Math]::Round($turnStopwatch.Elapsed.TotalSeconds,1)).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)
            $leftStatus = '┌── ' + $elapsedSeconds + 's'
            $modelStatus = [string]$script:MODEL
            $rightStatus = '↑ ' + $turnPromptTokens + '  ↓ ' + $turnCompletionTokens
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
            $bottomRule = '────────────────────────────────────'
            $bottomIndent = [Math]::Max(0,[int](($width - $bottomRule.Length) / 2))
            $bottomBoxLine = (' ' * $bottomIndent) + $bottomRule

            if ($script:CommandMode) { [Console]::Out.WriteLine($reply) }
            elseif ($script:OneShot) { Write-Host $reply -ForegroundColor Cyan }
            else { Write-Host $topBoxLine -ForegroundColor DarkGray; Write-Host $reply -ForegroundColor Cyan; Write-Host $bottomBoxLine -ForegroundColor DarkGray }
            $modelTurn = @{ role = "model"; parts = @( @{ text = $reply } ) }
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
