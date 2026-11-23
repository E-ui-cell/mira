# MIRA TUI CORE
# Ported from backups/mira-tui-1.0.5-fat-shell.ps1.
# Shared terminal backend and temporary completion-pane renderer.
# Windows PowerShell 5.1 / PowerShell 7; no external module dependency.

$script:GemTuiUseVtCursor = $false
try {
    if ($env:WT_SESSION -or $env:ConEmuANSI -eq 'ON' -or $env:TERM) {
        $script:GemTuiUseVtCursor = $true
    }
} catch {}

function Set-GemTuiCursorPosition {
    param([int]$X,[int]$Y)

    try {
        if ($script:GemTuiUseVtCursor) {
            [Console]::Write(([char]27).ToString() + '[' + ($Y + 1) + ';' + ($X + 1) + 'H')
        } else {
            [Console]::SetCursorPosition($X,$Y)
        }
        return $true
    } catch {
        try {
            [Console]::SetCursorPosition($X,$Y)
            return $true
        } catch { return $false }
    }
}

function Get-GemTuiCursorTop {
    try { return [Console]::CursorTop } catch {
        try { return [int]$Host.UI.RawUI.CursorPosition.Y } catch { return 0 }
    }
}

function Get-GemTuiWindowWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 0) { return $width }
    } catch {}
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -gt 0) { return $width }
    } catch {}
    return 80
}

function Get-GemTuiWindowHeight {
    try {
        $height = [Console]::WindowHeight
        if ($height -gt 0) { return $height }
    } catch {}
    try {
        $height = $Host.UI.RawUI.WindowSize.Height
        if ($height -gt 0) { return $height }
    } catch {}
    return 25
}

function Get-GemTuiWindowTop {
    try { return [Console]::WindowTop } catch {
        try { return [int]$Host.UI.RawUI.WindowPosition.Y } catch { return 0 }
    }
}

function Get-GemTuiBufferHeight {
    try {
        $height = [Console]::BufferHeight
        if ($height -gt 0) { return $height }
    } catch {}
    try {
        $height = $Host.UI.RawUI.BufferSize.Height
        if ($height -gt 0) { return $height }
    } catch {}
    return (Get-GemTuiWindowTop) + (Get-GemTuiWindowHeight)
}

function Read-GemTuiKey {
    try {
        return [Console]::ReadKey($true)
    } catch {
        $raw = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $mods = [ConsoleModifiers]0
        $state = [int]$raw.ControlKeyState
        if (($state -band 16) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Shift }
        if (($state -band 12) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Control }
        if (($state -band 3) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Alt }
        return New-Object PSObject -Property @{
            Key = [ConsoleKey][int]$raw.VirtualKeyCode
            KeyChar = [char]$raw.Character
            Modifiers = $mods
        }
    }
}

function Test-GemTuiKeyAvailable {
    try { return [Console]::KeyAvailable } catch {
        try { return [bool]$Host.UI.RawUI.KeyAvailable } catch { return $false }
    }
}

function Get-GemTuiCompletionLayout {
    param(
        [string[]]$Items,
        [int]$PromptRow
    )

    $width = [Math]::Max(40,(Get-GemTuiWindowWidth))
    $windowHeight = [Math]::Max(10,(Get-GemTuiWindowHeight))
    $windowTop = Get-GemTuiWindowTop
    $windowBottom = $windowTop + $windowHeight
    $maxRows = [Math]::Max(1,[Math]::Min(8,$windowHeight - 6))

    $maxName = 1
    foreach ($item in $Items) {
        if ($null -ne $item -and ([string]$item).Length -gt $maxName) {
            $maxName = ([string]$item).Length
        }
    }

    # Keep columns useful on narrow consoles and stop one long path from
    # forcing every other candidate into a single-column list.
    $targetCellWidth = [Math]::Max(14,[Math]::Min(34,$maxName + 3))
    $columns = [Math]::Max(1,[Math]::Min(4,[int][Math]::Floor(($width - 4) / [double]$targetCellWidth)))
    $innerWidth = [Math]::Max(1,$width - 2)
    $cellWidth = [Math]::Max(1,[int][Math]::Floor($innerWidth / [double]$columns))

    $visibleRows = [Math]::Min($maxRows,[Math]::Max(1,[int][Math]::Ceiling($Items.Count / [double]($columns * $maxRows))))
    $menuHeight = $visibleRows + 3
    $below = $windowBottom - ($PromptRow + 1)
    $above = $PromptRow - $windowTop

    if ($below -ge $menuHeight) {
        $top = $PromptRow + 1
    } elseif ($above -ge $menuHeight) {
        $top = $PromptRow - $menuHeight
    } else {
        $available = [Math]::Max(1,[Math]::Max($below,$above) - 3)
        $visibleRows = [Math]::Max(1,[Math]::Min($visibleRows,$available))
        $menuHeight = $visibleRows + 3
        if ($below -ge $above) { $top = $PromptRow + 1 } else { $top = [Math]::Max($windowTop,$PromptRow - $menuHeight) }
    }

    return [pscustomobject]@{
        Top = [int]$top
        Rows = [int]$visibleRows
        Columns = [int]$columns
        CellWidth = [int]$cellWidth
        Width = [int]$width
        Height = [int]$menuHeight
        PageSize = [int]($visibleRows * $columns)
        ItemCount = [int]$Items.Count
    }
}

function Clear-GemTuiCompletionMenu {
    param([object]$Layout)

    if ($null -eq $Layout) { return }
    $clearWidth = [Math]::Max(1,[int]$Layout.Width - 1)
    for ($rowIndex = 0; $rowIndex -lt [int]$Layout.Height; $rowIndex++) {
        if (Set-GemTuiCursorPosition -X 0 -Y ([int]$Layout.Top + $rowIndex)) {
            [Console]::Write((' ' * $clearWidth))
        }
    }
}

function Draw-GemTuiCompletionMenu {
    param(
        [string[]]$Items,
        [int]$SelectedIndex,
        [object]$Layout,
        [string]$Kind = 'completion'
    )

    if ($null -eq $Layout -or $Items.Count -eq 0) { return }
    $oldForeground = [Console]::ForegroundColor
    $oldBackground = [Console]::BackgroundColor
    $width = [int]$Layout.Width
    $clearWidth = [Math]::Max(1,$width - 1)
    $pageSize = [Math]::Max(1,[int]$Layout.PageSize)
    $pageStart = [int]([Math]::Floor($SelectedIndex / [double]$pageSize) * $pageSize)
    $pageNumber = [int][Math]::Floor($SelectedIndex / [double]$pageSize) + 1
    $pageCount = [int][Math]::Ceiling($Items.Count / [double]$pageSize)

    $tl = [string][char]0x250C
    $tr = [string][char]0x2510
    $bl = [string][char]0x2514
    $br = [string][char]0x2518
    $hz = [string][char]0x2500
    $vt = [string][char]0x2502

    $title = (' {0}  {1}  {2}/{3} ' -f $Kind,$Items.Count,($SelectedIndex + 1),$Items.Count)
    $headerInner = [Math]::Max(0,$clearWidth - 2)
    if ($title.Length -gt $headerInner) { $title = $title.Substring(0,$headerInner) }
    $header = $tl + $title + ($hz * [Math]::Max(0,$headerInner - $title.Length)) + $tr

    $hint = ' j/k or Up/Down move   Enter select   Esc cancel '
    if ($hint.Length -gt $headerInner) { $hint = $hint.Substring(0,$headerInner) }
    $hintLine = $vt + $hint.PadRight($headerInner) + $vt

    try {
        if (-not (Set-GemTuiCursorPosition -X 0 -Y ([int]$Layout.Top))) { return }
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        [Console]::BackgroundColor = $oldBackground
        [Console]::Write($header.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write($hintLine.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        for ($rowIndex = 0; $rowIndex -lt [int]$Layout.Rows; $rowIndex++) {
            if (-not (Set-GemTuiCursorPosition -X 0 -Y ([int]$Layout.Top + 2 + $rowIndex))) { continue }
            [Console]::Write($vt)
            for ($columnIndex = 0; $columnIndex -lt [int]$Layout.Columns; $columnIndex++) {
                $itemIndex = $pageStart + $rowIndex + ($columnIndex * [int]$Layout.Rows)
                $cellWidth = [int]$Layout.CellWidth
                if ($columnIndex -eq ([int]$Layout.Columns - 1)) {
                    $cellWidth = $headerInner - ($columnIndex * [int]$Layout.CellWidth)
                }
                $cellWidth = [Math]::Max(1,$cellWidth)
                if ($itemIndex -lt $Items.Count) {
                    $label = [string]$Items[$itemIndex]
                    $prefix = if ($itemIndex -eq $SelectedIndex) { '> ' } else { '  ' }
                    $labelWidth = [Math]::Max(0,$cellWidth - $prefix.Length)
                    if ($label.Length -gt $labelWidth) {
                        if ($labelWidth -gt 1) { $label = $label.Substring(0,$labelWidth - 1) + [string][char]0x2026 }
                        else { $label = $label.Substring(0,$labelWidth) }
                    }
                    $cell = $prefix + $label
                    if ($itemIndex -eq $SelectedIndex) {
                        [Console]::ForegroundColor = [ConsoleColor]::White
                        [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
                    } else {
                        [Console]::ForegroundColor = [ConsoleColor]::Gray
                        [Console]::BackgroundColor = $oldBackground
                    }
                    [Console]::Write($cell.PadRight($cellWidth))
                    [Console]::ForegroundColor = [ConsoleColor]::Gray
                    [Console]::BackgroundColor = $oldBackground
                } else {
                    [Console]::Write((' ' * $cellWidth))
                }
            }
            [Console]::ForegroundColor = [ConsoleColor]::DarkGray
            [Console]::BackgroundColor = $oldBackground
            [Console]::Write($vt)
        }

        if (-not (Set-GemTuiCursorPosition -X 0 -Y ([int]$Layout.Top + 2 + [int]$Layout.Rows))) { return }
        $footerText = (' {0}/{1}  page {2}/{3} ' -f ($SelectedIndex + 1),$Items.Count,$pageNumber,$pageCount)
        if ($footerText.Length -gt $headerInner) { $footerText = $footerText.Substring(0,$headerInner) }
        $footer = $bl + $footerText + ($hz * [Math]::Max(0,$headerInner - $footerText.Length)) + $br
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::BackgroundColor = $oldBackground
        [Console]::Write($footer.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
    } finally {
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
    }
}
