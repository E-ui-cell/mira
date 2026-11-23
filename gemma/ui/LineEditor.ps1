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
    $completionOriginal = ''
    $completionIndex = -1
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
    while ($true) {
        $k = [Console]::ReadKey($true)

        # j/k navigate the active completion list. The chosen item is previewed
        # in the input buffer; Escape restores the text typed before completion.
        if ($completionCandidates.Count -gt 1) {
            if ($k.KeyChar -eq 'j' -or $k.Key -eq [ConsoleKey]::DownArrow) {
                $completionIndex = ($completionIndex + 1) % $completionCandidates.Count
                $old = $b; $b = [string]$completionCandidates[$completionIndex]; $c = $b.Length
                Redraw $old $b $c
                continue
            }
            if ($k.KeyChar -eq 'k' -or $k.Key -eq [ConsoleKey]::UpArrow) {
                $completionIndex = ($completionIndex - 1 + $completionCandidates.Count) % $completionCandidates.Count
                $old = $b; $b = [string]$completionCandidates[$completionIndex]; $c = $b.Length
                Redraw $old $b $c
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Escape) {
                $old = $b; $b = $completionOriginal; $c = $b.Length
                $completionCandidates = @(); $completionIndex = -1; $completionOriginal = ''
                Redraw $old $b $c
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Tab -or $k.Key -eq [ConsoleKey]::Enter) {
                $completionCandidates = @(); $completionIndex = -1; $completionOriginal = ''
                if ($k.Key -eq [ConsoleKey]::Tab) {
            if ($c -ne $b.Length) { continue }

            $candidateBuffers = @()
            $candidateLabels = @()

            # MIRA dot-commands.
            if ($b -match '^\.[^\s]*$') {
                $matchesForCompletion = @($script:GemCommands | Where-Object {
                    $_.StartsWith($b,[StringComparison]::OrdinalIgnoreCase)
                })
                foreach ($item in $matchesForCompletion) {
                    $candidateBuffers += [string]$item
                    $candidateLabels += [string]$item
                }
            }
            # PowerShell command names after !; paths after the command.
            elseif ($b -match '^!(.*)$') {
                $commandText = $matches[1]
                if ($commandText -notmatch '\s') {
                    $matchesForCompletion = @(Get-GemCommands $commandText)
                    foreach ($item in $matchesForCompletion) {
                        $candidateBuffers += ('!' + [string]$item)
                        $candidateLabels += [string]$item
                    }
                } else {
                    $tokenMatch = [regex]::Match($commandText,'(?:^|\s)([^\s]*)$')
                    $typedPath = $tokenMatch.Groups[1].Value
                    $pathItems = @(Get-GemFiles $typedPath)
                    $prefixLength = $commandText.Length - $typedPath.Length
                    foreach ($item in $pathItems) {
                        $clean = $typedPath.Trim('"').Trim("'")
                        $path = if ([string]::IsNullOrEmpty($clean)) { $item.Name } else {
                            $dir = [IO.Path]::GetDirectoryName($clean)
                            if ([string]::IsNullOrEmpty($dir)) { $item.Name }
                            elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $dir + $item.Name }
                            else { $dir + '\' + $item.Name }
                        }
                        if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                        if ($item.PSIsContainer) { $path += '\' }
                        $candidateBuffers += ('!' + $commandText.Substring(0,$prefixLength) + $path)
                        $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                    }
                }
            }
            # File and session path arguments.
            elseif ($b -match '^(\.(?:file|text|exportsession|loadsession))(\s+)(.*)$') {
                $head = $matches[1] + $matches[2]
                $typed = $matches[3]
                $pathItems = @(Get-GemFiles $typed)
                foreach ($item in $pathItems) {
                    $clean = $typed.Trim('"').Trim("'")
                    $path = if ([string]::IsNullOrEmpty($clean)) { $item.Name } else {
                        $dir = [IO.Path]::GetDirectoryName($clean)
                        if ([string]::IsNullOrEmpty($dir)) { $item.Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $dir + $item.Name }
                        else { $dir + '\' + $item.Name }
                    }
                    if ($typed.StartsWith('"') -or $typed.StartsWith("'")) { $path = $typed[0] + $path + $typed[0] }
                    if ($item.PSIsContainer) { $path += '\' }
                    $candidateBuffers += ($head + $path)
                    $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                }
            }
            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*)
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
                $diffText = $matches[1]
                $tokenMatch = [regex]::Match($diffText,'(?:^|\s)([^\s]*)            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
)
                $typedPath = $tokenMatch.Groups[1].Value
                $pathItems = @(Get-GemFiles $typedPath)
                $prefixLength = $diffText.Length - $typedPath.Length
                foreach ($item in $pathItems) {
                    $clean = $typedPath.Trim('"').Trim("'")
                    $path = if ([string]::IsNullOrEmpty($clean)) { $item.Name } else {
                        $dir = [IO.Path]::GetDirectoryName($clean)
                        if ([string]::IsNullOrEmpty($dir)) { $item.Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $dir + $item.Name }
                        else { $dir + '\' + $item.Name }
                    }
                    if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                    if ($item.PSIsContainer) { $path += '\' }
                    $candidateBuffers += ('.diff ' + $diffText.Substring(0,$prefixLength) + $path)
                    $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                }
            }
            # Argument completions for built-in commands.
            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
                $diffText = $matches[1]
                $tokenMatch = [regex]::Match($diffText,'(?:^|\s)([^\s]*)            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
)
                $typedPath = $tokenMatch.Groups[1].Value
                $pathItems = @(Get-GemFiles $typedPath)
                $prefixLength = $diffText.Length - $typedPath.Length
                foreach ($item in $pathItems) {
                    $clean = $typedPath.Trim('"').Trim("'")
                    $path = if ([string]::IsNullOrEmpty($clean)) { $item.Name } else {
                        $dir = [IO.Path]::GetDirectoryName($clean)
                        if ([string]::IsNullOrEmpty($dir)) { $item.Name }
                        elseif ($dir.EndsWith('\') -or $dir.EndsWith('/')) { $dir + $item.Name }
                        else { $dir + '\' + $item.Name }
                    }
                    if ($typedPath.StartsWith('"') -or $typedPath.StartsWith("'")) { $path = $typedPath[0] + $path + $typedPath[0] }
                    if ($item.PSIsContainer) { $path += '\' }
                    $candidateBuffers += ('.diff ' + $diffText.Substring(0,$prefixLength) + $path)
                    $candidateLabels += $(if ($item.PSIsContainer) { $item.Name + '\' } else { $item.Name })
                }
            }
            # Argument completions for built-in commands.
            elseif ($b -match '^\.provider\s+(\S*)$') {
                foreach ($item in @('antigravity','gemini' | Where-Object { $_.StartsWith($matches[1],[StringComparison]::OrdinalIgnoreCase) })) {
                    $candidateBuffers += ('.provider ' + $item); $candidateLabels += $item
                }
            }
            elseif ($b -match '^\.(grounding|auth|effort)\s+(\S*) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
) {
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
                $completionIndex = 0
                $old = $b; $b = [string]$completionCandidates[0]; $c = $b.Length
                [Console]::WriteLine()
                for ($n = 0; $n -lt $candidateLabels.Count; $n++) {
                    $prefix = if ($n -eq 0) { '> ' } else { '  ' }
                    [Console]::WriteLine($prefix + [string]$candidateLabels[$n])
                }
                [Console]::WriteLine('j/k navigate  Enter accept  Esc cancel')
                $row = [Console]::CursorTop
                Redraw $old $b $c
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
