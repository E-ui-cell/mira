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
        $title = 'Models - ' + $script:Provider
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

    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
        $selectedModel = $RequestedModel.Trim() -replace '^models/', ''
        $script:MODEL = $selectedModel
        Write-Host (([Environment]::NewLine) + '[Model switched to: ' + $script:MODEL + ']') -ForegroundColor Green
        return
    }

    try {
        $availableModels = @(Get-GeminiModels)
        if ($availableModels.Count -eq 0) {
            Write-Host '[No models available.]' -ForegroundColor Yellow
            return
        }

        $selectedIndex = Read-GemmaModelSelection -Models $availableModels -CurrentModel $script:MODEL
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $availableModels.Count) { return }

        $selectedModel = [string]$availableModels[$selectedIndex].name -replace '^models/', ''
        if ($selectedModel -ieq $script:MODEL) { return }

        $script:MODEL = $selectedModel
        Write-Host (([Environment]::NewLine) + '[Model switched to: ' + $script:MODEL + ']') -ForegroundColor Green
    } catch {
        Write-Host (([Environment]::NewLine) + '[Could not fetch/switch models]: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
