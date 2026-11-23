function Start-GemmaChatLoop {
# MAIN CHAT LOOP
# ==============================================================================
while ($true) {
    if ($script:OneShotCompleted) { break }
    # Single owner of the interactive input buffer.
    if ($script:OneShot) { $firstLine = $Prompt; $Prompt = $null } else { $firstLine = Read-GemLineFallback }
    if ([string]::IsNullOrWhiteSpace($firstLine)) { continue }

    $lineBuffer = [System.Collections.Generic.List[string]]::new()
    $lineBuffer.Add($firstLine)

    $rawInput = [string]::Join("`n", $lineBuffer)
    $trimmedInput = $rawInput.Trim()    # MIRA INPUT HISTORY - record accepted input
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        if ($script:MiraInputHistory.Count -ge $script:MiraHistoryMax) {
            $script:MiraInputHistory.RemoveAt(0)
        }
        [void]$script:MiraInputHistory.Add($rawInput)
    }
    $script:MiraHistoryIndex = -1
    $script:MiraHistoryDraft = ''
    $userParts = @()

    # ==========================================================================
    # SYSTEM COMMANDS
    # ==========================================================================
    if ($trimmedInput -eq ".q" -or $trimmedInput -eq "quit") { break }

    if ($trimmedInput -eq "clear" -or $trimmedInput -eq ".clear") {
        $Contents.Clear()
        Clear-Host
        Write-Host "History reset.`n" -ForegroundColor Yellow
        continue
    }

    if ($trimmedInput -ieq '.skills') {
        $skillList = Get-GemmaSkill -Name 'list'
        Write-Host ("Available skills: " + (@($skillList.skills) -join ', ')) -ForegroundColor Cyan
        Write-Host ("User skill folder: " + $skillList.user_skill_directory) -ForegroundColor DarkGray
        Write-Host "Create your own skill as a .md file in that folder." -ForegroundColor DarkGray
        continue
    }
    if ($trimmedInput -match '^\.skill\s+([a-zA-Z0-9_-]+)$') {
        $loadedSkill = Get-GemmaSkill -Name $matches[1]
        if ($loadedSkill.instructions) { Write-Host $loadedSkill.instructions -ForegroundColor Gray }
        else { Write-Host ([string]$loadedSkill.error) -ForegroundColor Yellow }
        continue
    }

    if ($trimmedInput -eq ".auth" -or $trimmedInput.StartsWith(".auth ", [StringComparison]::OrdinalIgnoreCase)) {
        $authArgument = ""
        if ($trimmedInput.Length -gt 5) { $authArgument = $trimmedInput.Substring(5).Trim() }
        Invoke-GemmaAuthCommand -Argument $authArgument
        continue
    }

    if ($trimmedInput -eq ".verbose" -or $trimmedInput.StartsWith(".verbose ", [StringComparison]::OrdinalIgnoreCase)) {
        $verboseArgument = if ($trimmedInput.Length -gt 8) { $trimmedInput.Substring(8).Trim().ToLowerInvariant() } else { '' }
        if (-not $verboseArgument) { $script:VerboseOutput = -not $script:VerboseOutput }
        elseif ($verboseArgument -in @('on','true','1','yes')) { $script:VerboseOutput = $true }
        elseif ($verboseArgument -in @('off','false','0','no')) { $script:VerboseOutput = $false }
        else { Write-Host 'Usage: .verbose [on|off]' -ForegroundColor Yellow; continue }
        Write-Host "[Verbose thought summaries: $(if ($script:VerboseOutput) { 'ON' } else { 'OFF' })]" -ForegroundColor $(if ($script:VerboseOutput) { 'Green' } else { 'Yellow' })
        continue
    }

    if ($trimmedInput -eq ".effort" -or $trimmedInput.StartsWith(".effort ", [StringComparison]::OrdinalIgnoreCase)) {
        $effortArgument = ""
        if ($trimmedInput.Length -gt 7) { $effortArgument = $trimmedInput.Substring(7).Trim() }
        Invoke-GemmaEffortCommand -Argument $effortArgument
        continue
    }

    if ($trimmedInput -ieq '.ask') {
        Invoke-GemmaPermissionCommand -Mode ask
        continue
    }
    if ($trimmedInput -ieq '.autopilot') {
        Invoke-GemmaPermissionCommand -Mode autopilot
        continue
    }

    if ($trimmedInput -eq ".sysprompt" -or $trimmedInput.StartsWith(".sysprompt ", [StringComparison]::OrdinalIgnoreCase)) {
        $systemPromptArgument = ""
        if ($trimmedInput.Length -gt ".sysprompt".Length) { $systemPromptArgument = $trimmedInput.Substring(".sysprompt".Length).Trim() }
        Invoke-GemmaSystemPromptCommand -Argument $systemPromptArgument
        continue
    }

    if ($trimmedInput -eq ".provider" -or $trimmedInput.StartsWith(".provider ", [StringComparison]::OrdinalIgnoreCase)) {
        $providerArgument = ""
        if ($trimmedInput.Length -gt 9) { $providerArgument = $trimmedInput.Substring(9).Trim() }
        Invoke-GemmaProviderCommand -Argument $providerArgument
        continue
    }

    if ($trimmedInput -eq ".grounding" -or $trimmedInput.StartsWith(".grounding ", [StringComparison]::OrdinalIgnoreCase)) {
        $searchArgument = ""
        if ($trimmedInput.Length -gt ".grounding".Length) { $searchArgument = $trimmedInput.Substring(".grounding".Length).Trim() }
        Invoke-GemmaSearchCommand -Argument $searchArgument
        continue
    }
    if ($trimmedInput -eq ".model" -or $trimmedInput.StartsWith(".model ", [StringComparison]::OrdinalIgnoreCase)) {
        $requestedModel = ""
        if ($trimmedInput.Length -gt 6) { $requestedModel = $trimmedInput.Substring(6).Trim() }
        Invoke-GeminiModelSwitcher -RequestedModel $requestedModel
        continue
    }

    if ($trimmedInput -eq "save" -or $trimmedInput -eq ".save") {
        if ($Contents.Count -gt 0) {
            $lastModelTurn = $Contents | Where-Object { $_.role -eq "model" } | Select-Object -Last 1
            if ($lastModelTurn) {
                Save-GeminiCodeBlocks -Text $lastModelTurn.parts[0].text
            } else {
                Write-Host "`n[No model reply found to extract code from]" -ForegroundColor Yellow
            }
        } else {
            Write-Host "`n[Conversation history is empty]" -ForegroundColor Yellow
        }
        continue
    }

    # ==========================================================================
    # SESSION PERSISTENCE
    # ==========================================================================
    if ($trimmedInput -eq ".exportsession" -or $trimmedInput.StartsWith(".exportsession ", [StringComparison]::OrdinalIgnoreCase)) {
        $sessionName = $trimmedInput.Substring(".exportsession".Length).Trim()
        if (-not $sessionName) { $sessionName = Get-Date -Format 'yyMMddHHmm' }
        $fileName = if ($sessionName.EndsWith(".json")) { $sessionName } else { "$sessionName.json" }

        $sessionData = @{
            SessionName = "Mira" # <-- Change this to match your session name
            Contents    = $Contents
        }
        $sessionData | ConvertTo-Json -Depth 10 | Set-Content -Path $fileName -Encoding UTF8
        Write-Host "`n[Session saved to $fileName]" -ForegroundColor Green
        continue
    }

    if ($trimmedInput.StartsWith(".loadsession")) {
        $sessionName = $trimmedInput.Substring(12).Trim()
        if (-not $sessionName) {
            Write-Host "`n[Error: Specify a session file name]" -ForegroundColor Red
            continue
        }
        $fileName = if ($sessionName.EndsWith(".json")) { $sessionName } else { "$sessionName.json" }
        if (Test-Path $fileName) {
            $jsonContent = Get-Content -Path $fileName -Raw -Encoding UTF8
            $loadedData = $jsonContent | ConvertFrom-Json
            $Contents.Clear()
            foreach ($turn in $loadedData.Contents) { [void]$Contents.Add($turn) }
            Write-Host "`n[Session loaded from $fileName]" -ForegroundColor Green
        } else {
            Write-Host "`n[Error: Session file not found -> $fileName]" -ForegroundColor Red
        }
        continue
    }

    # ==========================================================================
    # LOCAL COMMAND EXECUTION (!)
    # ==========================================================================
    if ($trimmedInput.StartsWith("!")) {
        $commandToRun = $trimmedInput.Substring(1).Trim()
        Write-Host "`n[Executing local command: $commandToRun]" -ForegroundColor DarkYellow
        try {
            $cmdOutput = Invoke-Expression $commandToRun 2>&1 | Out-String
            Write-Host $cmdOutput -ForegroundColor Gray
            $modelCmdOutput = $cmdOutput
            if ($modelCmdOutput.Length -gt $MIRA_MAX_COMMAND_OUTPUT_CHARS) { $modelCmdOutput = $modelCmdOutput.Substring(0,$MIRA_MAX_COMMAND_OUTPUT_CHARS) + "`n[Command output truncated before sending to the model]" }
            $userParts = @( @{ text = "Executed PowerShell Command: $commandToRun`nOutput:`n$modelCmdOutput" } )
        } catch {
            $errOutput = $_.Exception.Message
            Write-Host "[Error]: $errOutput" -ForegroundColor Red
            $userParts = @( @{ text = "Executed PowerShell Command: $commandToRun`nError:`n$errOutput" } )
        }
    }
    # ==========================================================================
    # TEXT OR BINARY FILE PROCESSING (.text / .file)
    # ==========================================================================
    elseif ($trimmedInput.StartsWith(".text") -or $trimmedInput.StartsWith(".file")) {
        $isBinary = $trimmedInput.StartsWith(".file")
        $remainder = $trimmedInput.Substring(5).Trim()
        $filePath = ""
        $promptText = ""

        if ([string]::IsNullOrWhiteSpace($remainder)) {
            Add-Type -AssemblyName PresentationFramework
            $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
            $openFileDialog.Multiselect = $false
            $openFileDialog.Title = "Select a file for Mira"
            if ($openFileDialog.ShowDialog() -eq $true) {
                $filePath = $openFileDialog.FileName
                $promptText = if ($isBinary) { "Analyze this attached file." } else { "Analyze this text/code." }
            } else {
                Write-Host "`n[File selection cancelled]" -ForegroundColor Yellow
                continue
            }
        } else {
            if ($remainder.StartsWith('"') -or $remainder.StartsWith("'")) {
                $quote = $remainder.Substring(0,1)
                $endIndex = $remainder.IndexOf($quote, 1)
                if ($endIndex -gt 0) {
                    $filePath = $remainder.Substring(1, $endIndex - 1)
                    if ($remainder.Length -gt ($endIndex + 1)) { $promptText = $remainder.Substring($endIndex + 1).Trim() }
                }
            } else {
                $spaceIndex = $remainder.IndexOf(" ")
                if ($spaceIndex -gt 0) {
                    $filePath = $remainder.Substring(0, $spaceIndex)
                    $promptText = $remainder.Substring($spaceIndex + 1).Trim()
                } else { $filePath = $remainder }
            }
            if (-not $promptText) { $promptText = if ($isBinary) { "Analyze this attached file." } else { "Analyze this text/code." } }
        }

        $filePath = $filePath.Trim('"').Trim("'")
        if (-not (Test-Path $filePath)) {
            Write-Host "`n[Error: File not found -> $filePath]" -ForegroundColor Red
            continue
        }

        if (-not $isBinary) {
            $fileContent = Get-Content -Path $filePath -Raw -Encoding UTF8
            Write-Host "`n[Loaded text file: $filePath]" -ForegroundColor DarkYellow
            $userParts = @( @{ text = "$promptText`n`n[File content of $filePath]:`n$fileContent" } )
        } else {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mimeType = switch ($ext) {
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".webp" { "image/webp" }
                ".pdf"  { "application/pdf" }
                ".mp3"  { "audio/mp3" }
                ".wav"  { "audio/wav" }
                ".mp4"  { "video/mp4" }
                ".csv"  { "text/csv" }
                ".html" { "text/html" }
                ".json" { "application/json" }
                default { "text/plain" }
            }
            $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
            $base64 = [Convert]::ToBase64String($fileBytes)
            Write-Host "`n[Attached file: $filePath | Type: $mimeType | Size: $($fileBytes.Length) bytes]" -ForegroundColor DarkYellow
            $userParts = @(
                @{ inline_data = @{ mime_type = $mimeType; data = $base64 } },
                @{ text = $promptText }
            )
        }
    }
    # ===========================================================================
    # FILE DIFF (.diff)
    # ===========================================================================
    elseif ($trimmedInput -eq ".diff" -or $trimmedInput.StartsWith(".diff ")) {
        $remainder = $trimmedInput.Substring(5).Trim()
        $argMatches = [regex]::Matches($remainder, '(?:"([^"]+)"|''([^'']+)''|(\S+))')
        if ($argMatches.Count -lt 2) {
            Write-Host "`n[Usage: .diff \"left\" \"right\" [prompt]]" -ForegroundColor Yellow
            continue
        }

        $left = if ($argMatches[0].Groups[1].Success) { $argMatches[0].Groups[1].Value } elseif ($argMatches[0].Groups[2].Success) { $argMatches[0].Groups[2].Value } else { $argMatches[0].Groups[3].Value }
        $right = if ($argMatches[1].Groups[1].Success) { $argMatches[1].Groups[1].Value } elseif ($argMatches[1].Groups[2].Success) { $argMatches[1].Groups[2].Value } else { $argMatches[1].Groups[3].Value }

        $rightEnd = $argMatches[1].Index + $argMatches[1].Length
        $promptText = if ($rightEnd -lt $remainder.Length) { $remainder.Substring($rightEnd).Trim() } else { "" }

        if (-not (Test-Path -LiteralPath $left)) {
            Write-Host "`n[Error: File not found -> $left]" -ForegroundColor Red
            continue
        }
        if (-not (Test-Path -LiteralPath $right)) {
            Write-Host "`n[Error: File not found -> $right]" -ForegroundColor Red
            continue
        }

        try {
            $leftLines = @(Get-Content -LiteralPath $left -Encoding UTF8)
            $rightLines = @(Get-Content -LiteralPath $right -Encoding UTF8)
            $cmp = @(Compare-Object $leftLines $rightLines)
            $diffLines = New-Object System.Collections.Generic.List[string]
            [void]$diffLines.Add("DIFF: $left <-> $right")
            foreach ($x in $cmp) {
                $prefix = if ($x.SideIndicator -eq '<=') { '- ' } else { '+ ' }
                [void]$diffLines.Add($prefix + [string]$x.InputObject)
            }
            if ($diffLines.Count -eq 1) {
                [void]$diffLines.Add('Files are identical.')
            }

            if ([string]::IsNullOrWhiteSpace($promptText)) {
                $promptText = 'Analyze this diff and explain the important changes. Preserve factual accuracy and distinguish additions, removals, and unchanged behavior.'
            }
            $userParts = @( @{ text = "$promptText`n`n$([string]::Join("`n",$diffLines))" } )
        }
        catch {
            Write-Host "`n[Diff failed]: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
    }
    # ==========================================================================
    # SCREENSHOT FROM CLIPBOARD (.shot)
    # ==========================================================================
    elseif ($trimmedInput -eq ".shot" -or $trimmedInput.StartsWith(".shot ")) {
        Add-Type -AssemblyName System.Windows.Forms
        $clipImage = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -eq $clipImage) {
            Write-Host "`n[No image found on clipboard]" -ForegroundColor Red
            continue
        }
        $promptText = "Analyze this screenshot."
        if ($trimmedInput.Length -gt 5) { $promptText = $trimmedInput.Substring(5).Trim() }
        $ms = New-Object System.IO.MemoryStream
        $clipImage.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $fileBytes = $ms.ToArray()
        $ms.Dispose()
        $clipImage.Dispose()
        $base64 = [Convert]::ToBase64String($fileBytes)
        Write-Host "`n[Captured screenshot from clipboard: $($fileBytes.Length) bytes]" -ForegroundColor DarkYellow
        $userParts = @(
            @{ inline_data = @{ mime_type = "image/png"; data = $base64 } },
            @{ text = $promptText }
        )
    }
    # ==========================================================================
    # STANDARD CHAT INPUT
    # ==========================================================================
    else {
        $userParts = @( @{ text = $rawInput } )
    }

    # Snapshot the conversation before this turn.
    $turnStartCount = $Contents.Count
    $userTurn = @{ role = "user"; parts = $userParts }
    [void]$Contents.Add($userTurn)

    # ===========================================================================
. (Join-Path $PSScriptRoot 'Turn.ps1')

}
}
