# WINDOWS POWERSHELL 5.1
# On-demand Gemini 3.8 Flash TTS with a permanent, content-addressed WAV cache.

$script:MiraTtsModel = $MIRA_TTS_MODEL
$script:MiraTtsVoice = $MIRA_TTS_VOICE
$script:MiraTtsDirectorCore = $MIRA_TTS_DIRECTOR_CORE
$script:MiraTtsAudioDirectory = Join-Path $HOME '.gemma\audio'

function Get-GemmaTtsDirectorStyle {
    param([System.Collections.IList]$Contents)
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
    if ($context) { return "$script:MiraTtsDirectorCore Context: $context" }
    return $script:MiraTtsDirectorCore
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

function Invoke-GemmaPlayTtsWave {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "[TTS] Audio file not found: $Path" -ForegroundColor Yellow
        return
    }

    $player = $null
    try {
        $player = [System.Media.SoundPlayer]::new($Path)
        $player.Load()
        $player.PlaySync()
    }
    catch {
        Write-Host ("[TTS playback error] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        if ($null -ne $player) { try { $player.Dispose() } catch {} }
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
        Write-Host '[TTS] No cached audio for this reply. Press Tab to generate it once.' -ForegroundColor Yellow
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
    if ($keys.Count -eq 0) { throw 'No Gemini API key configured. Set GEMINI_API or GEMINI_API_KEYS.' }

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

function Invoke-GemmaSpeakLatest {
    param([System.Collections.IList]$Contents)
    $transcript = Get-GemmaLatestAssistantTranscript -Contents $Contents
    if ([string]::IsNullOrWhiteSpace($transcript)) {
        [Console]::Beep(700,60)
        Write-Host '[TTS] No completed assistant reply to speak yet.' -ForegroundColor Yellow
        return
    }

    $style = Get-GemmaTtsDirectorStyle -Contents $Contents
    $audioPath = Get-GemmaTtsCachePath -Transcript $transcript -Style $style

    # Cache-first: a repeat Tab press replays the same WAV without another request.
    if (Test-Path -LiteralPath $audioPath -PathType Leaf) {
        Write-Host '[TTS] Playing cached WAV (no API request)...' -ForegroundColor DarkGray
        Invoke-GemmaPlayTtsWave -Path $audioPath
        return
    }

    if ([string]::IsNullOrWhiteSpace($API_KEY)) {
        Write-Host '[TTS] Set GEMINI_API or GEMINI_API_KEY. Antigravity OAuth alone cannot authenticate Gemini API TTS.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $script:MiraTtsAudioDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:MiraTtsAudioDirectory -Force -ErrorAction Stop | Out-Null
    }

    $payload = @{
        contents = @(@{ role = 'user'; parts = @(@{ text = $transcript; speechMetadata = @{ style = $style } }) })
        generationConfig = @{
            responseModalities = @('AUDIO')
            speechConfig = @{ voiceConfig = @{ prebuiltVoiceConfig = @{ voiceName = $script:MiraTtsVoice } } }
        }
    }
    $json = $payload | ConvertTo-Json -Depth 12
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($script:MiraTtsModel):generateContent"
    Write-Host ("[TTS] Generating speech ({0}, {1})..." -f $script:MiraTtsModel,$script:MiraTtsVoice) -ForegroundColor DarkGray
    try {
        $response = Invoke-GemmaTtsWithKeyRotation -Uri $uri -Json $json
        $audioPart = @($response.candidates[0].content.parts | Where-Object { $null -ne $_.inlineData -and -not [string]::IsNullOrWhiteSpace([string]$_.inlineData.data) }) | Select-Object -First 1
        if ($null -eq $audioPart -or [string]::IsNullOrWhiteSpace([string]$audioPart.inlineData.data)) {
            $finishReason = [string]$response.candidates[0].finishReason
            throw "Gemini TTS returned no audio data. Finish reason: $finishReason"
        }
        $audioBytes = [Convert]::FromBase64String([string]$audioPart.inlineData.data)
        if ($audioBytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($audioBytes,0,4) -ne 'RIFF') { throw 'Gemini TTS response was not a complete WAV file.' }

        # Store the generated WAV permanently; do not delete it after playback.
        [IO.File]::WriteAllBytes($audioPath,$audioBytes)
        Write-Host ("[TTS] Saved WAV: {0}" -f $audioPath) -ForegroundColor DarkGray
        Invoke-GemmaPlayTtsWave -Path $audioPath
    }
    catch { Write-Host ("[TTS error] {0}" -f $_.Exception.Message) -ForegroundColor Red }
}
