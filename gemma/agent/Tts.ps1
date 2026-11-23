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
    return (Join-Path $script:MiraTtsAudioDirectory ($key + '.wav'))
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
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ 'x-goog-api-key' = $API_KEY } -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 120 -ErrorAction Stop
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
