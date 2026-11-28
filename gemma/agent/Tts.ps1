# WINDOWS POWERSHELL 5.1
# On-demand Gemini 3.8 Flash TTS with a permanent, content-addressed WAV cache.

$script:MiraTtsModel = $MIRA_TTS_MODEL
$script:MiraTtsVoice = $MIRA_TTS_VOICE
$script:MiraTtsPlayer = $null
$script:MiraTtsModels = @('gemini-3.8-flash-tts','gemini-3.1-flash-tts-preview','gemini-2.5-flash-preview-tts','gemini-3.8-flash-lite-tts')
$script:MiraTtsAudioDirectory = Join-Path $HOME '.gemma\audio'

function Get-GemmaTtsDirectorStyle {
    param([System.Collections.IList]$Contents)

    # TTS direction is optional and belongs to the active system prompt preset.
    # Only a prompt containing this heading can supply a director instruction.
    $director = ''
    $systemText = [string]$SystemInstruction.parts[0].text
    $match = [regex]::Match($systemText,'(?ims)^##[ \t]+TTS voice direction[ \t]*\r?\n(?<body>.*?)(?=^##[ \t]+|^COMMAND GENERATION MODE:|\z)')
    if ($match.Success) { $director = $match.Groups['body'].Value.Trim() }

    $context = ''
    if ($null -ne $Contents) {
        for ($i = $Contents.Count - 1; $i -ge 0; $i--) {
            $turn = $Contents[$i]
            if ($turn.role -ne 'user' -or $null -eq $turn.parts) { continue }
            $textParts = @(
                foreach ($part in $turn.parts) {
                    if ($null -ne $part.text -and -not [string]::IsNullOrWhiteSpace([string]$part.text)) { [string]$part.text }
                }
            )
            if ($textParts.Count -gt 0) { $context = ($textParts -join ' '); break }
        }
    }
    $context = [regex]::Replace($context,'(?s)\x60{3}.*?\x60{3}',' ')
    $context = [regex]::Replace($context,'[\r\n\t]+',' ')
    $context = [regex]::Replace($context,'\s{2,}',' ').Trim()
    if ($context.Length -gt 120) { $context = $context.Substring(0,117).TrimEnd() + '...' }
    $styleParts = New-Object 'System.Collections.Generic.List[string]'
    if ($director) { [void]$styleParts.Add($director) }
    if ($context) { [void]$styleParts.Add("Context: $context") }
    return [string]::Join(' ',@($styleParts))
}

function Get-GemmaLatestAssistantTranscript {
    param([System.Collections.IList]$Contents)
    if ($null -eq $Contents -or $Contents.Count -eq 0) { return '' }

    $lastUserIndex = -1
    for ($i = $Contents.Count - 1; $i -ge 0; $i--) {
        if ($Contents[$i].role -eq 'user') { $lastUserIndex = $i; break }
    }

    # Require a completed model text reply after the latest user/tool-response
    # turn. While a new message is pending, this returns empty instead of stale text.
    for ($i = $Contents.Count - 1; $i -gt $lastUserIndex; $i--) {
        $turn = $Contents[$i]
        if ($turn.role -ne 'model' -or $null -eq $turn.parts) { continue }
        $textParts = @(
            foreach ($part in $turn.parts) {
                if ($null -ne $part.text -and -not [string]::IsNullOrWhiteSpace([string]$part.text)) { [string]$part.text }
            }
        )
        if ($textParts.Count -gt 0) { return ($textParts -join [Environment]::NewLine) }
    }
    return ''
}

function Get-GemmaTtsCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$Transcript,
        [Parameter(Mandatory = $true)][string]$Style
    )
    # The exact synthesis inputs form the key. Different replies, user contexts,
    # voices or models cannot accidentally select another reply's audio.
    $cacheMaterial = [string]::Join([string][char]0,@(
        $Transcript,
        [string]$script:MiraTtsModel,
        [string]$script:MiraTtsVoice,
        $Style
    ))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cacheMaterial))
        $key = [BitConverter]::ToString($digest).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    # 80-bit filename keeps paths readable; the full SHA-256 still determines the cache identity.
    $fileKey = $key.Substring(0,20)
    $shortPath = Join-Path $script:MiraTtsAudioDirectory ($fileKey + '.wav')

    # Preserve existing caches: migrate the former full-length filename on first access.
    $legacyPath = Join-Path $script:MiraTtsAudioDirectory ($key + '.wav')
    if (-not (Test-Path -LiteralPath $shortPath -PathType Leaf) -and (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
        Move-Item -LiteralPath $legacyPath -Destination $shortPath -ErrorAction Stop
    }
    return $shortPath
}

function Stop-GemmaTtsPlayback {
    if ($null -ne $script:MiraTtsPlayer) {
        try { $script:MiraTtsPlayer.Stop() } catch {}
        try { $script:MiraTtsPlayer.Dispose() } catch {}
        $script:MiraTtsPlayer = $null
    }
}

function Invoke-GemmaPlayTtsWave {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "[TTS] Audio file not found: $Path" -ForegroundColor Yellow
        return
    }

    $player = $null
    try {
        Stop-GemmaTtsPlayback
        $player = [System.Media.SoundPlayer]::new($Path)
        $player.Load()
        $player.Play()
        $script:MiraTtsPlayer = $player
    }
    catch {
        if ($null -ne $player) { try { $player.Dispose() } catch {} }
        Write-Host ("[TTS playback error] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-GemmaTtsModelPicker {
    $models = @($script:MiraTtsModels)
    if ($models.Count -eq 0) { return }
    $selected = [Array]::IndexOf($models,[string]$script:MiraTtsModel)
    if ($selected -lt 0) { $selected = 0 }
    $interactive = $false
    try { $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected } catch {}

    if (-not $interactive) {
        for ($i = 0; $i -lt $models.Count; $i++) {
            $marker = if ($i -eq $selected) { '  [CURRENT]' } else { '' }
            Write-Host ('{0}. {1}{2}' -f ($i + 1),$models[$i],$marker)
        }
        $choice = Read-Host 'Select TTS model number; Enter cancels'
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        $selectionNumber = 0
        if (-not [int]::TryParse($choice.Trim(),[ref]$selectionNumber) -or $selectionNumber -lt 1 -or $selectionNumber -gt $models.Count) {
            Write-Host '[Invalid TTS model selection; unchanged.]' -ForegroundColor Yellow
            return
        }
        $script:MiraTtsModel = $models[$selectionNumber - 1]
        Write-Host (('[TTS model: {0}]' -f $script:MiraTtsModel)) -ForegroundColor Green
        return
    }

    $top = [Console]::CursorTop
    $width = [Math]::Max(1,[Console]::WindowWidth - 1)
    $oldForeground = [Console]::ForegroundColor
    $oldBackground = [Console]::BackgroundColor
    $confirmed = $false
    $cancelled = $false
    $draw = {
        [Console]::SetCursorPosition(0,$top)
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        [Console]::BackgroundColor = $oldBackground
        [Console]::Write(('Select TTS model'.PadRight($width)).Substring(0,$width))
        [Console]::WriteLine()
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write(('Up/Down or j/k move; Enter select; Esc cancel'.PadRight($width)).Substring(0,$width))
        [Console]::WriteLine()
        for ($i = 0; $i -lt $models.Count; $i++) {
            $marker = if ($models[$i] -ieq $script:MiraTtsModel) { '  [current]' } else { '' }
            $label = ('  {0} {1}{2}' -f $(if ($i -eq $selected) { '>' } else { ' ' }),$models[$i],$marker)
            if ($i -eq $selected) {
                [Console]::ForegroundColor = [ConsoleColor]::White
                [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
            } else {
                [Console]::ForegroundColor = [ConsoleColor]::Gray
                [Console]::BackgroundColor = $oldBackground
            }
            [Console]::Write(($label.PadRight($width)).Substring(0,$width))
            [Console]::WriteLine()
        }
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        [Console]::SetCursorPosition(0,[Math]::Min($top + $models.Count + 2,[Console]::BufferHeight - 1))
    }
    try {
        & $draw
        while (-not $confirmed -and -not $cancelled) {
            $key = [Console]::ReadKey($true)
            $character = [char]::ToLowerInvariant($key.KeyChar)
            if ($key.Key -eq [ConsoleKey]::UpArrow -or $character -eq 'k') {
                $selected = ($selected - 1 + $models.Count) % $models.Count
                & $draw
            } elseif ($key.Key -eq [ConsoleKey]::DownArrow -or $character -eq 'j') {
                $selected = ($selected + 1) % $models.Count
                & $draw
            } elseif ($key.Key -eq [ConsoleKey]::Home) {
                $selected = 0
                & $draw
            } elseif ($key.Key -eq [ConsoleKey]::End) {
                $selected = $models.Count - 1
                & $draw
            } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                $confirmed = $true
            } elseif ($key.Key -eq [ConsoleKey]::Escape -or $character -eq 'q' -or
                ($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0))) {
                $cancelled = $true
            }
        }
    } finally {
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        for ($i = 0; $i -lt ($models.Count + 2); $i++) {
            $target = $top + $i
            if ($target -ge 0 -and $target -lt [Console]::BufferHeight) {
                [Console]::SetCursorPosition(0,$target)
                [Console]::Write((' ' * $width))
            }
        }
        [Console]::SetCursorPosition(0,[Math]::Min($top,[Console]::BufferHeight - 1))
        [Console]::WriteLine()
    }
    if ($confirmed) {
        $script:MiraTtsModel = $models[$selected]
        Write-Host (('[TTS model: {0}]' -f $script:MiraTtsModel)) -ForegroundColor Green
    }
}
function Invoke-GemmaReplayLatest {
    param([System.Collections.IList]$Contents)
    # Replay is cache-only. It never calls the Gemini API.
    $transcript = Get-GemmaLatestAssistantTranscript -Contents $Contents
    if ([string]::IsNullOrWhiteSpace($transcript)) {
        Write-Host '[TTS] No completed assistant reply for the current turn.' -ForegroundColor Yellow
        return
    }

    $style = Get-GemmaTtsDirectorStyle -Contents $Contents
    $audioPath = Get-GemmaTtsCachePath -Transcript $transcript -Style $style
    if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf)) {
        Write-Host '[TTS] No cached audio for this reply. Use .speak to generate it once.' -ForegroundColor Yellow
        return
    }

    Write-Host '[TTS] Replaying cached WAV (no API request)...' -ForegroundColor DarkGray
    Invoke-GemmaPlayTtsWave -Path $audioPath
}

function Get-GemmaTtsApiKeys { return Get-GeminiApiKeys }

function Get-GemmaTtsHttpError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $status = 0
    $body = ''
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            $status = [int]$response.StatusCode
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = [IO.StreamReader]::new($stream)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
    } catch {}
    $message = [string]$ErrorRecord.Exception.Message
    $reason = ''
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            $message = [string]$parsed.error.message
            $reason = [string]$parsed.error.details[0].reason
            if (-not $reason) { $reason = [string]$parsed.error.status }
        } catch {}
    }
    return [pscustomobject]@{ Status = $status; Message = $message; Reason = $reason }
}

function Invoke-GemmaTtsWithKeyRotation {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Json
    )
    $keys = @(Get-GemmaTtsApiKeys)
    if ($keys.Count -eq 0) { throw 'No Gemini API key candidate configured. Set GEMINI_API_KEY or GEMINI_APIJ.' }

    if ($null -eq $script:MiraTtsApiKeyIndex) { $script:MiraTtsApiKeyIndex = 0 }
    $start = [int]($script:MiraTtsApiKeyIndex % $keys.Count)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    for ($offset = 0; $offset -lt $keys.Count; $offset++) {
        $index = ($start + $offset) % $keys.Count
        $key = $keys[$index]
        try {
            $result = Invoke-RestMethod -Uri $Uri -Method Post -Headers @{ 'x-goog-api-key' = $key } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -TimeoutSec 120 -ErrorAction Stop
            $script:MiraTtsApiKeyIndex = $index
            return $result
        }
        catch {
            $info = Get-GemmaTtsHttpError -ErrorRecord $_
            $status = [int]$info.Status
            $detail = if ($info.Reason) { $info.Reason } else { $info.Message }
            [void]$failures.Add(("HTTP {0}: {1}" -f $status,$detail))

            # Rotate on quota/rate limits, auth/key errors, transient HTTP errors,
            # and transport failures. A generic 400 is not a key failure: only
            # rotate it when Google's response explicitly identifies the key.
            $keyInvalid400 = ($status -eq 400 -and (
                $info.Reason -match 'API_KEY_INVALID|API_KEY_SERVICE_BLOCKED|INVALID_API_KEY' -or
                $info.Message -match '(?i)api.?key.{0,30}(invalid|not valid|expired|blocked)'
            ))
            $rotate = ($status -in @(0,400,401,403,408,429,500,502,503,504))
            if ($status -eq 400 -and -not $keyInvalid400) { $rotate = $false }
            if (-not $rotate) {
                throw ("Gemini TTS request failed; key rotation was not applicable. HTTP {0}: {1}" -f $status,$detail)
            }
            if ($offset -lt ($keys.Count - 1)) {
                Write-Host ("[TTS] API key {0}/{1} failed (HTTP {2}); trying the next key..." -f ($offset + 1),$keys.Count,$status) -ForegroundColor DarkYellow
            }
        }
    }
    $script:MiraTtsApiKeyIndex = ($start + 1) % $keys.Count
    throw ("Gemini TTS failed with every configured API key: " + ($failures -join ' | '))
}

function Get-GemmaTtsScene {
    $systemText = [string]$SystemInstruction.parts[0].text
    $match = [regex]::Match($systemText,'(?ims)^##[ \t]+(?:TTS scene|Scene)[ \t]*\r?\n(?<body>.*?)(?=^##[ \t]+|^COMMAND GENERATION MODE:|\z)')
    if ($match.Success) { return $match.Groups['body'].Value.Trim() }
    return ''
}

function ConvertTo-GemmaTtsLegacyTranscript {
    param([Parameter(Mandatory = $true)][string]$Transcript,[switch]$RemoveTags)
    $tagNames = 'whispers?|laughs?|sighs?|short pause|long pause|breath|gasp|cough|groan|scream|chuckles?|giggles?|yawn|grunt|pant|sob|shout|snort|tsk|hiss|phew|moan|whimper'
    if ($RemoveTags) {
        $value = [regex]::Replace($Transcript,('(?i)(?:<|\[)(?:' + $tagNames + ')(?:>|\])'),' ')
        return [regex]::Replace($value,'\s{2,}',' ').Trim()
    }
    return [regex]::Replace($Transcript,('(?i)<(' + $tagNames + ')>'),'[$1]')
}

function New-GemmaTtsSpeechPart {
    param(
        [Parameter(Mandatory = $true)][string]$Transcript,
        [string]$Style = '',
        [string]$Scene = '',
        [Parameter(Mandatory = $true)][string]$Model
    )
    $partText = $Transcript
    $part = @{ text = $partText }
    if ($Model -match '^gemini-3\.8-') {
        if (-not [string]::IsNullOrWhiteSpace($Style)) { $part.speechMetadata = @{ style = $Style } }
        return $part
    }
    if ($Model -match '^gemini-3\.1-') {
        $legacyTranscript = ConvertTo-GemmaTtsLegacyTranscript -Transcript $Transcript
        $sections = New-Object 'System.Collections.Generic.List[string]'
        [void]$sections.Add('[Audio Profile]')
        [void]$sections.Add(('Voice: ' + [string]$script:MiraTtsVoice))
        if (-not [string]::IsNullOrWhiteSpace($Scene)) { [void]$sections.Add('[Scene]'); [void]$sections.Add($Scene) }
        if (-not [string]::IsNullOrWhiteSpace($Style)) { [void]$sections.Add("[Director's Notes]"); [void]$sections.Add($Style) }
        [void]$sections.Add('[Transcript]')
        [void]$sections.Add($legacyTranscript)
        $part.text = [string]::Join([Environment]::NewLine,[string[]]$sections.ToArray())
        return $part
    }
    if ($Model -match '^gemini-2\.5-') {
        $plainTranscript = ConvertTo-GemmaTtsLegacyTranscript -Transcript $Transcript -RemoveTags
        $sections = New-Object 'System.Collections.Generic.List[string]'
        [void]$sections.Add(('Speak using the voice ' + [string]$script:MiraTtsVoice + '.'))
        if (-not [string]::IsNullOrWhiteSpace($Scene)) { [void]$sections.Add(('Scene: ' + $Scene)) }
        if (-not [string]::IsNullOrWhiteSpace($Style)) { [void]$sections.Add(("Director's notes: " + $Style)) }
        [void]$sections.Add('Read this transcript verbatim:')
        [void]$sections.Add($plainTranscript)
        $part.text = [string]::Join([Environment]::NewLine,[string[]]$sections.ToArray())
        return $part
    }
    throw "Unsupported Gemini TTS model '$Model'."
}

function Test-GemmaTtsModelRetryableFailure {
    param([string]$Message)
    return ($Message -match '(?i)HTTP (?:0|408|429|500|502|503|504)\b' -or
        $Message -match '(?i)timeout|timed out|connection reset|connection closed|name resolution|temporarily unavailable')
}
function Invoke-GemmaSpeakLatest {
    param([System.Collections.IList]$Contents)
    $transcript = Get-GemmaLatestAssistantTranscript -Contents $Contents
    if ([string]::IsNullOrWhiteSpace($transcript)) {
        [Console]::Beep(700,60)
        Write-Host '[TTS] No completed assistant reply to speak yet.' -ForegroundColor Yellow
        return
    }

    $style = Get-GemmaTtsDirectorStyle -Contents $Contents
    $scene = Get-GemmaTtsScene
    $models = @($script:MiraTtsModels)
    if ($models.Count -eq 0) { throw 'No Gemini TTS models are configured.' }
    $preferredModel = [string]$script:MiraTtsModel
    $preferredIndex = [Array]::IndexOf($models,$preferredModel)
    if ($preferredIndex -lt 0) { $preferredIndex = 0 }
    $modelOrder = @()
    for ($i = 0; $i -lt $models.Count; $i++) { $modelOrder += [string]$models[($preferredIndex + $i) % $models.Count] }

    # Reuse any model-specific cache before making an API request.
    foreach ($candidateModel in $modelOrder) {
        $script:MiraTtsModel = $candidateModel
        $candidateCache = Get-GemmaTtsCachePath -Transcript $transcript -Style $style
        if (Test-Path -LiteralPath $candidateCache -PathType Leaf) {
            Write-Host (('[TTS] Playing cached WAV ({0}; no API request)...' -f $candidateModel)) -ForegroundColor DarkGray
            Invoke-GemmaPlayTtsWave -Path $candidateCache
            return
        }
    }
    $script:MiraTtsModel = $preferredModel

    if (@(Get-GeminiApiKeys).Count -eq 0) {
        Write-Host '[TTS] Set GEMINI_API_KEY or GEMINI_APIJ. Antigravity OAuth alone cannot authenticate Gemini API TTS.' -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path -LiteralPath $script:MiraTtsAudioDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:MiraTtsAudioDirectory -Force -ErrorAction Stop | Out-Null
    }

    $response = $null
    $successfulModel = ''
    $lastFailure = ''
    try {
        foreach ($candidateModel in $modelOrder) {
            $speechPart = New-GemmaTtsSpeechPart -Transcript $transcript -Style $style -Scene $scene -Model $candidateModel
            $payload = @{
                contents = @(@{ role = 'user'; parts = @($speechPart) })
                generationConfig = @{
                    responseModalities = @('AUDIO')
                    speechConfig = @{ voiceConfig = @{ prebuiltVoiceConfig = @{ voiceName = $script:MiraTtsVoice } } }
                }
            }
            $json = $payload | ConvertTo-Json -Depth 12
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/$candidateModel`:generateContent"
            Write-Host (('[TTS] Generating speech ({0}, {1})...' -f $candidateModel,$script:MiraTtsVoice)) -ForegroundColor DarkGray
            try {
                $response = Invoke-GemmaTtsWithKeyRotation -Uri $uri -Json $json
                $successfulModel = $candidateModel
                break
            } catch {
                $lastFailure = [string]$_.Exception.Message
                if (-not (Test-GemmaTtsModelRetryableFailure -Message $lastFailure)) { throw }
                if ($candidateModel -ne $modelOrder[$modelOrder.Count - 1]) {
                    Write-Host (('[TTS] {0} failed with a retryable server error; trying the next configured model...' -f $candidateModel)) -ForegroundColor DarkYellow
                }
            }
        }
        if ($null -eq $response -or [string]::IsNullOrWhiteSpace($successfulModel)) { throw $lastFailure }
        $script:MiraTtsModel = $successfulModel
        $audioPath = Get-GemmaTtsCachePath -Transcript $transcript -Style $style
        $audioPart = @($response.candidates[0].content.parts | Where-Object { $null -ne $_.inlineData -and -not [string]::IsNullOrWhiteSpace([string]$_.inlineData.data) }) | Select-Object -First 1
        if ($null -eq $audioPart -or [string]::IsNullOrWhiteSpace([string]$audioPart.inlineData.data)) {
            $finishReason = [string]$response.candidates[0].finishReason
            throw "Gemini TTS returned no audio data. Finish reason: $finishReason"
        }
        $audioBytes = [Convert]::FromBase64String([string]$audioPart.inlineData.data)
        if ($audioBytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($audioBytes,0,4) -ne 'RIFF') { throw 'Gemini TTS response was not a complete WAV file.' }
        [IO.File]::WriteAllBytes($audioPath,$audioBytes)
        Write-Host (('[TTS] Saved WAV ({0}): {1}' -f $successfulModel,$audioPath)) -ForegroundColor DarkGray
        Invoke-GemmaPlayTtsWave -Path $audioPath
    } catch {
        $script:MiraTtsModel = $preferredModel
        Write-Host (('[TTS error] {0}' -f $_.Exception.Message)) -ForegroundColor Red
    }
}
