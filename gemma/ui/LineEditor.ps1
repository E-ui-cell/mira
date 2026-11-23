function Get-GemCommands([string]$p) {
    @(
        Get-Command -CommandType Cmdlet,Function,Alias,Filter,ExternalScript,Application `
            -ErrorAction SilentlyContinue |
        Sort-Object Name -Unique |
        Where-Object { $_.Name.StartsWith($p,[StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -ExpandProperty Name
    )
}

function Get-GemFiles([string]$p) {
    $q = if ($p.StartsWith('"') -or $p.StartsWith("'")) { $p[0] } else { '' }
    $x = if ($q) { $p.Substring(1) } else { $p }
    if ($x.StartsWith('~')) { $x = $env:USERPROFILE + $x.Substring(1) }

    try {
        $dir = [IO.Path]::GetDirectoryName($x)
        $leaf = [IO.Path]::GetFileName($x)
    }
    catch {
        return @()
    }

    if ([String]::IsNullOrEmpty($dir)) { $dir = (Get-Location).Path }

    @(
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($leaf,[StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Name
    )
}

function Add-GemUndoSnapshot {
    param([System.Collections.Generic.List[object]]$Stack,[string]$Buffer,[int]$Cursor)
    [void]$Stack.Add(@{ Buffer = $Buffer; Cursor = $Cursor })
    if ($Stack.Count -gt 100) { $Stack.RemoveAt(0) }
}

function Get-GemWordStart {
    param([string]$Text,[int]$Position)
    $i = [Math]::Min($Position,$Text.Length)
    while ($i -gt 0 -and [char]::IsWhiteSpace($Text[$i - 1])) { --$i }
    while ($i -gt 0 -and -not [char]::IsWhiteSpace($Text[$i - 1])) { --$i }
    return $i
}

function Get-GemWordEnd {
    param([string]$Text,[int]$Position)
    $i = [Math]::Max(0,[Math]::Min($Position,$Text.Length))
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { ++$i }
    while ($i -lt $Text.Length -and -not [char]::IsWhiteSpace($Text[$i])) { ++$i }
    return $i
}

function Find-GemHistoryMatch {
    param([string]$Term,[int]$Start,[int]$Direction)
    if ($Direction -lt 0) {
        for ($i = [Math]::Min($Start - 1,$script:MiraInputHistory.Count - 1); $i -ge 0; $i--) {
            if ($script:MiraInputHistory[$i].IndexOf($Term,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
        }
    } else {
        for ($i = [Math]::Max(0,$Start + 1); $i -lt $script:MiraInputHistory.Count; $i++) {
            if ($script:MiraInputHistory[$i].IndexOf($Term,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
        }
    }
    return -1
}

function Get-GemHistorySearchPrompt {
    param([int]$Direction,[string]$Term,[int]$Width)
    $label = if ($Direction -gt 0) { '(fwd) ' } else { '(rev) ' }
    if ($Width -ge 28) {
        $label = if ($Direction -gt 0) { '(forward-i-search) ' } else { '(reverse-i-search) ' }
    }
    $maxTerm = [Math]::Max(0,$Width - $label.Length - 3)
    $displayTerm = [string]$Term
    if ($displayTerm.Length -gt $maxTerm) {
        if ($maxTerm -gt 0) { $displayTerm = $displayTerm.Substring($displayTerm.Length - $maxTerm) } else { $displayTerm = '' }
    }
    return $label + $displayTerm + ': '
}

function Read-GemLineConsole {
    $oldTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true

    $b = ''; $c = 0; $promptText = '> '; $prompt = $promptText.Length
    $row = [Console]::CursorTop
    [Console]::Write($promptText)

    $renderedRows = 1
    if ($null -eq $script:GemKillRing) {
        $script:GemKillRing = New-Object 'System.Collections.Generic.List[string]'
    }
    $undoStack = New-Object 'System.Collections.Generic.List[object]'
    $historySearchTerm = $null
    $historySearchDraft = $null
    $lastYankStart = -1
    $lastYankLength = 0
    $killRingIndex = 0
    $completionCandidates = @()
    $completionLabels = @()
    $completionOriginal = ''
    $completionIndex = -1
    $completionTop = -1
    $completionVisibleRows = 0
    $completionMenuHeight = 0
    $completionOldForeground = [Console]::ForegroundColor
    $completionOldBackground = [Console]::BackgroundColor
    function Redraw($old,$new,$pos) {
        $w = [Math]::Max(12,[Console]::WindowWidth)
        $usable = $w - 1
        $lines = @(([string]$new) -split [string][char]10,-1)
        $rowOffsets = New-Object 'System.Collections.Generic.List[int]'
        $totalRows = 0

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $rowOffsets.Add($totalRows)
            $startColumn = if ($i -eq 0) { $prompt } else { 0 }
            $firstCapacity = [Math]::Max(1,$usable - $startColumn)
            $length = ([string]$lines[$i]).Length
            $rowsForLine = if ($length -le $firstCapacity) { 1 } else { 1 + [int][Math]::Ceiling(($length - $firstCapacity) / [double]$usable) }
            $totalRows += $rowsForLine
        }

        # Clear the previous and new physical rows, including wrapped long lines.
        $clearRows = [Math]::Max($renderedRows,$totalRows)
        for ($i = 0; $i -lt $clearRows; $i++) {
            $targetRow = $row + $i
            if ($targetRow -ge [Console]::BufferHeight) { break }
            [Console]::SetCursorPosition(0,$targetRow)
            [Console]::Write((' ' * $usable))
        }

        # Draw bounded chunks rather than relying on implicit console wrapping.
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $value = [string]$lines[$i]
            $startColumn = if ($i -eq 0) { $prompt } else { 0 }
            $firstCapacity = [Math]::Max(1,$usable - $startColumn)
            $offset = 0
            $physicalRow = $row + $rowOffsets[$i]
            if ($i -eq 0 -and $physicalRow -lt [Console]::BufferHeight) {
                [Console]::SetCursorPosition(0,$physicalRow)
                [Console]::Write($promptText)
            }
            while ($offset -lt $value.Length) {
                $column = if ($offset -eq 0) { $startColumn } else { 0 }
                $capacity = if ($offset -eq 0) { $firstCapacity } else { $usable }
                $count = [Math]::Min($capacity,$value.Length - $offset)
                if ($physicalRow -lt [Console]::BufferHeight) {
                    [Console]::SetCursorPosition($column,$physicalRow)
                    [Console]::Write($value.Substring($offset,$count))
                }
                $offset += $count
                if ($offset -lt $value.Length) { ++$physicalRow }
            }
        }

        $lineIndex = 0
        $column = 0
        if ($pos -gt 0) {
            $prefix = ([string]$new).Substring(0,[Math]::Min($pos,([string]$new).Length))
            $lineIndex = ([regex]::Matches($prefix,[string][char]10)).Count
            $lastBreak = $prefix.LastIndexOf([char]10)
            $column = if ($lastBreak -ge 0) { $prefix.Length - $lastBreak - 1 } else { $prefix.Length }
        }
        $startColumn = if ($lineIndex -eq 0) { $prompt } else { 0 }
        $firstCapacity = [Math]::Max(1,$usable - $startColumn)
        if ($column -lt $firstCapacity) {
            $cursorRowOffset = 0
            $cursorColumn = $startColumn + $column
        } else {
            $afterFirst = $column - $firstCapacity
            $cursorRowOffset = 1 + [int][Math]::Floor($afterFirst / [double]$usable)
            $cursorColumn = $afterFirst % $usable
        }
        $cursorRow = [Math]::Min($row + $rowOffsets[$lineIndex] + $cursorRowOffset,[Console]::BufferHeight - 1)
        [Console]::SetCursorPosition([Math]::Min($cursorColumn,$usable - 1),$cursorRow)
        $renderedRows = [Math]::Max(1,$totalRows)
    }
    function Draw-GemCompletionMenu {
        if ($completionCandidates.Count -le 1 -or $completionVisibleRows -le 0) { return }

        $first = [Math]::Max(0,[Math]::Min(
            $completionIndex - [int][Math]::Floor($completionVisibleRows / 2),
            $completionCandidates.Count - $completionVisibleRows
        ))
        $clearWidth = [Math]::Max(1,[Console]::WindowWidth - 1)
        [Console]::SetCursorPosition(0,$completionTop)

        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        $header = ('Completions ({0})' -f $completionCandidates.Count)
        [Console]::Write($header.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        $hint = 'Up/Down or j/k move; Enter accept; Esc cancel'
        [Console]::Write($hint.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        for ($rowIndex = 0; $rowIndex -lt $completionVisibleRows; $rowIndex++) {
            $candidateIndex = $first + $rowIndex
            $line = ''
            if ($candidateIndex -lt $completionCandidates.Count) {
                $marker = if ($candidateIndex -eq $completionIndex) { '>' } else { ' ' }
                $label = if ($candidateIndex -lt $completionLabels.Count) {
                    [string]$completionLabels[$candidateIndex]
                } else {
                    [string]$completionCandidates[$candidateIndex]
                }
                $line = (' {0} {1}' -f $marker,$label)
                if ($line.Length -gt $clearWidth) { $line = $line.Substring(0,$clearWidth) }
            }

            if ($candidateIndex -lt $completionCandidates.Count -and $candidateIndex -eq $completionIndex) {
                [Console]::ForegroundColor = [ConsoleColor]::White
                [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
            } else {
                [Console]::ForegroundColor = [ConsoleColor]::Gray
                [Console]::BackgroundColor = $completionOldBackground
            }
            [Console]::Write($line.PadRight($clearWidth).Substring(0,$clearWidth))
            [Console]::WriteLine()
        }

        [Console]::ForegroundColor = $completionOldForeground
        [Console]::BackgroundColor = $completionOldBackground
        $footer = (' {0}/{1} ' -f ($completionIndex + 1),$completionCandidates.Count)
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write($footer.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::ForegroundColor = $completionOldForeground
        [Console]::SetCursorPosition(0,[Math]::Min(
            $completionTop + $completionMenuHeight,
            [Console]::BufferHeight - 1
        ))
    }
    while ($true) {
        $k = [Console]::ReadKey($true)

        if ($completionCandidates.Count -gt 1) {
            if ($k.Key -eq [ConsoleKey]::J -or $k.Key -eq [ConsoleKey]::DownArrow) {
                $completionIndex = ($completionIndex + 1) % $completionCandidates.Count
                Draw-GemCompletionMenu
                continue
            }
            if ($k.Key -eq [ConsoleKey]::K -or $k.Key -eq [ConsoleKey]::UpArrow) {
                $completionIndex = ($completionIndex - 1 + $completionCandidates.Count) % $completionCandidates.Count
                Draw-GemCompletionMenu
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Escape) {
                $completionCandidates = @()
                $completionLabels = @()
                $completionIndex = -1
                $completionOriginal = ''
                $completionTop = -1
                Redraw $b $b $c
                continue
            }

            # Enter accepts the highlighted completion only; a second Enter
            # submits the input line. Any other key accepts then edits normally.
            Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
            $old = $b
            $b = [string]$completionCandidates[$completionIndex]
            $c = $b.Length
            $completionCandidates = @()
            $completionLabels = @()
            $completionIndex = -1
            $completionOriginal = ''
            $completionTop = -1
            Redraw $old $b $c
            if ($k.Key -eq [ConsoleKey]::Enter) { continue }
        }

        $ctrl = (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
        $alt = (($k.Modifiers -band [ConsoleModifiers]::Alt) -ne 0)
        if (-not ($alt -and $k.Key -eq [ConsoleKey]::Y)) {
            $lastYankStart = -1
            $lastYankLength = 0
        }

        if ($null -eq $historySearchTerm -and $k.Key -eq [ConsoleKey]::C -and
            (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
            $b = ''
            $c = 0
            $script:MiraHistoryIndex = -1
            $historySearchTerm = $null
            [Console]::SetCursorPosition($prompt, $row)
            [Console]::Write((' ' * ([Math]::Max(10, [Console]::WindowWidth - $prompt - 1))))
            [Console]::SetCursorPosition($prompt, $row)
            continue
        }

        if ($null -eq $historySearchTerm -and ($k.Key -eq [ConsoleKey]::J -or $k.KeyChar -eq [char]10) -and
            (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
            Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
            $old = $b
            $b = $b.Insert($c,[string][char]10)
            ++$c
            $script:MiraHistoryIndex = -1
            $historySearchTerm = $null
            Redraw $old $b $c
            continue
        }

        # Ctrl+R starts reverse-i-search; type a term, Ctrl+R/S cycles matches.
        if ($null -ne $historySearchTerm) {
            $old = $b
            $searchChanged = $false
            if (($ctrl -and $k.Key -eq [ConsoleKey]::G) -or $k.Key -eq [ConsoleKey]::Escape) {
                $b = [string]$historySearchDraft
                $c = $b.Length
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                $promptText = '> '
                $prompt = $promptText.Length
                Redraw $old $b $c
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Enter) {
                $historySearchTerm = $null
                $script:MiraHistoryIndex = -1
                $promptText = '> '
                $prompt = $promptText.Length
                [Console]::Write([Environment]::NewLine)
                [Console]::TreatControlCAsInput = $oldTreatControlCAsInput
                return $b
            }
            if ($ctrl -and ($k.Key -eq [ConsoleKey]::R -or $k.Key -eq [ConsoleKey]::S)) {
                $historySearchDirection = if ($k.Key -eq [ConsoleKey]::R) { -1 } else { 1 }
                $startIndex = if ($script:MiraHistoryIndex -ge 0) {
                    $script:MiraHistoryIndex
                } elseif ($historySearchDirection -lt 0) {
                    $script:MiraInputHistory.Count
                } else {
                    -1
                }
                $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $startIndex -Direction $historySearchDirection
                if ($matchIndex -ge 0) {
                    $script:MiraHistoryIndex = $matchIndex
                    $b = $script:MiraInputHistory[$matchIndex]
                    $c = $b.Length
                } else {
                    [Console]::Beep(700,60)
                }
                $searchChanged = $true
            } elseif ($k.Key -eq [ConsoleKey]::Backspace -or ($ctrl -and $k.Key -eq [ConsoleKey]::H)) {
                if ($historySearchTerm.Length -gt 0) {
                    $historySearchTerm = $historySearchTerm.Substring(0,$historySearchTerm.Length - 1)
                }
                if ($historySearchTerm.Length -eq 0) {
                    $b = [string]$historySearchDraft
                    $c = $b.Length
                    $script:MiraHistoryIndex = -1
                } else {
                    $script:MiraHistoryIndex = -1
                    $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $script:MiraInputHistory.Count -Direction -1
                    if ($matchIndex -ge 0) {
                        $script:MiraHistoryIndex = $matchIndex
                        $b = $script:MiraInputHistory[$matchIndex]
                        $c = $b.Length
                    } else {
                        [Console]::Beep(700,60)
                    }
                }
                $searchChanged = $true
            } elseif (-not [Char]::IsControl($k.KeyChar) -and -not $ctrl -and -not $alt) {
                $historySearchTerm += [string]$k.KeyChar
                $script:MiraHistoryIndex = -1
                $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $script:MiraInputHistory.Count -Direction -1
                if ($matchIndex -ge 0) {
                    $script:MiraHistoryIndex = $matchIndex
                    $b = $script:MiraInputHistory[$matchIndex]
                    $c = $b.Length
                } else {
                    [Console]::Beep(700,60)
                }
                $searchChanged = $true
            } else {
                [Console]::Beep(700,60)
            }

            if ($searchChanged) {
                $directionLabel = if ($historySearchDirection -gt 0) { 'forward' } else { 'reverse' }
                if (-not $historySearchDirection) { $directionLabel = 'reverse' }
                $promptText = Get-GemHistorySearchPrompt -Direction $historySearchDirection -Term $historySearchTerm -Width ([Console]::WindowWidth)
                $prompt = $promptText.Length
                Redraw $old $b $c
            }
            continue
        }

        if ($ctrl -and ($k.Key -eq [ConsoleKey]::G)) {
            [Console]::Beep(700,60)
            continue
        }
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::R -or $k.Key -eq [ConsoleKey]::S)) {
            $historySearchDraft = $b
            $historySearchTerm = $b
            $historySearchDirection = if ($k.Key -eq [ConsoleKey]::R) { -1 } else { 1 }
            $script:MiraHistoryIndex = -1
            $directionLabel = if ($historySearchDirection -gt 0) { 'forward' } else { 'reverse' }
            $promptText = Get-GemHistorySearchPrompt -Direction $historySearchDirection -Term $historySearchTerm -Width ([Console]::WindowWidth)
            $prompt = $promptText.Length
            if ($historySearchTerm.Length -gt 0) {
                $startIndex = if ($historySearchDirection -lt 0) { $script:MiraInputHistory.Count } else { -1 }
                $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $startIndex -Direction $historySearchDirection
                if ($matchIndex -ge 0) {
                    $script:MiraHistoryIndex = $matchIndex
                    $b = $script:MiraInputHistory[$matchIndex]
                    $c = $b.Length
                } else {
                    [Console]::Beep(700,60)
                }
            }
            Redraw $b $b $c
            continue
        }

        # Ctrl+P/N are explicit previous/next history shortcuts.
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::P -or $k.Key -eq [ConsoleKey]::N)) {
            if ($k.Key -eq [ConsoleKey]::P) {
                if ($script:MiraInputHistory.Count -gt 0) {
                    if ($script:MiraHistoryIndex -eq -1) {
                        $script:MiraHistoryDraft = $b
                        $script:MiraHistoryIndex = $script:MiraInputHistory.Count - 1
                    } elseif ($script:MiraHistoryIndex -gt 0) {
                        --$script:MiraHistoryIndex
                    } else { [Console]::Beep(700,60); continue }
                    $old = $b
                    $b = $script:MiraInputHistory[$script:MiraHistoryIndex]
                    $c = $b.Length
                    Redraw $old $b $c
                } else { [Console]::Beep(700,60) }
            } else {
                if ($script:MiraHistoryIndex -eq -1) {
                    [Console]::Beep(700,60)
                } elseif ($script:MiraHistoryIndex -lt ($script:MiraInputHistory.Count - 1)) {
                    ++$script:MiraHistoryIndex
                    $old = $b
                    $b = $script:MiraInputHistory[$script:MiraHistoryIndex]
                    $c = $b.Length
                    Redraw $old $b $c
                } else {
                    $old = $b
                    $b = $script:MiraHistoryDraft
                    $c = $b.Length
                    $script:MiraHistoryIndex = -1
                    Redraw $old $b $c
                }
            }
            $historySearchTerm = $null
            continue
        }

        # Ctrl+D deletes forward, or exits cleanly on an empty prompt.
        if ($ctrl -and $k.Key -eq [ConsoleKey]::D) {
            if ($b.Length -eq 0) {
                [Console]::TreatControlCAsInput = $oldTreatControlCAsInput
                return '.q'
            }
            if ($c -lt $b.Length) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $b = $b.Remove($c,1)
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            } else { [Console]::Beep(700,60) }
            continue
        }

        # Ctrl+A/E move to the current logical line boundary.
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::A -or $k.Key -eq [ConsoleKey]::E)) {
            if ($k.Key -eq [ConsoleKey]::A) {
                $lineStart = $b.LastIndexOf([char]10,[Math]::Max(0,$c - 1))
                $c = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
            } else {
                $lineEnd = $b.IndexOf([char]10,$c)
                $c = if ($lineEnd -lt 0) { $b.Length } else { $lineEnd }
            }
            Redraw $b $b $c
            continue
        }

        # Ctrl+B/F and Alt+B/F provide character and word motion.
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::B -or $k.Key -eq [ConsoleKey]::F)) {
            if ($k.Key -eq [ConsoleKey]::B) { $c = [Math]::Max(0,$c - 1) }
            else { $c = [Math]::Min($b.Length,$c + 1) }
            Redraw $b $b $c
            continue
        }
        if ($alt -and ($k.Key -eq [ConsoleKey]::B -or $k.Key -eq [ConsoleKey]::F)) {
            if ($k.Key -eq [ConsoleKey]::B) { $c = Get-GemWordStart -Text $b -Position $c }
            else { $c = Get-GemWordEnd -Text $b -Position $c }
            Redraw $b $b $c
            continue
        }

        # Ctrl+K/U/W and Alt+D/Backspace use a shared kill ring.
        if (($ctrl -and ($k.Key -eq [ConsoleKey]::K -or $k.Key -eq [ConsoleKey]::U -or $k.Key -eq [ConsoleKey]::W)) -or
            ($alt -and ($k.Key -eq [ConsoleKey]::D -or $k.Key -eq [ConsoleKey]::Backspace))) {
            $start = $c
            $finish = $c
            if ($ctrl -and $k.Key -eq [ConsoleKey]::K) {
                $lineEnd = $b.IndexOf([char]10,$c)
                if ($lineEnd -lt 0) { $lineEnd = $b.Length }
                $finish = if ($lineEnd -eq $c -and $lineEnd -lt $b.Length) { $lineEnd + 1 } else { $lineEnd }
            } elseif ($ctrl -and $k.Key -eq [ConsoleKey]::U) {
                $lineStart = $b.LastIndexOf([char]10,[Math]::Max(0,$c - 1))
                $start = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
            } elseif ($ctrl -and $k.Key -eq [ConsoleKey]::W -or ($alt -and $k.Key -eq [ConsoleKey]::Backspace)) {
                $start = Get-GemWordStart -Text $b -Position $c
            } else {
                $finish = Get-GemWordEnd -Text $b -Position $c
            }
            if ($finish -gt $start) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                [void]$script:GemKillRing.Insert(0,$b.Substring($start,$finish - $start))
                while ($script:GemKillRing.Count -gt 20) { $script:GemKillRing.RemoveAt($script:GemKillRing.Count - 1) }
                $lastYankStart = -1
                $lastYankLength = 0
                $b = $b.Remove($start,$finish - $start)
                $c = $start
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            }
            continue
        }

        # Ctrl+Y pastes the most recently killed text.
        if ($ctrl -and $k.Key -eq [ConsoleKey]::Y) {
            if ($script:GemKillRing.Count -gt 0) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $text = $script:GemKillRing[0]
                $b = $b.Insert($c,$text)
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                $lastYankStart = $c
                $lastYankLength = $text.Length
                $killRingIndex = 0
                $c += $text.Length
                Redraw $old $b $c
            }
            continue
        }

        # Ctrl+T transposes adjacent characters; Alt+T transposes adjacent words.
        if ($ctrl -and $k.Key -eq [ConsoleKey]::T) {
            if ($b.Length -ge 2 -and $c -gt 0) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $left = if ($c -eq $b.Length) { $c - 2 } else { $c - 1 }
                $chars = $b.ToCharArray()
                $temp = $chars[$left]
                $chars[$left] = $chars[$left + 1]
                $chars[$left + 1] = $temp
                $b = -join $chars
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                $c = [Math]::Min($b.Length,$c + 1)
                Redraw $old $b $c
            }
            continue
        }
        if ($alt -and $k.Key -eq [ConsoleKey]::T) {
            $firstStart = Get-GemWordStart -Text $b -Position $c
            $firstEnd = Get-GemWordEnd -Text $b -Position $firstStart
            $secondStart = Get-GemWordEnd -Text $b -Position $firstEnd
            if ($firstEnd -gt $firstStart -and $secondStart -lt $b.Length) {
                $secondEnd = Get-GemWordEnd -Text $b -Position $secondStart
                if ($secondEnd -gt $secondStart) {
                    Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                    $old = $b
                    $firstWord = $b.Substring($firstStart,$firstEnd - $firstStart)
                    $separator = $b.Substring($firstEnd,$secondStart - $firstEnd)
                    $secondWord = $b.Substring($secondStart,$secondEnd - $secondStart)
                    $b = $b.Substring(0,$firstStart) + $secondWord + $separator + $firstWord + $b.Substring($secondEnd)
                    $script:MiraHistoryIndex = -1
                    $historySearchTerm = $null
                    $c = $firstStart + $secondWord.Length + $separator.Length + $firstWord.Length
                    Redraw $old $b $c
                }
            }
            continue
        }

        # Ctrl+Z/Ctrl+_ undo the most recent edit.
        if (($ctrl -and $k.Key -eq [ConsoleKey]::Z) -or $k.KeyChar -eq [char]31) {
            if ($undoStack.Count -gt 0) {
                $state = $undoStack[$undoStack.Count - 1]
                $undoStack.RemoveAt($undoStack.Count - 1)
                $old = $b
                $b = [string]$state.Buffer
                $c = [int]$state.Cursor
                Redraw $old $b $c
            } else { [Console]::Beep(700,60) }
            continue
        }

        # Ctrl+V/Ctrl+Q insert the next key literally.
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::V -or $k.Key -eq [ConsoleKey]::Q)) {
            $quoted = [Console]::ReadKey($true)
            $insertText = [string]$quoted.KeyChar
            if ($quoted.Key -eq [ConsoleKey]::Enter -or $quoted.KeyChar -eq [char]13 -or $quoted.KeyChar -eq [char]10) {
                $insertText = [string][char]10
            }
            if ($insertText.Length -gt 0 -and $insertText -ne [string][char]0) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $b = $b.Insert($c,$insertText)
                $c += $insertText.Length
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            }
            continue
        }

        # Alt+C/U/L change the case of the word at the cursor.
        if ($alt -and ($k.Key -eq [ConsoleKey]::C -or $k.Key -eq [ConsoleKey]::U -or $k.Key -eq [ConsoleKey]::L)) {
            $wordStart = Get-GemWordStart -Text $b -Position $c
            $wordEnd = Get-GemWordEnd -Text $b -Position $wordStart
            if ($wordEnd -gt $wordStart) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $word = $b.Substring($wordStart,$wordEnd - $wordStart)
                if ($k.Key -eq [ConsoleKey]::U) {
                    $changedWord = $word.ToUpperInvariant()
                } elseif ($k.Key -eq [ConsoleKey]::L) {
                    $changedWord = $word.ToLowerInvariant()
                } else {
                    $changedWord = $word.Substring(0,1).ToUpperInvariant() + $word.Substring(1).ToLowerInvariant()
                }
                $b = $b.Substring(0,$wordStart) + $changedWord + $b.Substring($wordEnd)
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                $c = $wordStart + $changedWord.Length
                Redraw $old $b $c
            }
            continue
        }

        # Alt+Y rotates through the recent kill ring after Ctrl+Y.
        if ($alt -and $k.Key -eq [ConsoleKey]::Y) {
            if ($lastYankStart -ge 0 -and $script:GemKillRing.Count -gt 1) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $b = $b.Remove($lastYankStart,$lastYankLength)
                $killRingIndex = ($killRingIndex + 1) % $script:GemKillRing.Count
                $text = $script:GemKillRing[$killRingIndex]
                $b = $b.Insert($lastYankStart,$text)
                $lastYankLength = $text.Length
                $c = $lastYankStart + $lastYankLength
                Redraw $old $b $c
            } else {
                [Console]::Beep(700,60)
            }
            continue
        }

        # Alt+< / Alt+> jump to the oldest/newest history entry.
        if ($alt -and ($k.KeyChar -eq '<' -or $k.KeyChar -eq '>')) {
            if ($script:MiraInputHistory.Count -gt 0) {
                if ($script:MiraHistoryIndex -eq -1) { $script:MiraHistoryDraft = $b }
                $script:MiraHistoryIndex = if ($k.KeyChar -eq '<') { 0 } else { $script:MiraInputHistory.Count - 1 }
                $old = $b
                $b = $script:MiraInputHistory[$script:MiraHistoryIndex]
                $c = $b.Length
                Redraw $old $b $c
            } else {
                [Console]::Beep(700,60)
            }
            continue
        }

        # Ctrl+L clears and redraws without losing the current draft.
        if ($ctrl -and $k.Key -eq [ConsoleKey]::L) {
            [Console]::Clear()
            $row = [Console]::CursorTop
            $renderedRows = 1
            Redraw '' $b $c
            continue
        }

        if ($k.Key -eq [ConsoleKey]::Enter) {
            [Console]::Write("`r`n")
            [Console]::TreatControlCAsInput = $oldTreatControlCAsInput
            return $b
        }

        if ($k.Key -eq [ConsoleKey]::Backspace -or ($ctrl -and $k.Key -eq [ConsoleKey]::H)) {
            if ($c -gt 0) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $b = $b.Remove($c-1,1)
                --$c
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::Delete) {
            if ($c -lt $b.Length) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $b = $b.Remove($c,1)
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::LeftArrow) {
            if ($c -gt 0) { --$c; Redraw $b $b $c }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::RightArrow) {
            if ($c -lt $b.Length) { ++$c; Redraw $b $b $c }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::Home) {
            $lineStart = $b.LastIndexOf([char]10,[Math]::Max(0,$c - 1))
            $c = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
            Redraw $b $b $c; continue
        }

        if ($k.Key -eq [ConsoleKey]::End) {
            $lineEnd = $b.IndexOf([char]10,$c)
            $c = if ($lineEnd -lt 0) { $b.Length } else { $lineEnd }
            Redraw $b $b $c; continue
        }
        # MIRA INPUT HISTORY - fallback Up/Down
        if ($k.Key -eq [ConsoleKey]::UpArrow) {
            if ($script:MiraInputHistory.Count -eq 0) {
                [Console]::Beep(700,60)
                continue
            }

            if ($script:MiraHistoryIndex -eq -1) {
                $script:MiraHistoryDraft = $b
                $script:MiraHistoryIndex = $script:MiraInputHistory.Count - 1
            }
            elseif ($script:MiraHistoryIndex -gt 0) {
                --$script:MiraHistoryIndex
            }

            $old = $b
            $b = $script:MiraInputHistory[$script:MiraHistoryIndex]
            $c = $b.Length
            Redraw $old $b $c
            continue
        }

        if ($k.Key -eq [ConsoleKey]::DownArrow) {
            if ($script:MiraHistoryIndex -eq -1) {
                [Console]::Beep(700,60)
                continue
            }

            if ($script:MiraHistoryIndex -lt ($script:MiraInputHistory.Count - 1)) {
                ++$script:MiraHistoryIndex
                $old = $b
                $b = $script:MiraInputHistory[$script:MiraHistoryIndex]
                $c = $b.Length
                Redraw $old $b $c
            }
            else {
                $old = $b
                $b = $script:MiraHistoryDraft
                $c = $b.Length
                $script:MiraHistoryIndex = -1
                Redraw $old $b $c
            }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::Tab) {
            if ($c -ne $b.Length) { continue }
            $candidateBuffers = @()
            $candidateLabels = @()

            if ($b -match '^\.[^\s]*$') {
                $found = @($script:GemCommands | Where-Object { $_.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) })
                foreach ($item in $found) { $candidateBuffers += [string]$item; $candidateLabels += [string]$item }
            }
            elseif ($b -match '^!(.*)$') {
                $commandText = $matches[1]
                if ($commandText -notmatch '\s' -and ($commandText -match '[\\/]' -or $commandText.StartsWith('.') -or $commandText.StartsWith('~'))) {
                    foreach ($item in @(Get-GemFiles $commandText)) {
                        $clean = $commandText.Trim('"').Trim("'")
                        $dir = [IO.Path]::GetDirectoryName($clean)
                        if ([string]::IsNullOrEmpty($clean) -or [string]::IsNullOrEmpty($dir)) { $path = $item.Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $path = $dir + $item.Name }
                        else { $path = $dir + '\' + $item.Name }
                        if ($commandText.StartsWith('"') -or $commandText.StartsWith("'")) { $path = $commandText[0] + $path + $commandText[0] }
                        if ($item.PSIsContainer) { $path += '\' }
                        $candidateBuffers += ('!' + $path)
                        $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                    }
                } elseif ($commandText -notmatch '\s') {
                    $found = @(Get-GemCommands $commandText)
                    foreach ($item in $found) { $candidateBuffers += ('!' + [string]$item); $candidateLabels += [string]$item }
                } else {
                    $tokenMatch = [regex]::Match($commandText,'(?:^|\s)([^\s]*)$')
                    $typedPath = $tokenMatch.Groups[1].Value
                    $prefixLength = $commandText.Length - $typedPath.Length
                    foreach ($item in @(Get-GemFiles $typedPath)) {
                        $clean = $typedPath.Trim('"').Trim("'")
                        $dir = [IO.Path]::GetDirectoryName($clean)
                        if ([string]::IsNullOrEmpty($clean) -or [string]::IsNullOrEmpty($dir)) { $path = $item.Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $path = $dir + $item.Name }
                        else { $path = $dir + '\' + $item.Name }
                        if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                        if ($item.PSIsContainer) { $path += '\' }
                        $candidateBuffers += ('!' + $commandText.Substring(0,$prefixLength) + $path)
                        $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                    }
                }
            }
            elseif ($b -match '^(\.(?:file|text|exportsession|loadsession))(\s+)(.*)$') {
                $head = $matches[1] + $matches[2]
                $typedPath = $matches[3]
                foreach ($item in @(Get-GemFiles $typedPath)) {
                    $clean = $typedPath.Trim('"').Trim("'")
                    $dir = [IO.Path]::GetDirectoryName($clean)
                    if ([string]::IsNullOrEmpty($clean) -or [string]::IsNullOrEmpty($dir)) { $path = $item.Name }
                    elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $path = $dir + $item.Name }
                    else { $path = $dir + '\' + $item.Name }
                    if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                    if ($item.PSIsContainer) { $path += '\' }
                    $candidateBuffers += ($head + $path)
                    $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                }
            }
            elseif ($b -match '^\.diff\s+(.*)$') {
                $diffText = $matches[1]
                $tokenMatch = [regex]::Match($diffText,'(?:^|\s)([^\s]*)$')
                $typedPath = $tokenMatch.Groups[1].Value
                $prefixLength = $diffText.Length - $typedPath.Length
                foreach ($item in @(Get-GemFiles $typedPath)) {
                    $clean = $typedPath.Trim('"').Trim("'")
                    $dir = [IO.Path]::GetDirectoryName($clean)
                    if ([string]::IsNullOrEmpty($clean) -or [string]::IsNullOrEmpty($dir)) { $path = $item.Name }
                    elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $path = $dir + $item.Name }
                    else { $path = $dir + '\' + $item.Name }
                    if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                    if ($item.PSIsContainer) { $path += '\' }
                    $candidateBuffers += ('.diff ' + $diffText.Substring(0,$prefixLength) + $path)
                    $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                }
            }
            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*)$') {
                $head = '.' + $matches[1] + ' '
                $options = if ($matches[1] -eq 'grounding') { @('on','off','status') } elseif ($matches[1] -eq 'effort') { @('low','medium','high') } else { @('login','status','logout') }
                foreach ($item in @($options | Where-Object { $_.StartsWith($matches[2],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ($head + $item); $candidateLabels += $item
                }
            }

            if ($candidateBuffers.Count -eq 1) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b; $b = [string]$candidateBuffers[0]; $c = $b.Length
                Redraw $old $b $c
            } elseif ($candidateBuffers.Count -gt 1) {
                $completionOriginal = $b
                $completionCandidates = @($candidateBuffers)
                $completionLabels = @($candidateLabels)
                $completionIndex = 0

                # Use a fixed-height scrolling viewport, matching the model picker.
                [Console]::WriteLine()
                $windowHeight = [Math]::Max(10,[Console]::WindowHeight)
                $completionVisibleRows = [Math]::Max(1,[Math]::Min(10,$windowHeight - 6))
                $completionVisibleRows = [Math]::Min($completionVisibleRows,$completionCandidates.Count)
                $completionMenuHeight = $completionVisibleRows + 3
                $completionTop = [Console]::CursorTop
                $viewportBottom = [Console]::WindowTop + $windowHeight
                $spaceBelow = $viewportBottom - $completionTop
                if ($spaceBelow -lt ($completionMenuHeight + 1)) {
                    $paddingRows = ($completionMenuHeight + 1) - $spaceBelow
                    [Console]::Write(([Environment]::NewLine * $paddingRows))
                    $completionTop = [Console]::CursorTop
                }
                $completionOldForeground = [Console]::ForegroundColor
                $completionOldBackground = [Console]::BackgroundColor
                Draw-GemCompletionMenu
                $row = [Math]::Min($completionTop + $completionMenuHeight,[Console]::BufferHeight - 1)
                $renderedRows = 1
                Redraw $b $b $c
            } else {
                [Console]::Beep(700,60)
            }
            continue
        }

        
if (-not [Char]::IsControl($k.KeyChar)) {
    Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
    $old = $b

    if ($c -eq $b.Length) {
        $b += $k.KeyChar
    }
    else {
        $b = $b.Insert($c,[string]$k.KeyChar)
    }
    ++$c
    $script:MiraHistoryIndex = -1
    $historySearchTerm = $null

    # Drain a burst of pasted characters before redrawing.
    while ([Console]::KeyAvailable) {
        $pk = [Console]::ReadKey($true)

        # A multiline paste is delivered as Enter/CR/LF control characters.
        # Preserve those as text line breaks; Enter typed after the paste burst
        # is handled by the outer input loop as submit.
        if ($pk.Key -eq [ConsoleKey]::Enter -or $pk.KeyChar -eq [char]13 -or $pk.KeyChar -eq [char]10) {
            if ($pk.KeyChar -eq [char]10 -and $b.EndsWith("`n")) { continue }
            if ($b.EndsWith("`r")) { $b = $b.TrimEnd([char]13) }
            $b = $b.Insert($c,"`n")
            ++$c
            continue
        }

        if (-not [Char]::IsControl($pk.KeyChar)) {
            if ($c -eq $b.Length) {
                $b += $pk.KeyChar
            }
            else {
                $b = $b.Insert($c,[string]$pk.KeyChar)
            }
            ++$c
        }
    }

    # One redraw for the whole burst instead of one per character.
    Redraw $old $b $c
}
}
}

function Read-GemLineFallback {
    $useConsoleReader = $false
    try {
        $useConsoleReader = ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected)
    } catch {
        $useConsoleReader = $false
    }
    if (-not $useConsoleReader) {
        return Read-Host '> '
    }
    try {
        return Read-GemLineConsole
    } catch {
        try { [Console]::TreatControlCAsInput = $false } catch {}
        Write-Host "[Console input fallback] $($_.Exception.Message)" -ForegroundColor Yellow
        return Read-Host '   >'
    }
}
