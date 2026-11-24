function Read-GemmaModelSelection {
    param(
        [object[]]$Models,
        [string]$CurrentModel
    )

    if ($Models.Count -eq 0) { return -1 }

    $modelIds = @(
        foreach ($item in $Models) {
            ([string]$item.name -replace '^models/','')
        }
    )
    $selectedIndex = 0
    for ($i = 0; $i -lt $modelIds.Count; $i++) {
        if ($modelIds[$i] -ieq $CurrentModel) { $selectedIndex = $i; break }
    }

    $interactive = $false
    try {
        $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    } catch {}
    if (-not $interactive) {
        for ($i = 0; $i -lt $modelIds.Count; $i++) {
            $marker = if ($i -eq $selectedIndex) { '  [CURRENT]' } else { '' }
            Write-Host ('  {0,3}. {1}{2}' -f ($i + 1),$modelIds[$i],$marker)
        }
        $selection = Read-Host 'Select model number or exact model ID; Enter cancels'
        if ([string]::IsNullOrWhiteSpace($selection)) { return -1 }
        $selection = $selection.Trim() -replace '^models/',''
        if ($selection -match '^\d+$') {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $modelIds.Count) { return $index }
            return -1
        }
        for ($i = 0; $i -lt $modelIds.Count; $i++) {
            if ($modelIds[$i] -ieq $selection) { return $i }
        }
        return -1
    }

    $windowHeight = [Math]::Max(10,[Console]::WindowHeight)
    $visibleRows = [Math]::Max(1,[Math]::Min(12,$windowHeight - 6))
    $visibleRows = [Math]::Min($visibleRows,$modelIds.Count)
    $menuHeight = $visibleRows + 3
    $windowTop = [Console]::WindowTop
    $top = [Console]::CursorTop
    $viewportBottom = $windowTop + $windowHeight
    $spaceBelow = $viewportBottom - $top
    if ($spaceBelow -lt ($menuHeight + 1)) {
        $paddingRows = ($menuHeight + 1) - $spaceBelow
        [Console]::Write(([Environment]::NewLine * $paddingRows))
        $top = [Console]::CursorTop
    }

    $oldForeground = [Console]::ForegroundColor
    $oldBackground = [Console]::BackgroundColor
    $cancelled = $false
    $confirmed = $false

    function Draw-GemmaModelMenu {
        $first = [Math]::Max(0,[Math]::Min(
            $selectedIndex - [int][Math]::Floor($visibleRows / 2),
            $modelIds.Count - $visibleRows
        ))
        $last = $first + $visibleRows
        $clearWidth = [Math]::Max(1,[Console]::WindowWidth - 1)
        [Console]::SetCursorPosition(0,$top)

        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        $title = 'Models - all providers'
        [Console]::Write($title.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write(('Up/Down or j/k move; Enter select; Esc or q cancel').PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        for ($row = 0; $row -lt $visibleRows; $row++) {
            $index = $first + $row
            $line = ''
            if ($index -lt $last) {
                $marker = if ($index -eq $selectedIndex) { '>' } else { ' ' }
                $current = if ($modelIds[$index] -ieq $CurrentModel) { '  [current]' } else { '' }
                $line = (' {0} {1}{2}' -f $marker,$modelIds[$index],$current)
                if ($line.Length -gt $clearWidth) {
                    $line = $line.Substring(0,$clearWidth)
                }
            }
            if ($index -eq $selectedIndex) {
                [Console]::ForegroundColor = [ConsoleColor]::White
                [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
            } else {
                [Console]::ForegroundColor = [ConsoleColor]::Gray
                [Console]::BackgroundColor = $oldBackground
            }
            [Console]::Write($line.PadRight($clearWidth).Substring(0,$clearWidth))
            [Console]::WriteLine()
        }

        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        $footer = (' {0}/{1} ' -f ($selectedIndex + 1),$modelIds.Count)
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write($footer.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::SetCursorPosition(0,[Math]::Min($top + $menuHeight,[Console]::BufferHeight - 1))
    }

    try {
        Draw-GemmaModelMenu
        while (-not $confirmed -and -not $cancelled) {
            $key = [Console]::ReadKey($true)
            $character = [char]::ToLowerInvariant($key.KeyChar)

            if ($key.Key -eq [ConsoleKey]::UpArrow -or $character -eq 'k') {
                $selectedIndex = [Math]::Max(0,$selectedIndex - 1)
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::DownArrow -or $character -eq 'j') {
                $selectedIndex = [Math]::Min($modelIds.Count - 1,$selectedIndex + 1)
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::Home) {
                $selectedIndex = 0
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::End) {
                $selectedIndex = $modelIds.Count - 1
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::PageUp) {
                $selectedIndex = [Math]::Max(0,$selectedIndex - $visibleRows)
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::PageDown) {
                $selectedIndex = [Math]::Min($modelIds.Count - 1,$selectedIndex + $visibleRows)
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                $confirmed = $true
            } elseif ($key.Key -eq [ConsoleKey]::Escape -or $character -eq 'q') {
                $cancelled = $true
            }
        }
    } finally {
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        [Console]::SetCursorPosition(0,[Math]::Min($top + $menuHeight,[Console]::BufferHeight - 1))
        [Console]::WriteLine()
    }

    if ($cancelled) { return -1 }
    return $selectedIndex
}

function Invoke-GeminiModelSwitcher {
    param([string]$RequestedModel = "")

    # Remember the last Gemini-side provider so the combined picker can show
    # its catalogue even while OpenAI is currently selected.
    if ($script:Provider -ne 'openai') {
        $script:GemmaLastGeminiProvider = $script:Provider
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:GemmaLastGeminiProvider)) {
        $script:GemmaLastGeminiProvider = 'gemini'
    }

    $openAIModel = [string]$MIRA_OPENAI_DEFAULT_MODEL
    if ([string]::IsNullOrWhiteSpace($openAIModel)) {
        Write-Host '[OpenAI default model is not configured in Defaults.ps1.]' -ForegroundColor Yellow
        return
    }

    # Direct model selection: .model <id>
    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
        $selectedModel = $RequestedModel.Trim() -replace '^models/',''
        if ($selectedModel -ieq $openAIModel) {
            if (@(Get-GemmaOpenAIApiKeys).Count -eq 0) {
                Write-Host '[OpenAI API key is not set. Configure OPENAI_API_KEY or OPENAI_API_KEYS.]' -ForegroundColor Yellow
                return
            }
            $script:Provider = 'openai'
            $script:MODEL = $openAIModel
        } else {
            $targetProvider = [string]$script:GemmaLastGeminiProvider
            if ($targetProvider -notin @('antigravity','gemini')) { $targetProvider = 'gemini' }
            if ($targetProvider -eq 'antigravity' -and -not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
                $targetProvider = 'gemini'
            }
            if ($targetProvider -eq 'gemini' -and @(Get-GeminiApiKeys).Count -eq 0) {
                Write-Host '[Gemini API key is not set. Configure GEMINI_API or GEMINI_API_KEYS.]' -ForegroundColor Yellow
                return
            }
            $script:Provider = $targetProvider
            $script:GemmaLastGeminiProvider = $targetProvider
            $script:MODEL = $selectedModel
        }
        Write-Host (([Environment]::NewLine) + '[Provider: ' + $script:Provider + ' | Model: ' + $script:MODEL + ']') -ForegroundColor Green
        return
    }

    try {
        # The OpenAI catalogue is deliberately static: one configured model,
        # pinned first. Only the Gemini-side catalogue is fetched.
        $models = New-Object 'System.Collections.Generic.List[object]'
        [void]$models.Add([pscustomobject]@{
            name = $openAIModel
            displayName = 'GPT-6 Luna'
            provider = 'openai'
        })

        $catalogProvider = [string]$script:GemmaLastGeminiProvider
        if ($catalogProvider -notin @('antigravity','gemini')) { $catalogProvider = 'gemini' }
        $originalProvider = $script:Provider
        try {
            $script:Provider = $catalogProvider
            $geminiModels = @(Get-GeminiModels)
        } finally {
            $script:Provider = $originalProvider
        }

        foreach ($item in $geminiModels) {
            $id = ([string]$item.name -replace '^models/','')
            if ([string]::IsNullOrWhiteSpace($id) -or $id -ieq $openAIModel) { continue }
            [void]$models.Add([pscustomobject]@{
                name = $id
                displayName = if ($item.displayName) { [string]$item.displayName } else { $id }
                provider = $catalogProvider
            })
        }

        $availableModels = $models.ToArray()
        $selectedIndex = Read-GemmaModelSelection -Models $availableModels -CurrentModel $script:MODEL
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $availableModels.Count) { return }

        $selected = $availableModels[$selectedIndex]
        $selectedModel = [string]$selected.name
        $targetProvider = [string]$selected.provider
        if ($targetProvider -eq 'openai') {
            if (@(Get-GemmaOpenAIApiKeys).Count -eq 0) {
                Write-Host '[OpenAI API key is not set. Configure OPENAI_API_KEY or OPENAI_API_KEYS.]' -ForegroundColor Yellow
                return
            }
        } elseif ($targetProvider -eq 'gemini') {
            if (@(Get-GeminiApiKeys).Count -eq 0) {
                Write-Host '[Gemini API key is not set. Configure GEMINI_API or GEMINI_API_KEYS.]' -ForegroundColor Yellow
                return
            }
        } elseif ($targetProvider -eq 'antigravity') {
            if (-not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
                Write-Host '[Antigravity is not authenticated. Run .auth login first.]' -ForegroundColor Yellow
                return
            }
        }

        $script:Provider = $targetProvider
        if ($targetProvider -ne 'openai') { $script:GemmaLastGeminiProvider = $targetProvider }
        $script:MODEL = $selectedModel
        Write-Host (([Environment]::NewLine) + '[Provider: ' + $script:Provider + ' | Model: ' + $script:MODEL + ']') -ForegroundColor Green
    } catch {
        Write-Host (([Environment]::NewLine) + '[Could not fetch/switch models]: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
