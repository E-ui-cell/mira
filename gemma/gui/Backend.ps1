#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][string]$Provider,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Effort,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$SystemPromptPath = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-GemmaGuiRequest {
    param(
        [string]$RootPath,
        [string]$Provider,
        [string]$Model,
        [string]$Effort,
        [string]$Prompt,
        [string]$SystemPromptPath
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        . (Join-Path $RootPath 'config\Defaults.ps1')
        $script:CommandMode = $false
        $script:Provider = $Provider.ToLowerInvariant()
        $script:MODEL = $Model.Trim()
        $MODEL = $script:MODEL
        $script:Effort = $Effort.ToLowerInvariant()
        if ($script:Effort -notin @('low','medium','high')) { $script:Effort = 'high' }
        $script:VerboseOutput = $false
        $script:ExecutionPermission = 'ask'
        $script:GemmaPromptDirectory = Join-Path $RootPath 'prompts'

        . (Join-Path $RootPath 'providers\Antigravity.ps1')
        . (Join-Path $RootPath 'providers\GeminiApi.ps1')
        . (Join-Path $RootPath 'windows\Native.ps1')
        . (Join-Path $RootPath 'agent\Execution.ps1')
        . (Join-Path $RootPath 'agent\Skills.ps1')
        . (Join-Path $RootPath 'agent\Tools.ps1')
        . (Join-Path $RootPath 'agent\Conversation.ps1')

        if ($script:Provider -notin @('antigravity','gemini')) {
            throw "Unsupported provider '$Provider'."
        }
        if ([string]::IsNullOrWhiteSpace($script:MODEL)) {
            throw 'Select a model before sending a prompt.'
        }
        if (-not $Prompt.Trim()) {
            throw 'The prompt is empty.'
        }

        if ($script:Provider -eq 'antigravity' -and -not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
            throw 'Antigravity is not authenticated. Authenticate first with the existing GEMMA CLI using .auth login, or select Gemini and set GEMINI_API.'
        }
        if ($script:Provider -eq 'gemini' -and [string]::IsNullOrWhiteSpace($API_KEY)) {
            throw 'Gemini API key is missing. Set GEMINI_API or GEMINI_API_KEY in the environment.'
        }

        if ($SystemPromptPath) {
            if (-not (Test-Path -LiteralPath $SystemPromptPath -PathType Leaf)) { throw "System prompt file not found: $SystemPromptPath" }
            $systemText = Get-Content -LiteralPath $SystemPromptPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($systemText)) { throw 'The selected system prompt file is empty.' }
            $script:ActiveSystemPromptName = [IO.Path]::GetFileNameWithoutExtension($SystemPromptPath)
        } else {
            $systemText = [string]$MIRA_DEFAULT_SYSTEM_PROMPT
            $script:ActiveSystemPromptName = 'default'
        }

        $SystemInstruction = @{ parts = @(@{ text = $systemText }) }
        $Contents = [System.Collections.ArrayList]::new()
        $rawInput = $Prompt.Trim()
        [void]$Contents.Add(@{
            role = 'user'
            parts = @(@{ text = $rawInput })
        })

        $toolConfiguration = Get-GemmaToolConfiguration
        $GeminiTools = $toolConfiguration.Tools
        $GeminiToolConfig = $toolConfiguration.ToolConfig

        # The GUI has no terminal Read-Host prompt. Local commands use a native
        # Windows Yes/No permission dialog and remain ASK-by-default.
        function Invoke-GemmaPowerShellTool {
            param([string]$Command)
            if ([string]::IsNullOrWhiteSpace($Command)) { throw 'run_powershell requires a command.' }
            $nl = [Environment]::NewLine
            $message = "The assistant requests permission to run this local PowerShell command:" + $nl + $nl +
                $Command + $nl + $nl + 'Run it?'
            $decision = [System.Windows.Forms.MessageBox]::Show(
                $message,
                'GEMMA - PowerShell permission',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($decision -ne [System.Windows.Forms.DialogResult]::Yes) {
                return @{ approved = $false; output = 'User declined command execution.' }
            }

            $previousProgressPreference = $ProgressPreference
            $previousInformationPreference = $InformationPreference
            $previousApprovedToolState = $script:InApprovedPowerShellTool
            try {
                $script:InApprovedPowerShellTool = $true
                $ProgressPreference = 'SilentlyContinue'
                $InformationPreference = 'SilentlyContinue'
                $output = Invoke-Expression $Command *>&1 | Out-String -Width $MIRA_POWERSHELL_OUTPUT_WIDTH
                if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) {
                    $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + $nl + '[Command output truncated]'
                }
                return @{ approved = $true; output = $output; current_location = (Get-Location).Path }
            } catch {
                return @{ approved = $true; error = $_.Exception.Message }
            } finally {
                $ProgressPreference = $previousProgressPreference
                $InformationPreference = $previousInformationPreference
                $script:InApprovedPowerShellTool = $previousApprovedToolState
            }
        }

        $promptTokens = 0
        $completionTokens = 0
        $toolRounds = 0
        $maxToolRounds = [int]$MIRA_MAX_TOOL_ROUNDS

        if ($script:Provider -eq 'antigravity' -and (Test-GemmaSearchIntent -Text $rawInput)) {
            Invoke-GemmaAntigravityGoogleSearchPreflight
        }

        while ($true) {
            $toolRounds++
            if ($toolRounds -gt $maxToolRounds) {
                throw "Tool loop exceeded $maxToolRounds rounds."
            }

            $payloadObj = Build-GeminiPayload -SystemInstruction $SystemInstruction -Contents $Contents
            if ($script:Provider -eq 'antigravity') {
                $payloadObj.systemInstruction.role = 'user'
                if ($payloadObj.Contains('safetySettings')) { [void]$payloadObj.Remove('safetySettings') }
                $envelope = Invoke-GemmaAntigravityRequest -Payload $payloadObj -Model $script:MODEL
                if ($null -eq $envelope -or $null -eq $envelope.response) {
                    throw 'Antigravity returned an invalid or empty response envelope.'
                }
                $response = $envelope.response
            } else {
                $jsonPayload = $payloadObj | ConvertTo-Json -Depth 30
                $url = "https://generativelanguage.googleapis.com/v1beta/models/$($script:MODEL):generateContent"
                $requestArgs = @{
                    Uri = $url
                    Method = 'Post'
                    Headers = @{ 'x-goog-api-key' = $API_KEY }
                    ContentType = 'application/json; charset=utf-8'
                    Body = [Text.Encoding]::UTF8.GetBytes($jsonPayload)
                    TimeoutSec = 180
                    ErrorAction = 'Stop'
                }
                $response = Invoke-RestMethod @requestArgs
            }

            if ($null -ne $response.usageMetadata) {
                if ($null -ne $response.usageMetadata.promptTokenCount) {
                    $promptTokens += [int]$response.usageMetadata.promptTokenCount
                }
                if ($null -ne $response.usageMetadata.candidatesTokenCount) {
                    $completionTokens += [int]$response.usageMetadata.candidatesTokenCount
                }
            }

            if ($null -eq $response.candidates -or @($response.candidates).Count -eq 0) {
                $blockReason = [string]$response.promptFeedback.blockReason
                if ($blockReason) { throw "Google blocked the prompt: $blockReason." }
                if ($null -ne $response.error) { throw "API error: $($response.error.message)" }
                throw 'The API returned no candidates.'
            }

            $candidate = $response.candidates[0]
            $content = $candidate.content
            if ($null -eq $content -or $null -eq $content.parts -or @($content.parts).Count -eq 0) {
                $finishReason = [string]$candidate.finishReason
                throw "Generation returned no content. Finish reason: $finishReason"
            }

            $modelParts = @($content.parts)
            $functionCalls = @(
                $modelParts |
                    Where-Object { $null -ne $_.functionCall } |
                    ForEach-Object { $_.functionCall }
            )

            if ($functionCalls.Count -gt 0) {
                [void]$Contents.Add(@{ role = 'model'; parts = $modelParts })
                foreach ($call in $functionCalls) {
                    $toolName = [string]$call.name
                    $toolResult = Invoke-GemmaToolCall -Call $call
                    $functionResponse = @{ name = $toolName; response = $toolResult }
                    if ($call.id) { $functionResponse.id = [string]$call.id }
                    [void]$Contents.Add(@{
                        role = 'user'
                        parts = @(@{ functionResponse = $functionResponse })
                    })
                }
                continue
            }

            $replyParts = @(
                $modelParts |
                    Where-Object { $null -ne $_.text -and -not $_.thought } |
                    ForEach-Object { [string]$_.text }
            )
            $reply = [string]::Join([Environment]::NewLine,$replyParts).Trim()
            if ([string]::IsNullOrWhiteSpace($reply)) {
                throw 'The model returned no readable text.'
            }

            $watch.Stop()
            return [pscustomobject]@{
                Success = $true
                Reply = $reply
                Provider = $script:Provider
                Model = $script:MODEL
                PromptTokens = $promptTokens
                CompletionTokens = $completionTokens
                ElapsedSeconds = [Math]::Round($watch.Elapsed.TotalSeconds,1)
                Error = $null
            }
        }
    } catch {
        if ($watch.IsRunning) { $watch.Stop() }
        return [pscustomobject]@{
            Success = $false
            Reply = ''
            Provider = $Provider
            Model = $Model
            PromptTokens = 0
            CompletionTokens = 0
            ElapsedSeconds = [Math]::Round($watch.Elapsed.TotalSeconds,1)
            Error = $_.Exception.Message
        }
    }
}

Add-Type -AssemblyName System.Windows.Forms
$answer = Invoke-GemmaGuiRequest -RootPath $RootPath -Provider $Provider -Model $Model -Effort $Effort -Prompt $Prompt -SystemPromptPath $SystemPromptPath
Write-Output $answer
