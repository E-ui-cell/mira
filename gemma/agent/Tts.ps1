# WINDOWS POWERSHELL 5.1
# On-demand Gemini 3.8 Flash TTS playback.

$script:MiraTtsModel = $MIRA_TTS_MODEL
$script:MiraTtsVoice = $MIRA_TTS_VOICE
$script:MiraTtsDirectorCore = $MIRA_TTS_DIRECTOR_CORE

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
    $context = [regex]::Replace($context,'(?s)```.*?```',' ')
    $context = [regex]::Replace($context,'[\r\n\t]+',' ')
    $context = [regex]::Replace($context,'\s{2,}',' ').Trim()
    if ($context.Length -gt 120) { $context = $context.Substring(0,117).TrimEnd() + '...' }
    if ($context) { return "$script:MiraTtsDirectorCore Context: $context" }
    return $script:MiraTtsDirectorCore
}

function Invoke-GemmaSpeakLatest {
    param([System.Collections.IList]$Contents)
    $transcript = [string]$script:LastAssistantReply
    if ([string]::IsNullOrWhiteSpace($transcript) -and $null -ne $Contents) {
        for ($i = $Contents.Count - 1; $i -ge 0; $i--) {
            $turn = $Contents[$i]
            if ($turn.role -ne 'model' -or $null -eq $turn.parts) { continue }
            $textParts = @(
                foreach ($part in $turn.parts) {
                    if ($null -ne $part.text -and -not [string]::IsNullOrWhiteSpace([string]$part.text)) { [string]$part.text }
                }
            )
            if ($textParts.Count -gt 0) { $transcript = $textParts -join [Environment]::NewLine; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($transcript)) {
        [Console]::Beep(700,60)
        Write-Host '[TTS] No assistant response to speak yet.' -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($API_KEY)) {
        Write-Host '[TTS] Set GEMINI_API or GEMINI_API_KEY. Antigravity OAuth alone cannot authenticate Gemini API TTS.' -ForegroundColor Yellow
        return
    }
    $style = Get-GemmaTtsDirectorStyle -Contents $Contents
    $payload = @{
        contents = @(@{ role = 'user'; parts = @(@{ text = $transcript; speechMetadata = @{ style = $style } }) })
        generationConfig = @{
            responseModalities = @('AUDIO')
            speechConfig = @{ voiceConfig = @{ prebuiltVoiceConfig = @{ voiceName = $script:MiraTtsVoice } } }
        }
    }
    $json = $payload | ConvertTo-Json -Depth 12
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($script:MiraTtsModel):generateContent"
    $tempWave = Join-Path ([IO.Path]::GetTempPath()) ("gemma-tts-" + [guid]::NewGuid().ToString('N') + '.wav')
    $player = $null
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
        [IO.File]::WriteAllBytes($tempWave,$audioBytes)
        $player = [System.Media.SoundPlayer]::new($tempWave)
        $player.Load()
        $player.PlaySync()
    }
    catch { Write-Host ("[TTS error] {0}" -f $_.Exception.Message) -ForegroundColor Red }
    finally {
        if ($null -ne $player) { try { $player.Dispose() } catch {} }
        if (Test-Path -LiteralPath $tempWave) { try { Remove-Item -LiteralPath $tempWave -Force -ErrorAction SilentlyContinue } catch {} }
    }
}
