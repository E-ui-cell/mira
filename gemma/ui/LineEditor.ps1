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
    # No filename after ".file " means: do NOT run completion.
    # Press Enter instead and the normal .file command opens the file dialog.
    if ([String]::IsNullOrWhiteSpace($p)) {
        return @()
    }

    $q = if ($p.StartsWith('"') -or $p.StartsWith("'")) { $p[0] } else { '' }
    $x = if ($q) { $p.Substring(1) } else { $p }
    if ([String]::IsNullOrWhiteSpace($x)) {
        return @()
    }

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

function Read-GemLineConsole {
    $oldTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true

    $b = ''; $c = 0; $prompt = 2
    $row = [Console]::CursorTop
    [Console]::Write('> ')

    $renderedRows = 1
    if ($null -eq $script:GemKillRing) {
        $script:GemKillRing = New-Object 'System.Collections.Generic.List[string]'
    }
    $undoStack = New-Object 'System.Collections.Generic.List[object]'
    $historySearchTerm = $null
    $historySearchDraft = $null
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
                [Console]::Write('> ')
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
    function ShowChoices($choices,$current) {
        [Console]::SetCursorPosition(0,[Console]::CursorTop)
        [Console]::Write("`r`n" + ($choices -join '  ') + "`r`n> ")
        $script:dummy = $null
    }

    while ($true) {
        $k = [Console]::ReadKey($true)
        $ctrl = (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
        $alt = (($k.Modifiers -band [ConsoleModifiers]::Alt) -ne 0)

        if ($k.Key -eq [ConsoleKey]::C -and
            (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
            $b = ''
            $c = 0
            [Console]::SetCursorPosition($prompt, $row)
            [Console]::Write((' ' * ([Math]::Max(10, [Console]::WindowWidth - $prompt - 1))))
            [Console]::SetCursorPosition($prompt, $row)
            continue
        }

        if (($k.Key -eq [ConsoleKey]::J -or $k.KeyChar -eq [char]10) -and
            (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
            $old = $b
            $b = $b.Insert($c,[string][char]10)
            ++$c
            Redraw $old $b $c
            continue
        }

        # Ctrl+G cancels a history search and restores the original draft.
        if ($ctrl -and $k.Key -eq [ConsoleKey]::G) {
            if ($null -ne $historySearchTerm) {
                $old = $b
                $b = [string]$historySearchDraft
                $c = $b.Length
                $script:MiraHistoryIndex = -1
                $historySearchTerm = $null
                Redraw $old $b $c
            } else {
                [Console]::Beep(700,60)
            }
            continue
        }

        # Ctrl+R / Ctrl+S repeat reverse/forward searches for the current text.
        if ($ctrl -and ($k.Key -eq [ConsoleKey]::R -or $k.Key -eq [ConsoleKey]::S)) {
            if ($null -eq $historySearchTerm) {
                $historySearchTerm = $b
                $historySearchDraft = $b
                if ([string]::IsNullOrWhiteSpace($historySearchTerm)) {
                    [Console]::Beep(700,60)
                    $historySearchTerm = $null
                    continue
                }
            }
            if ($k.Key -eq [ConsoleKey]::R) {
                $startIndex = if ($script:MiraHistoryIndex -ge 0) { $script:MiraHistoryIndex } else { $script:MiraInputHistory.Count }
                $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $startIndex -Direction -1
            } else {
                $startIndex = if ($script:MiraHistoryIndex -ge 0) { $script:MiraHistoryIndex } else { -1 }
                $matchIndex = Find-GemHistoryMatch -Term $historySearchTerm -Start $startIndex -Direction 1
            }
            if ($matchIndex -ge 0) {
                Add-GemUndoSnapshot -Stack $undoStack -Buffer $b -Cursor $c
                $old = $b
                $script:MiraHistoryIndex = $matchIndex
                $b = $script:MiraInputHistory[$matchIndex]
                $c = $b.Length
                Redraw $old $b $c
            } else {
                [Console]::Beep(700,60)
            }
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

        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($c -gt 0) {
                $old = $b
                $b = $b.Remove($c-1,1)
                --$c
                Redraw $old $b $c
            }
            continue
        }

        if ($k.Key -eq [ConsoleKey]::Delete) {
            if ($c -lt $b.Length) {
                $old = $b
                $b = $b.Remove($c,1)
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
            $c = 0; Redraw $b $b $c; continue
        }

        if ($k.Key -eq [ConsoleKey]::End) {
            $c = $b.Length; Redraw $b $b $c; continue
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

            # !<TAB> / !get-<TAB>
            if ($b -match '^!(.*)$') {
                $p = $matches[1]
                $m = @(Get-GemCommands $p)
                if ($m.Count -eq 1) {
                    $old=$b; $b='!'+$m[0]; $c=$b.Length; Redraw $old $b $c
                } elseif ($m.Count -gt 1) {
                    [Console]::Write("`r`n" + ($m -join '  ') + "`r`n>  ")
                    $row=[Console]::CursorTop; Redraw '' $b $c
                } else { [Console]::Beep(700,60) }
                continue
            }

            # .<TAB> / .f<TAB> / .file<TAB>
            if ($b -match '^\.[^\s]*$') {
                $m = @($script:GemCommands | Where-Object {
                    $_.StartsWith($b,[StringComparison]::OrdinalIgnoreCase)
                })
                if ($m.Count -eq 1) {
                    $old=$b; $b=$m[0]; $c=$b.Length; Redraw $old $b $c
                } elseif ($m.Count -gt 1) {
                    [Console]::Write("`r`n" + ($m -join '  ') + "`r`nYou: ")
                    $row=[Console]::CursorTop; Redraw '' $b $c
                } else { [Console]::Beep(700,60) }
                continue
            }

            if ($b -match '^\.provider\s+(\S*)$') {
                $m = @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })
                if ($m.Count -eq 1) { $old=$b; $b='.provider '+$m[0]; $c=$b.Length; Redraw $old $b $c }
                elseif ($m.Count -gt 1) { [Console]::Write("`r`n"+($m -join '  ')+ "`r`nYou: "); $row=[Console]::CursorTop; Redraw '' $b $c }
                else { [Console]::Beep(700,60) }
                continue
            }
            if ($b -match '^\.(?:grounding|auth|effort)\s+(\S*)$') {
                $options = if ($b.StartsWith('.grounding')) { @('on','off','status') } elseif ($b.StartsWith('.effort')) { @('low','medium','high') } else { @('login','status','logout') }
                $m = @($options | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })
                if ($m.Count -eq 1) { $head = if ($b.StartsWith('.grounding')) { '.grounding ' } elseif ($b.StartsWith('.effort')) { '.effort ' } else { '.auth ' }; $old=$b; $b=$head+$m[0]; $c=$b.Length; Redraw $old $b $c }
                elseif ($m.Count -gt 1) { [Console]::Write("`r`n"+($m -join '  ')+ "`r`nYou: "); $row=[Console]::CursorTop; Redraw '' $b $c }
                else { [Console]::Beep(700,60) }
                continue
            }

            # .file <TAB> / .text <TAB> / session filename <TAB>
            if ($b -match '^(\.(?:file|text|exportsession|loadsession))(\s+)(.*)$') {
                $head = $matches[1] + $matches[2]
                $typed = $matches[3]
                $items = @(Get-GemFiles $typed)

                if ($items.Count -eq 1) {
                    $clean=$typed.Trim('"').Trim("'")
                    if ([String]::IsNullOrEmpty($clean)) {
                        $path=$items[0].Name
                    } else {
                        $dir=[IO.Path]::GetDirectoryName($clean)
                        if ([String]::IsNullOrEmpty($dir)) { $path=$items[0].Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $path=$dir+$items[0].Name }
                        else { $path=$dir+'\'+$items[0].Name }
                    }
                    if ($typed.StartsWith('"') -or $typed.StartsWith("'")) { $path=$typed[0]+$path+$typed[0] }
                    if ($items[0].PSIsContainer) { $path+='\' }
                    $old=$b; $b=$head+$path; $c=$b.Length; Redraw $old $b $c
                } elseif ($items.Count -gt 1) {
                    $show=@($items | ForEach-Object { if($_.PSIsContainer){$_.Name+'\'}else{$_.Name} })
                    [Console]::Write("`r`n"+($show -join '  ')+"`r`nYou: ")
                    $row=[Console]::CursorTop; Redraw '' $b $c
                } else { [Console]::Beep(700,60) }
                continue
            }

            continue
        }

if (-not [Char]::IsControl($k.KeyChar)) {
    $old = $b

    if ($c -eq $b.Length) {
        $b += $k.KeyChar
    }
    else {
        $b = $b.Insert($c,[string]$k.KeyChar)
    }
    ++$c

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
