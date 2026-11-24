function Invoke-GemmaEffortCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) {
        Write-Host "[Effort: $script:Effort]" -ForegroundColor Cyan
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor DarkGray
        return
    }
    if ($value -notin @('low','medium','high')) {
        Write-Host 'Usage: .effort low | .effort medium | .effort high' -ForegroundColor Yellow
        return
    }
    $script:Effort = $value
    $effectiveEffort = Get-GemmaRequestEffort -Provider $script:Provider
    Write-Host "[Shared effort set to: $script:Effort | active request effort: $effectiveEffort]" -ForegroundColor Green
}

function Invoke-GemmaProviderCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if (-not $value) { Write-Host "[Provider: $script:Provider | Model: $script:MODEL]" -ForegroundColor Cyan; Write-Host 'Usage: .provider antigravity | .provider gemini | .provider openai' -ForegroundColor DarkGray; return }
    if ($value -notin @('antigravity','gemini','openai')) { Write-Host 'Usage: .provider antigravity | .provider gemini | .provider openai' -ForegroundColor Yellow; return }
    if ($value -eq 'antigravity' -and -not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) { Write-Host '[Antigravity is not authenticated. Run .auth login first.]' -ForegroundColor Yellow; return }
    if ($value -eq 'gemini' -and @(Get-GeminiApiKeys).Count -eq 0) { Write-Host '[Gemini API key is not set. Set GEMINI_API or GEMINI_API_KEYS before switching.]' -ForegroundColor Yellow; return }
    if ($value -eq 'openai' -and @(Get-GemmaOpenAIApiKeys).Count -eq 0) { Write-Host '[OpenAI API key is not set. Set OPENAI_API_KEY or OPENAI_API_KEYS before switching.]' -ForegroundColor Yellow; return }
    if ($value -eq 'openai' -and $script:MODEL -match '(?i)^gemini[-.]') { $script:MODEL = $MIRA_OPENAI_DEFAULT_MODEL }
    if ($value -ne 'openai' -and $script:MODEL -match '(?i)^gpt[-.]') { $script:MODEL = $MIRA_DEFAULT_MODEL }
    $script:Provider = $value
    Write-Host "[Provider switched to: $script:Provider]" -ForegroundColor Green
    Write-Host '[Model name retained; use .model to select from this provider catalogue.]' -ForegroundColor DarkGray
    $effectiveEffort = Get-GemmaRequestEffort -Provider $value
    Write-Host "[Reasoning effort: $effectiveEffort (provider override or shared .effort setting).]" -ForegroundColor DarkGray
}


function Invoke-GemmaSystemPromptCommand {
    param([string]$Argument = '')

    $value = $Argument.Trim()
    $available = @('default')
    if (Test-Path -LiteralPath $script:GemmaPromptDirectory -PathType Container) {
        $available += @(
            Get-ChildItem -LiteralPath $script:GemmaPromptDirectory -Filter '*.md' -File |
                ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } |
                Sort-Object
        )
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host ("[System prompt: {0}]" -f $script:ActiveSystemPromptName) -ForegroundColor Cyan
        Write-Host ("Available presets: " + ($available -join ', ')) -ForegroundColor DarkGray
        Write-Host 'Usage: .sysprompt <name> | .sysprompt default' -ForegroundColor DarkGray
        return
    }

    if ($value -ieq 'default') {
        $SystemInstruction.parts[0].text = [string]$MIRA_DEFAULT_SYSTEM_PROMPT
        if ($script:CommandMode) {
            $SystemInstruction.parts[0].text += @"

COMMAND GENERATION MODE:
Return only the best ready-to-run Windows PowerShell command or short command chain for the user's request.
Do not execute commands, call tools, inspect the machine, or claim anything was executed.
Use PowerShell syntax, not Bash or CMD syntax. Prefer concise native commands.
For locating a file and showing it in Explorer, use Get-ChildItem and explorer.exe /select, with a quoted full path.
Output no Markdown fences, no explanation, and no alternatives unless one command cannot safely express the task.
"@
        }
        $script:ActiveSystemPromptName = 'default'
        Write-Host '[System prompt reset to default.]' -ForegroundColor Green
        return
    }

    if ($value -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Host 'Invalid preset name. Use .sysprompt to list available presets.' -ForegroundColor Yellow
        return
    }

    $promptPath = Join-Path $script:GemmaPromptDirectory ($value + '.md')
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        Write-Host ("Unknown system prompt '{0}'. Available: {1}" -f $value,($available -join ', ')) -ForegroundColor Yellow
        return
    }

    try {
        $promptText = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($promptText)) {
            Write-Host ("System prompt '{0}' is empty; active prompt unchanged." -f $value) -ForegroundColor Yellow
            return
        }
        $SystemInstruction.parts[0].text = $promptText.Trim()
        $script:ActiveSystemPromptName = [System.IO.Path]::GetFileNameWithoutExtension($promptPath)
        Write-Host ("[System prompt switched to: {0}]" -f $script:ActiveSystemPromptName) -ForegroundColor Green
    } catch {
        Write-Host ("[Could not load system prompt: {0}]" -f $_.Exception.Message) -ForegroundColor Red
    }
}
