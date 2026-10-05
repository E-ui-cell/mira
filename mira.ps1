#requires -Version 5.1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Normalize the Windows 7 Explorer "Run with PowerShell" argument wrapper
# before normal MIRA CLI argument parsing. No process relaunch is required.
function Get-MiraCliArgs {
    param([object[]]$RawArgs)

    $a=@($RawArgs | ForEach-Object {[string]$_})

    # Windows 7 Explorer's 'Run with PowerShell' verb on this machine
    # appends this legacy execution-policy command after -File.
    # Strip only that exact association suffix; ordinary MIRA args pass through.
    if($a.Count -ge 2 -and $a[0] -ieq '-Command'){
        $cmd=([string]$a[1]).Replace(' ','').Replace([string][char]9,'').Replace([string][char]13,'').Replace([string][char]10,'')
        $expected='if((Get-ExecutionPolicy)-neAllSigned){Set-ExecutionPolicy-ScopeProcessBypass}'
        if($cmd -ieq $expected){
            return @($a | Select-Object -Skip 2)
        }
    }

    return $a
}

$cliArgs=Get-MiraCliArgs $args
$script:MiraVersion = '0.1.0-beta.2'
$script:MiraBuild = 'b90879230'

# MIRA-TUI BETA 0.1.0-beta.2 / BUILD b90879230
# Own readline + fish-like history + completion + multiline + file/read/diff/image sending.
# Native Gemini + built-in OpenAI-compatible providers. No provider JSON config.
# No PSReadLine. No external modules.

$script:History = New-Object System.Collections.Generic.List[string]
$script:HistIndex = -1
$script:HistDraft = ''
$script:HistSearch = $false
$script:HistPrefix = ''
$script:HistSearchIndex = 0
$script:MenuVisible = $false
$script:MenuTop = 0
$script:MenuRows = 0
$script:MenuItems = @()
$script:MenuIndex = 0
$script:MenuKind = ''
$script:MenuCommand = ''
$script:RenderRows = 1
$script:LastStatusRow = -1
$script:LastStatusText = ''
$script:LastStatusHasBullet = $false
$script:Running = $true
$script:LastText = ''
$script:LastRequest = ''
$script:Conversation = New-Object System.Collections.Generic.List[object]
$script:Providers = @()
$script:CurrentProviderName = 'gemini'
$script:CurrentModel = if($env:GEMINI_MODEL){$env:GEMINI_MODEL}else{'gemini-flash-lite-latest'}
$script:SessionActive = $false
$script:SessionName = ''
$script:SessionSummary = ''
$script:LastPromptTokens = 0
$script:LastRequestElapsedMs = 0
$script:LastRequestFrame = '... '
$script:DryRunMode = $false
$script:CliArgsImplemented = @('-d','--dry-run')
$script:CliArgsNotImplemented = @('-m, --model <name>','-e, --execute','-h, --help','--')

# -----------------------------------------------------------------------------
# UI RUNTIME SWITCHES
# These affect only the visual renderer. Raw .copy/.grab/.save data is unchanged.
# -----------------------------------------------------------------------------
$script:UiRenderEnabled = $true
$script:ResponseFrameWaiting = $false
$script:ResponseFrameLiveRow = -1
$script:ResponseFrameWidth = 0
$script:ResponseFrameCursorCaptured = $false
$script:ResponseFrameCursorVisible = $true
$script:CompressThreshold = if($env:MIRA_COMPRESS_THRESHOLD){[int]$env:MIRA_COMPRESS_THRESHOLD}else{4000}
$script:OpenRouterApiKey = 'PASTE_OPENROUTER_KEY_HERE'
$script:StreamResponses = $false
$script:ShowReasoning = $false
# Persistent history is ON by default. Set MIRA_PERSIST_HISTORY=0/false/off to disable it.
$script:PersistHistory = -not ($env:MIRA_PERSIST_HISTORY -eq '0' -or $env:MIRA_PERSIST_HISTORY -eq 'false' -or $env:MIRA_PERSIST_HISTORY -eq 'off')
$script:HistoryLoadLimit = if($env:MIRA_HISTORY_LOAD_LIMIT){[Math]::Max(1,[int]$env:MIRA_HISTORY_LOAD_LIMIT)}else{50}
$script:HistoryFile = if($env:MIRA_HISTORY_FILE){$env:MIRA_HISTORY_FILE}else{Join-Path (Join-Path $env:LOCALAPPDATA 'Mira-TUI') 'history.json'}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){ $script:HistoryFile = Join-Path (Get-Location).Path 'mira-history.json' }
# Model-list cache lives in TEMP5 when defined, otherwise standard TEMP.
# Startup and .model completion never fetch; only .models + Tab refreshes caches.
$script:ModelCacheRoot = if(-not [string]::IsNullOrWhiteSpace($env:TEMP5)){Join-Path $env:TEMP5 'Mira-TUI'}elseif(-not [string]::IsNullOrWhiteSpace($env:TEMP)){Join-Path $env:TEMP 'Mira-TUI'}else{Join-Path (Get-Location).Path '.mira-tmp'}
$script:UsedModelsCacheFile = Join-Path $script:ModelCacheRoot 'used.list'
$script:ModelMenuActive = $false
$script:ModelMenuItems = @()
$script:ModelMenuIndex = 0
$script:ModelMenuTyped = ''

$script:Commands = @(
    '.help','.clear','.clear history','.history','.history persist on','.history persist off','.file','.read','.diff','.shot','.model','.models','.models test','.providers','.request','.request json','.save','.copy','.grab','.ui','.stream','.reasoning','.session','.empty session','.compress session','.delete session','.q',':q',':wq'
)

# -----------------------------------------------------------------------------
# MARKUP / CODE-BLOCK / MATH THEME
# Small, boring, editable theme. Markdown decides WHAT is rendered;
# this block decides only HOW it looks. No punctuation/Unicode normalization
# is done here.
# -----------------------------------------------------------------------------
$script:MarkupTheme = [pscustomobject]@{
    # Visual semantic: "<-- this whole region is Mira's response surface."

    # -------------------------------------------------------------------------
    # WHOLE MESSAGE FRAME -- quiet full-width top/bottom frame around the reply.
    # The final status line is embedded into the TOP border.
    # -------------------------------------------------------------------------
    MessageFrameEnabled  = $true
    MessageFrameColor    = 'DarkGray'      # fallback only when truecolor is unavailable
    MessageFrameRGB       = '50;52;58'      # intentionally fades into a dark terminal
    MessageTopLeft       = [char]0x250C     # ┌
    MessageTopRight      = [char]0x2510     # ┐
    MessageBottomLeft    = [char]0x2514     # └
    MessageBottomRight   = [char]0x2518     # ┘
    MessageHorizontal    = [char]0x2500     # ─
    MessageTopPrefix     = '───'            # after ┌, before status
    MessageLeftPadding   = '  '             # response text indent

    # -------------------------------------------------------------------------
    # CODE BLOCK THEME -- short U+2219 separator, about 25% of terminal width.
    # -------------------------------------------------------------------------
    CodeFrameColor       = 'DarkGray'       # fallback separator color
    CodeFrameRGB          = '96;100;110'     # slightly more visible than the outer frame
    CodeLanguageColor    = 'Red'            # language label color
    CodeTextColor        = 'Gray'           # code text color
    CodeHeaderPrefix     = '∙∙ '            # two U+2219 bullets + space
    CodeLanguageGap      = ' '              # one space after language
    CodeRuleChar         = '∙'              # U+2219 BULLET OPERATOR
    CodeRulePercent      = 0.25             # about 25% of terminal width
    CodeRuleMinWidth     = 18               # minimum readable rule
    CodeShowLanguage     = $true
    InlineTextRGB              = '205;207;212'
    InlineBoldRGB              = '245;245;248'
    InlineItalicRGB            = '205;215;225'
    InlineUnderlineRGB         = '100;190;235'
    InlineStrikeRGB            = '145;148;155'
    InlineCodeRGB              = '235;235;220'
    InlineCodeBG               = '38;41;48'
    InlineMarkRGB              = '245;235;205'
    InlineMarkBG               = '86;74;38'
    InlineKbdRGB               = '245;245;245'
    InlineKbdBG                = '55;58;66'
    InlineLinkRGB              = '100;190;240'
    InlineQuoteRGB             = '120;160;185'
    InlineTagRGB               = '145;150;160'
    CodePanelRGB               = '180;182;188'
    CodePanelBG                = '30;33;39'
    CodeHeaderRGB              = '210;212;218'
    CodeHeaderBG               = '42;45;53'
    TableHeaderRGB             = '225;230;235'
    TableHeaderBG              = '42;48;58'


    # ---- MATH BLOCK THEME ---------------------------------------------------
    MathFrameColor       = 'DarkGray'       # fallback separator color
    MathFrameRGB          = '96;100;110'     # slightly more visible than the outer frame
    MathLanguageColor    = 'Cyan'           # optional MATH label color
    MathTextColor        = 'Gray'           # rendered formula color
    MathHeaderPrefix     = '∙∙ '            # U+2219 U+2219 + space
    MathLanguageGap      = ' '              # one space after MATH
    MathRuleChar         = '∙'              # U+2219 BULLET OPERATOR
    MathRulePercent      = 0.25             # same graphic width as code blocks
    MathRuleMinWidth     = 18

    # ---- language labels ----------------------------------------------------
    CodeLanguageMap       = @{
        bash       = 'Bash'
        powershell = 'PowerShell'
        ps         = 'PowerShell (PS)'
        ps1        = 'PowerShell (PS)'
        pwsh       = 'PowerShell'
        python     = 'Python'
        py         = 'Python'
        lua        = 'Lua'
        json       = 'JSON'
        jsonc      = 'JSONC'
        markdown   = 'Markdown'
        md         = 'Markdown'
        sh         = 'SH'
    }
}

function W($s='', [ConsoleColor]$c = [ConsoleColor]::Gray) {
    Write-Host $s -ForegroundColor $c
}

function Cursor($x,$y) {
    try {
        [Console]::SetCursorPosition([int]$x,[int]$y)
        return $true
    } catch {
        try {
            $Host.UI.RawUI.CursorPosition = New-Object Management.Automation.Host.Coordinates([int]$x,[int]$y)
            return $true
        } catch { return $false }
    }
}

function Row() {
    try { return [Console]::CursorTop } catch { try { return $Host.UI.RawUI.CursorPosition.Y } catch { return 0 } }
}

function Width() {
    try { return [Math]::Max(20,[Console]::WindowWidth) } catch { try { return [Math]::Max(20,$Host.UI.RawUI.WindowSize.Width) } catch { return 80 } }
}

function Read-Key() {
    # Return the native ConsoleKeyInfo whenever possible.
    # History navigation reads .Key directly in Read-Line.
    try {
        return [Console]::ReadKey($true)
    } catch {
        $r = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $mods = [ConsoleModifiers]0
        $st = [int]$r.ControlKeyState
        if(($st -band 16) -ne 0){$mods = $mods -bor [ConsoleModifiers]::Shift}
        if(($st -band 12) -ne 0){$mods = $mods -bor [ConsoleModifiers]::Control}
        if(($st -band 3) -ne 0){$mods = $mods -bor [ConsoleModifiers]::Alt}
        return [pscustomobject]@{
            Key       = [ConsoleKey][int]$r.VirtualKeyCode
            KeyChar   = [char]$r.Character
            Modifiers = $mods
        }
    }
}

function Available() {
    try { return [Console]::KeyAvailable } catch { try { return $Host.UI.RawUI.KeyAvailable } catch { return $false } }
}

function Clear-Menu() {
    if (-not $script:MenuVisible) {
        $script:MenuItems=@()
        $script:MenuIndex=0
        $script:MenuKind=''
        $script:MenuCommand=''
        return
    }
    $w = Width
    for ($i=0; $i -lt $script:MenuRows; ++$i) {
        if (Cursor 0 ($script:MenuTop + $i)) { [Console]::Write((' ' * ($w - 1))) }
    }
    $script:MenuVisible = $false
    $script:MenuTop = 0
    $script:MenuRows = 0
    $script:MenuItems=@()
    $script:MenuIndex=0
    $script:MenuKind=''
    $script:MenuCommand=''
}

function Get-MenuItemText($item) {
    if($null -ne $item -and $null -ne $item.PSObject.Properties['Completion']) { return [string]$item.Completion }
    if($null -ne $item) { return [string]$item.Name }
    return ''
}

function Move-Menu([int]$direction,$promptRow,[ref]$buffer,[ref]$cursor) {
    if(-not $script:MenuVisible -or $script:MenuItems.Count -eq 0){return}
    $count=[int]$script:MenuItems.Count
    $script:MenuIndex=($script:MenuIndex+$direction)%$count
    if($script:MenuIndex -lt 0){$script:MenuIndex += $count}

    # Navigation only changes the highlighted menu item.
    # Do not overwrite the prompt buffer until Enter accepts the selection.
    $saved=@($script:MenuItems)
    $kind=[string]$script:MenuKind
    $cmd=[string]$script:MenuCommand
    $idx=[int]$script:MenuIndex
    Show-Menu $saved $promptRow $buffer.Value $cursor.Value $kind $cmd $idx
}

function Accept-Menu($promptRow,[ref]$buffer,[ref]$cursor) {
    if(-not $script:MenuVisible -or $script:MenuItems.Count -eq 0){return $false}
    $i=[Math]::Max(0,[Math]::Min([int]$script:MenuIndex,$script:MenuItems.Count-1))
    $value=Get-MenuItemText $script:MenuItems[$i]
    if([string]::IsNullOrEmpty($value)){return $false}
    $buffer.Value=$value
    $cursor.Value=$buffer.Value.Length
    Clear-Menu
    Redraw $buffer.Value $cursor.Value $promptRow
    return $true
}

function Get-TuiPrompt([int]$lineIndex) {
    if($lineIndex -eq 0){
        if($script:SessionActive -and -not [string]::IsNullOrWhiteSpace($script:SessionName)){
            return [string]$script:SessionName + ' > '
        }
        return '> '
    }
    return '... '
}

function Refresh-TuiWindow(){
    # Repaint the visible console buffer without clearing or rebuilding the screen.
    # This is the Ctrl+L action: same cells, same content, fresh host repaint.
    try{
        $ui=$Host.UI.RawUI
        $window=$ui.WindowSize
        $position=$ui.WindowPosition
        $rect=New-Object System.Management.Automation.Host.Rectangle(
            $position.X,
            $position.Y,
            $position.X+$window.Width-1,
            $position.Y+$window.Height-1
        )
        $cells=$ui.GetBufferContents($rect)
        $ui.SetBufferContents($rect,$cells)
        return $true
    }catch{
        try{
            $x=[Console]::CursorLeft
            $y=[Console]::CursorTop
            [Console]::SetCursorPosition($x,$y)
        }catch{}
        return $false
    }
}

function Redraw($buffer,$cursor,$row) {
    $w = Width
    $parts = $buffer -split "`n", -1
    $before = if ($cursor -gt 0) { $buffer.Substring(0,[Math]::Min($cursor,$buffer.Length)) } else { '' }
    $bl = $before -split "`n", -1
    $cl = $bl.Count - 1
    $cc = $bl[-1].Length

    # Remember how many physical rows we drew so shrinking a multiline buffer
    # does not leave stale text behind on the terminal.
    $oldRows = if($null -eq $script:RenderRows){1}else{[int]$script:RenderRows}
    $drawRows = [Math]::Max($oldRows,[Math]::Max(1,$parts.Count))
    for ($r=0; $r -lt $drawRows; ++$r) {
        if (Cursor 0 ($row+$r)) {
            [Console]::Write((' ' * [Math]::Max(1,$w-1)))
        }
    }

    for ($r=0; $r -lt $parts.Count; ++$r) {
        if (-not (Cursor 0 ($row+$r))) { continue }
        $prompt = Get-TuiPrompt $r
        $promptLen = $prompt.Length
        # Preserve the old 4-column safety margin for the normal '> ' prompt,
        # while making the usable text width follow the actual prompt length.
        $usable = [Math]::Max(1,$w-$promptLen-2)
        [Console]::Write($prompt)

        $line = [string]$parts[$r]
        $start = 0
        if ($r -eq $cl -and $line.Length -gt $usable) {
            $start = [Math]::Max(0,$cc-$usable+1)
        } elseif ($line.Length -gt $usable) {
            $start = $line.Length - $usable
        }
        $shown = if ($start -lt $line.Length) {
            $line.Substring($start,[Math]::Min($usable,$line.Length-$start))
        } else { '' }
        [Console]::Write($shown)
    }

    $currentPrompt = Get-TuiPrompt $cl
    $currentUsable = [Math]::Max(1,$w-$currentPrompt.Length-2)
    $ds = if ($cc -ge $currentUsable) { $cc-$currentUsable+1 } else { 0 }
    $dx = $currentPrompt.Length + ($cc-$ds)
    if ($dx -ge $w) { $dx=$w-1 }
    [void](Cursor $dx ($row+$cl))
    try { [Console]::CursorVisible = $true } catch {}
    $script:RenderRows = [Math]::Max(1,$parts.Count)
}

function CommonPrefix([string[]]$v) {
    if (!$v -or $v.Count -eq 0) { return '' }
    $p = [string]$v[0]
    for ($i=1;$i -lt $v.Count -and $p.Length -gt 0;++$i) {
        $n=[string]$v[$i]; $j=0; $m=[Math]::Min($p.Length,$n.Length)
        while ($j -lt $m -and [Char]::ToLowerInvariant($p[$j]) -eq [Char]::ToLowerInvariant($n[$j])) { ++$j }
        $p=$p.Substring(0,$j)
    }
    return $p
}

function PathCandidates([string]$typed) {
    $raw = if ($null -eq $typed) { '' } else { [string]$typed }
    if ($raw.StartsWith('"') -or $raw.StartsWith("'")) { $raw=$raw.Substring(1) }
    if ($raw.StartsWith('~')) { $raw=$env:USERPROFILE+$raw.Substring(1) }
    if ([string]::IsNullOrEmpty($raw)) { $dir=(Get-Location).Path; $leaf='' }
    else {
        try { $dir=[IO.Path]::GetDirectoryName($raw); $leaf=[IO.Path]::GetFileName($raw) } catch { return @() }
        if (!$dir) { $dir=(Get-Location).Path }
    }
    try {
        @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($leaf,[StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object @{Expression='LastWriteTime';Descending=$true}, Name)
    } catch { @() }
}

function Show-Menu($items,$promptRow,$buffer,$cursor,$kind='generic',$command='',$selectedIndex=0) {
    Clear-Menu
    if (!$items -or $items.Count -eq 0) { return }
    $script:MenuItems=@($items)
    $script:MenuIndex=[Math]::Max(0,[Math]::Min([int]$selectedIndex,$script:MenuItems.Count-1))
    $script:MenuKind=[string]$kind
    $script:MenuCommand=[string]$command

    $w=Width
    $max=1
    foreach($x in $script:MenuItems) { $n=[string]$x.Name; if($x.PSIsContainer){$n+='\'}; if($n.Length -gt $max){$max=$n.Length} }
    $colW=$max+4
    $cols=[Math]::Max(1,[int][Math]::Floor(($w-1)/$colW))
    if($cols -gt $script:MenuItems.Count){$cols=$script:MenuItems.Count}
    $rows=[int][Math]::Ceiling($script:MenuItems.Count/[double]$cols)
    $showRows=[Math]::Min($rows,10)
    $pageSize=[Math]::Max(1,$showRows*$cols)
    $pageStart=[int]([Math]::Floor($script:MenuIndex/[double]$pageSize)*$pageSize)
    $pageCount=[Math]::Min($pageSize,$script:MenuItems.Count-$pageStart)

    $script:MenuTop=$promptRow+1
    $script:MenuRows=$showRows
    $script:MenuVisible=$true

    for($r=0;$r -lt $showRows;++$r){
        if(-not (Cursor 0 ($script:MenuTop+$r))){continue}
        [Console]::Write((' ' * ($w-1)))
        [void](Cursor 0 ($script:MenuTop+$r))
        for($c=0;$c -lt $cols;++$c){
            $local=$r+($c*$showRows)
            if($local -ge $pageCount){break}
            $i=$pageStart+$local
            $n=[string]$script:MenuItems[$i].Name
            if($script:MenuItems[$i].PSIsContainer){$n+='\'}
            $last=($c -eq $cols-1 -or $local+$showRows -ge $pageCount)
            $mark=if($i -eq $script:MenuIndex){'> '}else{'  '}
            $cell=$mark+$n
            if($i -eq $script:MenuIndex){
                Write-Host $cell -NoNewline -ForegroundColor Black -BackgroundColor Gray
                if(-not $last){Write-Host (' ' * [Math]::Max(0,$colW-$cell.Length)) -NoNewline -ForegroundColor Black -BackgroundColor Gray}
            }else{
                Write-Host $cell -NoNewline -ForegroundColor DarkGray
                if(-not $last){Write-Host (' ' * [Math]::Max(0,$colW-$cell.Length)) -NoNewline -ForegroundColor DarkGray}
            }
        }
    }

    $extraAfter=$script:MenuItems.Count-($pageStart+$pageCount)
    $extraBefore=$pageStart
    if($extraBefore -gt 0 -or $extraAfter -gt 0){
        $parts=@()
        if($extraBefore -gt 0){$parts+=('↑ '+$extraBefore+' above')}
        if($extraAfter -gt 0){$parts+=('↓ '+$extraAfter+' more')}
        $msg=($parts -join '  ')+' — Tab/Shift+Tab/↑/↓/j/k  Enter=accept  Esc=close'
        if(Cursor 0 ($script:MenuTop+$script:MenuRows)){
            [Console]::Write((' ' * ($w-1)))
            [void](Cursor 0 ($script:MenuTop+$script:MenuRows))
            Write-Host $msg -NoNewline -ForegroundColor DarkGray
        }
        ++$script:MenuRows
    }
    Redraw $buffer $cursor $promptRow
}

function Get-LocalAppCandidates([string]$typed){
    $q=if($null -eq $typed){''}else{$typed.Trim()}
    $seen=@{}
    $items=New-Object System.Collections.Generic.List[string]

    # Scan PATH directly. This is reliable in Windows PowerShell 5.1 and does
    # not depend on the host's command-discovery behavior.
    try{
        $exts=@('.EXE','.COM','.BAT','.CMD','.PS1')
        if(-not [string]::IsNullOrWhiteSpace($env:PATHEXT)){
            $exts=@($env:PATHEXT -split ';' | ForEach-Object {$_.Trim().ToUpperInvariant()} | Where-Object {$_})
        }
        foreach($dir in @($env:Path -split ';')){
            if([string]::IsNullOrWhiteSpace($dir)){continue}
            try{
                foreach($item in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)){
                    $name=[string]$item.Name
                    if([string]::IsNullOrWhiteSpace($name)){continue}
                    $ext=([IO.Path]::GetExtension($name)).ToUpperInvariant()
                    if($exts -notcontains $ext){continue}
                    if(-not $name.StartsWith($q,[StringComparison]::OrdinalIgnoreCase)){continue}
                    if(-not $seen.ContainsKey($name)){
                        $seen[$name]=$true
                        [void]$items.Add($name)
                    }
                }
            }catch{}
        }
    }catch{}

    return @($items | Sort-Object)
}

function Complete-LocalApp($buffer,$row){
    $q=[string]$buffer
    if(-not $q.StartsWith('!')){return $q}

    # First token: complete executable name.
    if($q -notmatch '^!([^\s]*)$' -and $q -match '^!([^\s]+)\s+(.*)$'){
        $command=[string]$Matches[1]
        $argText=[string]$Matches[2]
        $sp=$q.IndexOf(' ')
        $prefix=$q.Substring(0,$sp+1)
        $lastSpace=$argText.LastIndexOf(' ')
        if($lastSpace -ge 0){
            $prefix += $argText.Substring(0,$lastSpace+1)
            $typed=$argText.Substring($lastSpace+1)
        }else{
            $typed=$argText
        }

        # Reuse the same filesystem/path completion logic as .file/.diff.
        try{
            $items=@(PathCandidates $typed)
            if($items.Count -eq 0){return $q}

            $quote=''
            $displayTyped=$typed
            if($displayTyped.StartsWith('"') -or $displayTyped.StartsWith("'")){
                $quote=$displayTyped.Substring(0,1)
                $displayTyped=$displayTyped.Substring(1)
            }

            $leaf=$displayTyped
            $k=$leaf.LastIndexOfAny([char[]]@('\','/'))
            $dirPrefix=''
            if($k -ge 0){
                $dirPrefix=$leaf.Substring(0,$k+1)
                $leaf=$leaf.Substring($k+1)
            }

            $names=@($items|ForEach-Object{[string]$_.Name})
            $comp=if($items.Count -eq 1){$names[0]}else{CommonPrefix $names}
            if($comp.Length -lt $leaf.Length){$comp=$leaf}

            $new=$dirPrefix+$comp
            if($quote){$new=$quote+$new}
            if($items.Count -eq 1 -and $items[0].PSIsContainer){
                $new=$new.TrimEnd('\','/')+'\'
            }

            $nb=$prefix+$new
            if($nb -ne $q){
                Clear-Menu
                return $nb
            }

            $menu=@($items|ForEach-Object{
                $n=[string]$_.Name
                $v=$dirPrefix+$n
                if($quote){$v=$quote+$v}
                if($_.PSIsContainer){$v=$v.TrimEnd('\','/')+'\'}
                [pscustomobject]@{
                    Name=$n
                    PSIsContainer=$_.PSIsContainer
                    Completion=($prefix+$v)
                }
            })
            Show-Menu $menu $row $q $q.Length 'path' '' 0
            return $q
        }catch{
            return $q
        }
    }

    $rest=$q.Substring(1)
    if($rest -match '\s'){return $q}

    $items=@(Get-LocalAppCandidates $rest)
    if($items.Count -eq 0){return $q}
    if($items.Count -eq 1){return '!'+[string]$items[0]}

    $p=CommonPrefix $items
    if($p.Length -gt $rest.Length){return '!'+$p}

    $menu=@($items|ForEach-Object{
        [pscustomobject]@{
            Name=('!'+[string]$_)
            PSIsContainer=$false
            Completion=('!'+[string]$_)
        }
    })
    Show-Menu $menu $row $q $q.Length 'command' '' 0
    return $q
}

function Complete-Command($buffer,$row) {
    $q=[string]$buffer
    $m=@($script:Commands | Where-Object { $_.StartsWith($q,[StringComparison]::OrdinalIgnoreCase) })
    if($m.Count -eq 1){return $m[0]}
    if($m.Count -gt 1){
        $p=CommonPrefix $m
        if($p.Length -gt $q.Length){return $p}
        $menu=@($m|ForEach-Object{[pscustomobject]@{Name=$_;PSIsContainer=$false;Completion=$_}})
        Show-Menu $menu $row $q $q.Length 'command' '' 0
        return $q
    }
    return $q
}

function Complete-Path($buffer,$cursor,$row,$command) {
    $sp=$buffer.IndexOf(' '); if($sp -lt 0){ return $false }
    $prefix=$buffer.Substring(0,$sp+1); $typed=$buffer.Substring($sp+1)
    if($command -eq '.diff' -and $typed.Contains(' ')){ $ls=$typed.LastIndexOf(' '); $prefix=$buffer.Substring(0,$sp+1+$ls+1); $typed=$typed.Substring($ls+1) }
    $items=@(PathCandidates $typed); if($items.Count -eq 0){ return $true }
    $quote=''; $displayTyped=$typed
    if($displayTyped.StartsWith('"') -or $displayTyped.StartsWith("'")){ $quote=$displayTyped.Substring(0,1); $displayTyped=$displayTyped.Substring(1) }
    $leaf=$displayTyped; $k=$leaf.LastIndexOfAny([char[]]@('\','/')); $dirPrefix=''; if($k -ge 0){$dirPrefix=$leaf.Substring(0,$k+1);$leaf=$leaf.Substring($k+1)}
    $names=@($items|ForEach-Object{[string]$_.Name})
    $comp=if($items.Count -eq 1){$names[0]}else{CommonPrefix $names}
    if($comp.Length -lt $leaf.Length){$comp=$leaf}
    $new=$dirPrefix+$comp; if($quote){$new=$quote+$new}; if($items.Count -eq 1 -and $items[0].PSIsContainer){$new=$new.TrimEnd('\','/')+'\'}
    $nb=$prefix+$new
    if($nb -ne $buffer){ Clear-Menu; return $nb }

    $menu=@($items|ForEach-Object{
        $n=[string]$_.Name
        $v=$dirPrefix+$n
        if($quote){$v=$quote+$v}
        if($_.PSIsContainer){$v=$v.TrimEnd('\','/')+'\'}
        [pscustomobject]@{Name=$n;PSIsContainer=$_.PSIsContainer;Completion=($prefix+$v)}
    })
    # First Tab opens the picker; do not consume the first item yet.
    # Selection is then controlled by Tab/Shift+Tab, Up/Down, or j/k.
    Show-Menu $menu $row $buffer $cursor 'path' $command 0
    return $null
}

function Normalize-TuiHistoryEntry([string]$s){
    if([string]::IsNullOrWhiteSpace($s)){return ''}
    # Keep embedded newlines. A previous version removed CRLF globally and could
    # turn multiline input into one long line.
    $x=$s -replace '\r\n','`n'
    $x=$x.TrimEnd("`n")
    # Remove only a visible prompt marker from the first line.
    if($x.StartsWith('> ')){$x=$x.Substring(2)}
    elseif($x.StartsWith('... ')){$x=$x.Substring(4)}
    return $x
}

function Add-TuiHistory($s){
    $s=Normalize-TuiHistoryEntry $s
    if([string]::IsNullOrWhiteSpace($s)){return}
    if($script:History.Count -eq 0 -or $script:History[$script:History.Count-1] -ne $s){[void]$script:History.Add($s)}
    while($script:History.Count -gt 500){$script:History.RemoveAt(0)}
}

function Expand-TuiHistoryValue($value,[System.Collections.Generic.List[string]]$out){
    if($null -eq $value){return}

    # Old builds could accidentally save the complete JSON array as one JSON
    # string. Unwrap that form before it reaches readline.
    if($value -is [string]){
        $text=[string]$value
        $trim=$text.Trim()
        if($trim.StartsWith('[') -and $trim.EndsWith(']')){
            try{
                $inner=@($trim | ConvertFrom-Json -ErrorAction Stop)
                if($inner.Count -gt 0 -or $trim -eq '[]'){
                    foreach($item in $inner){Expand-TuiHistoryValue $item $out}
                    return
                }
            }catch{}
        }
        if($trim.StartsWith('{') -and $trim.EndsWith('}')){
            try{
                $obj=$trim | ConvertFrom-Json -ErrorAction Stop
                if($null -ne $obj.history){foreach($item in @($obj.history)){Expand-TuiHistoryValue $item $out};return}
                if($null -ne $obj.items){foreach($item in @($obj.items)){Expand-TuiHistoryValue $item $out};return}
            }catch{}
        }
        $clean=Normalize-TuiHistoryEntry $text
        if(-not [string]::IsNullOrWhiteSpace($clean)){[void]$out.Add($clean)}
        return
    }

    if($value -is [System.Collections.IEnumerable]){
        foreach($item in $value){Expand-TuiHistoryValue $item $out}
        return
    }

    try{
        if($null -ne $value.history){foreach($item in @($value.history)){Expand-TuiHistoryValue $item $out};return}
        if($null -ne $value.items){foreach($item in @($value.items)){Expand-TuiHistoryValue $item $out};return}
    }catch{}

    $clean=Normalize-TuiHistoryEntry ([string]$value)
    if(-not [string]::IsNullOrWhiteSpace($clean)){[void]$out.Add($clean)}
}

function Load-TuiHistory(){
    if(-not $script:PersistHistory){return}
    if(-not (Test-Path -LiteralPath $script:HistoryFile)){return}
    try{
        $raw=Get-Content -LiteralPath $script:HistoryFile -Raw -Encoding UTF8 -ErrorAction Stop
        if([string]::IsNullOrWhiteSpace($raw)){return}

        $loaded=New-Object System.Collections.Generic.List[string]
        $parsed=$false
        try{
            $root=$raw | ConvertFrom-Json -ErrorAction Stop
            Expand-TuiHistoryValue $root $loaded
            $parsed=$true
        }catch{}

        if(-not $parsed){
            # Backward-compatible fallback for old line-based history files.
            foreach($line in @($raw -split "`r?`n")){
                $clean=Normalize-TuiHistoryEntry ([string]$line)
                if(-not [string]::IsNullOrWhiteSpace($clean)){[void]$loaded.Add($clean)}
            }
        }

        # De-duplicate while preserving order, then keep only recent entries.
        $unique=New-Object System.Collections.Generic.List[string]
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($item in $loaded){
            if($seen.Add([string]$item)){[void]$unique.Add([string]$item)}
        }
        $start=[Math]::Max(0,$unique.Count-$script:HistoryLoadLimit)
        for($i=$start;$i -lt $unique.Count;++$i){[void]$script:History.Add([string]$unique[$i])}
        while($script:History.Count -gt $script:HistoryLoadLimit){$script:History.RemoveAt(0)}
    }catch{
        W ('[history load warning] '+$_.Exception.Message) Yellow
    }
}

function Save-TuiHistory(){
    if(-not $script:PersistHistory){return}
    try{
        $dir=Split-Path -Parent $script:HistoryFile
        if(-not (Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)}
        $start=[Math]::Max(0,$script:History.Count-$script:HistoryLoadLimit)
        [string[]]$items=@()
        if($script:History.Count -gt 0){$items=@($script:History.ToArray())[$start..($script:History.Count-1)]}
        $json=ConvertTo-Json -InputObject ([object[]]$items) -Depth 4 -Compress
        [IO.File]::WriteAllText($script:HistoryFile,$json,[Text.UTF8Encoding]::new($false))
    }catch{
        W ('[history save warning] '+$_.Exception.Message) Yellow
    }
}

function Set-TuiHistoryPersistence([bool]$Enabled){
    $script:PersistHistory=$Enabled
    if($Enabled){
        Save-TuiHistory
        W ('[history persistence ON] '+$script:HistoryFile) DarkGray
    }else{
        W '[history persistence OFF] (RAM only)' DarkGray
    }
}

function Show-TuiHistory(){
    W ('[history: '+$script:History.Count+' entries | persistence: '+$(if($script:PersistHistory){'on'}else{'off'})+']') Cyan
    if($script:History.Count -eq 0){W '[history empty]' DarkGray;return}
    $start=[Math]::Max(0,$script:History.Count-50)
    for($i=$start;$i -lt $script:History.Count;++$i){W ((($i+1).ToString().PadLeft(4))+ '  '+$script:History[$i]) Gray}
}
function Reset-TuiHistorySearch(){
    $script:HistSearch=$false
    $script:HistPrefix=''
    $script:HistSearchIndex=0
}



function New-BuiltinProviders(){
    @(
        [pscustomobject]@{name='gemini';     type='gemini';            api_base='https://generativelanguage.googleapis.com/v1beta'; api_key_env='GEMINI_API_KEY'; safetySettings=@(
            [pscustomobject]@{category='HARM_CATEGORY_HARASSMENT';threshold='BLOCK_NONE'}
            [pscustomobject]@{category='HARM_CATEGORY_HATE_SPEECH';threshold='BLOCK_NONE'}
            [pscustomobject]@{category='HARM_CATEGORY_SEXUALLY_EXPLICIT';threshold='BLOCK_NONE'}
            [pscustomobject]@{category='HARM_CATEGORY_DANGEROUS_CONTENT';threshold='BLOCK_NONE'}
            [pscustomobject]@{category='HARM_CATEGORY_CIVIC_INTEGRITY';threshold='BLOCK_NONE'}
            [pscustomobject]@{category='HARM_CATEGORY_JAILBREAK';threshold='BLOCK_NONE'}
        ); models=@([pscustomobject]@{name='gemini-flash-lite-latest'})}
        [pscustomobject]@{name='openrouter'; type='openai-compatible'; api_base='https://openrouter.ai/api/v1';                     api_key_env='OPENROUTER_API_KEY'; headers=[pscustomobject]@{'HTTP-Referer'='http://localhost';'X-Title'='Mira-TUI'}; models=@([pscustomobject]@{name='nvidia/nemotron-3-super-120b-a12b:free'})}
        [pscustomobject]@{name='groq';      type='openai-compatible'; api_base='https://api.groq.com/openai/v1';                    api_key_env='GROQ_API_KEY';      models=@([pscustomobject]@{name='openai/gpt-oss-120b'})}
        [pscustomobject]@{name='openai';    type='openai-compatible'; api_base='https://api.openai.com/v1';                         api_key_env='OPENAI_API_KEY';       models=@()}
        [pscustomobject]@{name='deepseek';  type='openai-compatible'; api_base='https://api.deepseek.com';                         api_key_env='DEEPSEEK_API_KEY'; models=@([pscustomobject]@{name='deepseek-flash'})}
        [pscustomobject]@{name='mistral';   type='openai-compatible'; api_base='https://api.mistral.ai/v1';                         api_key_env='MISTRAL_API_KEY';  models=@([pscustomobject]@{name='mistral-large-latest'})}
        [pscustomobject]@{name='together';  type='openai-compatible'; api_base='https://api.together.xyz/v1';                      api_key_env='TOGETHER_API_KEY'; models=@()}
        [pscustomobject]@{name='fireworks'; type='openai-compatible'; api_base='https://api.fireworks.ai/inference/v1';           api_key_env='FIREWORKS_API_KEY'; models=@()}
        [pscustomobject]@{name='xai';       type='openai-compatible'; api_base='https://api.x.ai/v1';                              api_key_env='XAI_API_KEY';       models=@([pscustomobject]@{name='grok-4.7'})}
        [pscustomobject]@{name='perplexity';type='openai-compatible'; api_base='https://api.perplexity.ai';                         api_key_env='PERPLEXITY_API_KEY';models=@([pscustomobject]@{name='sonar'})}
    )
}

function Load-Providers(){
    # Provider registry is compiled into the slim script. No provider JSON file.
    $script:Providers=@(New-BuiltinProviders)
}

function Get-Provider([string]$name){
    if([string]::IsNullOrWhiteSpace($name)){return $null}
    foreach($p in $script:Providers){ if([string]$p.name -ieq $name){return $p} }
    return $null
}

function Test-ProviderUsable($provider){
    if($null -eq $provider){return $false}
    return -not [string]::IsNullOrWhiteSpace((Get-ProviderKey $provider))
}

function Get-ProviderKey($provider){
    $envNames=New-Object System.Collections.Generic.List[string]
    if($null -ne $provider.api_key_env -and -not [string]::IsNullOrWhiteSpace([string]$provider.api_key_env)){[void]$envNames.Add([string]$provider.api_key_env)}

    # Backward-compatible aliases used by earlier Mira-TUI builds.
    switch -Regex ([string]$provider.name){
        '^openrouter$' {foreach($n in @('OPENROUTER_API_KEY','OPENROUTER_API_KEY')){if(-not $envNames.Contains($n)){[void]$envNames.Add($n)}}}
        '^openai$'     {if(-not $envNames.Contains('OPENAI_API_KEY')){[void]$envNames.Add('OPENAI_API_KEY')}}
        '^gemini$'     {foreach($n in @('GEMINI_API_KEY','GEMINI_API_KEY')){if(-not $envNames.Contains($n)){[void]$envNames.Add($n)}}}
    }

    foreach($envName in $envNames){
        $value=[string](Get-Item -Path ('Env:'+ $envName) -ErrorAction SilentlyContinue).Value
        if(-not [string]::IsNullOrWhiteSpace($value)){return $value}
    }

    if($null -ne $provider.api_key -and -not [string]::IsNullOrWhiteSpace([string]$provider.api_key)){return [string]$provider.api_key}

    if([string]$provider.name -ieq 'openrouter' -and
       -not [string]::IsNullOrWhiteSpace($script:OpenRouterApiKey) -and
       $script:OpenRouterApiKey -ne 'PASTE_OPENROUTER_KEY_HERE'){
        return [string]$script:OpenRouterApiKey
    }

    return ''
}

function Read-UsedModels(){
    if(-not (Test-Path -LiteralPath $script:UsedModelsCacheFile)){return @()}
    try{return @(Get-Content -LiteralPath $script:UsedModelsCacheFile -Encoding UTF8 -ErrorAction Stop | ForEach-Object {[string]$_.Trim()} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Select-Object -Unique)}catch{return @()}
}

function Write-UsedModels([string[]]$models){
    try{
        if(-not (Test-Path -LiteralPath $script:ModelCacheRoot)){[void](New-Item -ItemType Directory -Path $script:ModelCacheRoot -Force -ErrorAction Stop)}
        $items=@($models|ForEach-Object{[string]$_.Trim()}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)
        [IO.File]::WriteAllLines($script:UsedModelsCacheFile,$items,(New-Object System.Text.UTF8Encoding($false)))
    }catch{}
}

function Add-UsedModel([string]$providerName,[string]$model){
    if([string]::IsNullOrWhiteSpace($providerName) -or [string]::IsNullOrWhiteSpace($model)){return}
    $full=$providerName+':'+$model
    $items=New-Object System.Collections.Generic.List[string]
    foreach($x in @(Read-UsedModels)){if(-not $items.Contains([string]$x)){[void]$items.Add([string]$x)}}
    if($items.Contains($full)){$items.Remove($full)}
    [void]$items.Insert(0,$full)
    while($items.Count -gt 100){$items.RemoveAt($items.Count-1)}
    Write-UsedModels $items.ToArray()
}

function Get-ProviderCacheFile([string]$providerName){
    $safe=([string]$providerName -replace '[^A-Za-z0-9._-]','_').ToLowerInvariant()
    return (Join-Path $script:ModelCacheRoot ($safe+'.list'))
}

function Read-ProviderModelCache($provider){
    $path=Get-ProviderCacheFile ([string]$provider.name)
    if(-not (Test-Path -LiteralPath $path)){return @()}
    try{
        $items=@(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop | ForEach-Object { [string]$_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return @($items | Select-Object -Unique)
    }catch{return @()}
}

function Get-CachedProviderModels($provider){
    $cached=@(Read-ProviderModelCache $provider)
    if($cached.Count -gt 0){return $cached}
    if($null -eq $provider.models){return @()}
    return @($provider.models | Where-Object { $null -eq $_.type -or [string]$_.type -eq 'chat' } | ForEach-Object { [string]$_.name })
}

function Write-ProviderModelCache($provider,[string[]]$models){
    $items=@($models | ForEach-Object { [string]$_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if($items.Count -eq 0){throw 'provider returned no chat models'}
    if(-not (Test-Path -LiteralPath $script:ModelCacheRoot)){
        [void](New-Item -ItemType Directory -Path $script:ModelCacheRoot -Force -ErrorAction Stop)
    }
    $path=Get-ProviderCacheFile ([string]$provider.name)
    [IO.File]::WriteAllLines($path,$items,(New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-ModelListHeaders($provider,[string]$apiKey){
    $headers=@{}
    if([string]$provider.type -eq 'openai-compatible' -and -not [string]::IsNullOrWhiteSpace($apiKey)){$headers['Authorization']='Bearer '+$apiKey}
    if([string]$provider.type -eq 'gemini' -and -not [string]::IsNullOrWhiteSpace($apiKey)){$headers['x-goog-api-key']=$apiKey}
    if($null -ne $provider.headers){foreach($prop in $provider.headers.PSObject.Properties){$headers[[string]$prop.Name]=[string]$prop.Value}}
    return $headers
}

function Get-ProviderRefreshKey($provider){
    $envNames=New-Object System.Collections.Generic.List[string]
    if($null -ne $provider.api_key_env -and -not [string]::IsNullOrWhiteSpace([string]$provider.api_key_env)){[void]$envNames.Add([string]$provider.api_key_env)}
    # Refresh must never use the hardcoded OpenRouter test key.
    switch -Regex ([string]$provider.name){
        '^openrouter$' {
            foreach($n in @('OPENROUTER_API_KEY','OPENROUTER_API_KEY')){if(-not $envNames.Contains($n)){[void]$envNames.Add($n)}}
        }
        '^openai$' {
            if(-not $envNames.Contains('OPENAI_API_KEY')){[void]$envNames.Add('OPENAI_API_KEY')}
        }
        '^gemini$' {
            foreach($n in @('GEMINI_API_KEY','GEMINI_API_KEY')){if(-not $envNames.Contains($n)){[void]$envNames.Add($n)}}
        }
    }
    foreach($envName in $envNames){
        $value=[string](Get-Item -Path ('Env:'+ $envName) -ErrorAction SilentlyContinue).Value
        if(-not [string]::IsNullOrWhiteSpace($value)){
            return [pscustomobject]@{Name=$envName;Value=$value}
        }
    }
    return $null
}

function Get-StringArrayProperty($object,[string]$path){
    if($null -eq $object -or [string]::IsNullOrWhiteSpace($path)){return @()}
    $value=$object
    foreach($part in ($path -split '\.')){
        if($null -eq $value){return @()}
        $prop=$value.PSObject.Properties[$part]
        if($null -eq $prop){return @()}
        $value=$prop.Value
    }
    if($null -eq $value){return @()}
    if($value -is [string]){return @([string]$value)}
    if($value -is [System.Array] -or $value -is [System.Collections.IEnumerable]){
        return @($value | ForEach-Object {[string]$_} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    }
    return @([string]$value)
}

function Get-BoolProperty($object,[string]$path){
    if($null -eq $object -or [string]::IsNullOrWhiteSpace($path)){return $null}
    $value=$object
    foreach($part in ($path -split '\.')){
        if($null -eq $value){return $null}
        $prop=$value.PSObject.Properties[$part]
        if($null -eq $prop){return $null}
        $value=$prop.Value
    }
    if($null -eq $value){return $null}
    try{return [bool]$value}catch{return $null}
}

function Test-TextChatModel($item){
    # Use provider metadata when it exists. Never guess from model names.
    $known=$false

    foreach($path in @('output_modalities','architecture.output_modalities','supportedOutputTypes')){
        $mods=@(Get-StringArrayProperty $item $path)
        if($mods.Count -gt 0){
            $known=$true
            if($mods -notcontains 'text'){return $false}
            break
        }
    }

    foreach($path in @('capabilities.completion_chat','capabilities.chat_completion','capabilities.chat')){
        $v=Get-BoolProperty $item $path
        if($null -ne $v){
            $known=$true
            if(-not $v){return $false}
            break
        }
    }

    $methods=@(Get-StringArrayProperty $item 'supportedGenerationMethods')
    if($methods.Count -gt 0){
        $known=$true
        if(($methods -contains 'generateContent') -or ($methods -contains 'generateMessage')){return $true}
        return $false
    }

    $typeProp=$item.PSObject.Properties['type']
    if($null -ne $typeProp -and -not [string]::IsNullOrWhiteSpace([string]$typeProp.Value)){
        $known=$true
        $t=([string]$typeProp.Value).ToLowerInvariant()
        if($t -in @('embedding','embeddings','image','audio','speech','transcription','reranker','moderation')){return $false}
        if($t -in @('chat','chat-completion','completion','language','text-generation')){return $true}
    }

    # Sparse OpenAI-compatible model objects (for example OpenAI/Groq) do not
    # expose capability metadata. Keep those models rather than inventing rules.
    return $true
}

function Refresh-ProviderModelList($provider){
    $name=[string]$provider.name
    $refreshKey=Get-ProviderRefreshKey $provider
    if($null -eq $refreshKey){return $null}
    $apiKey=[string]$refreshKey.Value
    $type=[string]$provider.type
    $models=New-Object System.Collections.Generic.List[string]
    $headers=Get-ModelListHeaders $provider $apiKey

    if($name -ieq 'openrouter'){
        # OpenRouter supports server-side output modality filtering.
        $url=([string]$provider.api_base).TrimEnd('/')+'/models?output_modalities=text'
        $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        foreach($item in @($response.data)){
            $id=[string]$item.id
            if([string]::IsNullOrWhiteSpace($id)){continue}
            # Keep output-text models, including vision-capable text chat models.
            if(Test-TextChatModel $item){[void]$models.Add($id)}
        }
    }
    elseif($name -ieq 'xai'){
        # xAI exposes a dedicated language-models endpoint; /models also contains        # non-language model families. Use the endpoint intended for chat/language models.
        $url=([string]$provider.api_base).TrimEnd('/')+'/language-models'
        $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        foreach($item in @($response.models)){
            $id=[string]$item.id
            if([string]::IsNullOrWhiteSpace($id)){continue}
            if(Test-TextChatModel $item){[void]$models.Add($id)}
        }
    }
    elseif($name -ieq 'mistral'){
        $url=([string]$provider.api_base).TrimEnd('/')+'/models'
        $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        foreach($item in @($response.data)){
            $id=[string]$item.id
            if([string]::IsNullOrWhiteSpace($id)){continue}
            $chat=$item.PSObject.Properties['capabilities']
            if($null -ne $chat -and $null -ne $chat.Value.PSObject.Properties['completion_chat']){
                if(-not [bool]$chat.Value.completion_chat){continue}
            }
            $archived=$item.PSObject.Properties['archived']
            if($null -ne $archived -and [bool]$archived.Value){continue}
            if(Test-TextChatModel $item){[void]$models.Add($id)}
        }
    }
    elseif($name -ieq 'deepseek'){
        $url=([string]$provider.api_base).TrimEnd('/')+'/models'
        $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        foreach($item in @($response.data)){
            $id=[string]$item.id
            if([string]::IsNullOrWhiteSpace($id)){continue}
            if(Test-TextChatModel $item){[void]$models.Add($id)}
        }
    }
    elseif($type -eq 'openai-compatible'){
        $url=([string]$provider.api_base).TrimEnd('/')+'/models'
        $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        foreach($item in @($response.data)){
            $id=[string]$item.id
            if([string]::IsNullOrWhiteSpace($id)){continue}
            # Apply the common capability filter only when the provider actually
            # supplies a recognizable capability tag. Otherwise keep the model.
            if(Test-TextChatModel $item){[void]$models.Add($id)}
        }
        if($models.Count -eq 0 -and $null -ne $response.models){
            foreach($item in @($response.models)){
                $id=if($null -ne $item.id){[string]$item.id}else{[string]$item.name}
                if([string]::IsNullOrWhiteSpace($id)){continue}
                if(Test-TextChatModel $item){[void]$models.Add($id)}
            }
        }
    }
    elseif($type -eq 'gemini'){
        $pageToken=''
        do{
            $url=([string]$provider.api_base).TrimEnd('/')+'/models?pageSize=1000'
            if(-not [string]::IsNullOrWhiteSpace($pageToken)){$url+='&pageToken='+[uri]::EscapeDataString($pageToken)}
            $response=Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
            foreach($item in @($response.models)){
                # Gemini's Models resource documents supportedGenerationMethods,
                # while managed agents are exposed separately by the Interactions API.
                $methods=@(Get-StringArrayProperty $item 'supportedGenerationMethods')
                if($methods.Count -gt 0 -and ($methods -notcontains 'generateContent')){continue}

                # Keep the normal GenerateContent model family. Managed agents are
                # not selected here because this TUI uses the GenerateContent API.
                $id=if(-not [string]::IsNullOrWhiteSpace([string]$item.baseModelId)){[string]$item.baseModelId}else{([string]$item.name -replace '^models/','')}
                if([string]::IsNullOrWhiteSpace($id)){continue}

                # These are separate Interactions API agent/model families, not
                # ordinary GenerateContent chat targets for this TUI.
                if($id -in @(
                    'deep-research-preview-04-2026',
                    'deep-research-max-preview-04-2026',
                    'deep-research-pro-preview-12-2025',
                    'antigravity-preview-05-2026',
                    'antigravity-preview-09-2026'
                )){continue}

                # Gemini's current Models resource does not expose output modality
                # metadata, so we intentionally do not use name-pattern filtering here.
                [void]$models.Add($id)
            }
            $pageToken=[string]$response.nextPageToken
        }while(-not [string]::IsNullOrWhiteSpace($pageToken))
    }
    else{throw ('unsupported provider type for model refresh: '+$type)}

    $path=Write-ProviderModelCache $provider $models.ToArray()
    return [pscustomobject]@{Provider=$name;Count=$models.Count;Path=$path;KeyName=$refreshKey.Name}
}

function Refresh-ModelCaches([string]$onlyProvider=''){
    $targets=@()
    if([string]::IsNullOrWhiteSpace($onlyProvider)){$targets=@($script:Providers)}
    else{
        $p=Get-Provider $onlyProvider
        if($null -eq $p){W ('[models] unknown provider: '+$onlyProvider) Red;return}
        $targets=@($p)
    }
    foreach($provider in $targets){
        $refreshKey=Get-ProviderRefreshKey $provider
        if($null -eq $refreshKey){
            $envName=[string]$provider.api_key_env
            if([string]::IsNullOrWhiteSpace($envName)){$envName='API key env'}
            W ('[models] '+[string]$provider.name+': skipped ('+$envName+' is empty)') DarkGray
            continue
        }
        try{
            W ('[models] refreshing '+[string]$provider.name+' ...') DarkGray
            $r=Refresh-ProviderModelList $provider
            if($null -eq $r){continue}
            W ('[models] '+$r.Provider+': '+$r.Count+' models → '+$r.Path) Green
        }catch{W ('[models] '+[string]$provider.name+' refresh error: '+$_.Exception.Message) Red}
    }
}


function Test-ModelProbeName($model){
    # Cheap pre-filter only. This is NOT the final usability test.
    # It removes model families that are obviously not Mira's normal text-chat target.
    $pattern='(\*\*[^*\r\n]+\*\*|~~[^~\r\n]+~~|`[^`\r\n]+`|\[[^\]]+\]\([^\)]+\)|<\/?[A-Za-z_][A-Za-z0-9_.:-]*(?:\s+[^<>]*?)?\/?>|(?<!\*)\*[^*\r\n]+\*(?!\*)|(?<![A-Za-z0-9_])_[^_\r\n]+_(?![A-Za-z0-9_])|(?<!\$)\$[^$\r\n]+\$(?!\$))'
    return -not ([string]$model -match $pattern)
}

function Merge-UsedModels([string[]]$newModels){
    $items=New-Object System.Collections.Generic.List[string]
    foreach($x in @($newModels)){
        $s=[string]$x
        if([string]::IsNullOrWhiteSpace($s)){continue}
        if(-not $items.Contains($s.Trim())){[void]$items.Add($s.Trim())}
    }
    foreach($x in @(Read-UsedModels)){
        $s=[string]$x
        if(-not [string]::IsNullOrWhiteSpace($s) -and -not $items.Contains($s.Trim())){[void]$items.Add($s.Trim())}
    }
    while($items.Count -gt 100){$items.RemoveAt($items.Count-1)}
    Write-UsedModels $items.ToArray()
}

function Test-CachedModels(){
    # Expensive verifier: local pre-filter first, then a tiny standalone probe.
    # One active probe per provider; different providers may run concurrently.
    # No Mira persona, session history, or other context is sent.
    $queues=@{}
    $skippedName=0
    $alreadyUsed=@(Read-UsedModels)
    $usedSet=@{}
    foreach($u in $alreadyUsed){$usedSet[[string]$u]=$true}

    foreach($provider in $script:Providers){
        if(-not (Test-ProviderUsable $provider)){continue}
        $queue=New-Object 'System.Collections.Generic.Queue[object]'
        foreach($model in @(Get-CachedProviderModels $provider)){
            $full=[string]$provider.name+':'+[string]$model
            if($usedSet.ContainsKey($full)){continue}
            if(-not (Test-ModelProbeName $model)){$skippedName++;continue}
            $queue.Enqueue([pscustomobject]@{Provider=[string]$provider.name;Type=[string]$provider.type;Base=[string]$provider.api_base;Model=[string]$model;Full=$full})
        }
        if($queue.Count -gt 0){$queues[[string]$provider.name]=$queue}
    }

    $candidateCount=0
    foreach($q in $queues.Values){$candidateCount += $q.Count}
    if($candidateCount -eq 0){
        W '[models test] nothing to probe (already used or pre-filtered)' DarkGray
        return
    }

    # One active request per provider. Different providers can be tested at once.
    $providerConcurrency=$queues.Count
    if($env:MIRA_MODEL_TEST_PROVIDER_CONCURRENCY){
        try{$providerConcurrency=[Math]::Max(1,[Math]::Min($queues.Count,[int]$env:MIRA_MODEL_TEST_PROVIDER_CONCURRENCY))}catch{}
    }
    $timeout=20
    if($env:MIRA_MODEL_TEST_TIMEOUT){try{$timeout=[Math]::Max(5,[Math]::Min(120,[int]$env:MIRA_MODEL_TEST_TIMEOUT))}catch{}}
    $max429Retries=3
    if($env:MIRA_MODEL_TEST_429_RETRIES){try{$max429Retries=[Math]::Max(0,[Math]::Min(3,[int]$env:MIRA_MODEL_TEST_429_RETRIES))}catch{}}

    W ('[models test] candidates='+$candidateCount+'  pre-filtered='+$skippedName+'  provider-concurrency='+$providerConcurrency+'  timeout='+$timeout+'s  429-retries='+$max429Retries) Cyan
    W '[models test] tiny standalone probe: "Reply with exactly OK."' DarkGray
    W '[models test] Ctrl+C = stop scan; completed PASS results are kept' DarkGray

    $probeScript={
        param($providerName,$type,$base,$model,$apiKey,$extraHeaders,$timeoutSec,$max429Retries)
        try{
            $headers=@{}
            if($null -ne $extraHeaders){
                foreach($p in $extraHeaders.GetEnumerator()){$headers[[string]$p.Key]=[string]$p.Value}
            }

            if($type -eq 'gemini'){
                $url=$base.TrimEnd('/')+'/models/'+$model+':generateContent?key='+[uri]::EscapeDataString([string]$apiKey)
                $payload=[ordered]@{
                    contents=@([ordered]@{role='user';parts=@([ordered]@{text='Reply with exactly OK.'})})
                    generationConfig=[ordered]@{temperature=0;maxOutputTokens=8}
                }
            }elseif($type -eq 'openai-compatible'){
                $url=$base.TrimEnd('/')+'/chat/completions'
                $headers['Authorization']='Bearer '+[string]$apiKey
                $payload=[ordered]@{
                    model=$model
                    messages=@([ordered]@{role='user';content='Reply with exactly OK.'})
                    stream=$false
                }
                # Modern OpenAI reasoning models prefer max_completion_tokens;
                # OpenAI-compatible providers generally accept max_tokens.
                if($providerName -ieq 'openai'){$payload.max_completion_tokens=8}else{$payload.max_tokens=8}
            }else{throw ('unsupported provider type: '+$type)}

            $json=$payload|ConvertTo-Json -Depth 20
            $bytes=[Text.Encoding]::UTF8.GetBytes($json)
            $attempt=0
            while($true){
                try{
                    $params=@{Uri=$url;Method='Post';ContentType='application/json';Body=$bytes;TimeoutSec=[int]$timeoutSec;ErrorAction='Stop'}
                    if($headers.Count -gt 0){$params.Headers=$headers}
                    $response=Invoke-RestMethod @params
                    $text=''
                    if($type -eq 'gemini'){
                        $candidates=@($response.candidates)
                        if($candidates.Count -gt 0 -and $null -ne $candidates[0].content -and $null -ne $candidates[0].content.parts){
                            $text=(@($candidates[0].content.parts|ForEach-Object{if($null -ne $_.text){[string]$_.text}})|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}) -join ''
                        }
                        if([string]::IsNullOrWhiteSpace($text)){throw 'empty/non-text Gemini response'}
                    }else{
                        $choices=@($response.choices)
                        if($choices.Count -gt 0 -and $null -ne $choices[0].message){
                            $content=$choices[0].message.content
                            if($content -is [string]){$text=[string]$content}
                            elseif($null -ne $content){$text=(@($content|ForEach-Object{if($null -ne $_.text){[string]$_.text}})|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}) -join ''}
                        }
                        if([string]::IsNullOrWhiteSpace($text)){throw 'empty/non-text OpenAI-compatible response'}
                    }
                    return [pscustomobject]@{Success=$true;Provider=$providerName;Model=$model;Full=$providerName+':'+$model;Error='';RateLimited=$false;Attempts=($attempt+1)}
                }catch{
                    $status=0
                    $retryAfter=0
                    try{
                        if($null -ne $_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode}
                        if($status -eq 429 -and $null -ne $_.Exception.Response.Headers['Retry-After']){
                            [void][int]::TryParse([string]$_.Exception.Response.Headers['Retry-After'],[ref]$retryAfter)
                        }
                    }catch{}
                    if($status -ne 429 -or $attempt -ge $max429Retries){
                        $label=if($status -eq 429){'rate limited (429) after retries'}else{$_.Exception.Message}
                        return [pscustomobject]@{Success=$false;Provider=$providerName;Model=$model;Full=$providerName+':'+$model;Error=$label;RateLimited=($status -eq 429);Attempts=($attempt+1)}
                    }
                    $attempt++
                    $delay=if($retryAfter -gt 0){[Math]::Min(30,$retryAfter)}else{[Math]::Min(8,[Math]::Pow(2,$attempt))}
                    Start-Sleep -Seconds ([int]$delay)
                }
            }
        }catch{
            return [pscustomobject]@{Success=$false;Provider=$providerName;Model=$model;Full=$providerName+':'+$model;Error=$_.Exception.Message;RateLimited=$false;Attempts=1}
        }
    }

    $active=New-Object System.Collections.Generic.List[object]
    $activeProviders=@{}
    $pool=[RunspaceFactory]::CreateRunspacePool(1,[Math]::Max(1,$providerConcurrency))
    $pool.Open()
    $passed=New-Object System.Collections.Generic.List[string]
    $failed=0
    $done=0
    $cancelled=$false
    $oldTreatControlCAsInput=$null

    try{
        # Make Ctrl+C a key event so the parent thread can cancel child runspaces.
        $oldTreatControlCAsInput=[Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput=$true

        while(($queues.Values | Where-Object {$_.Count -gt 0}).Count -gt 0 -or $active.Count -gt 0){
            foreach($providerName in @($queues.Keys)){
                if($active.Count -ge $providerConcurrency){break}
                if($activeProviders.ContainsKey($providerName)){continue}
                $queue=$queues[$providerName]
                if($queue.Count -eq 0){continue}

                $c=$queue.Dequeue()
                $provider=Get-Provider $c.Provider
                $extraHeaders=@{}
                if($null -ne $provider.headers){
                    foreach($prop in $provider.headers.PSObject.Properties){$extraHeaders[[string]$prop.Name]=[string]$prop.Value}
                }
                $apiKey=Get-ProviderKey $provider
                $ps=[PowerShell]::Create()
                $ps.RunspacePool=$pool
                [void]$ps.AddScript($probeScript.ToString()).AddArgument($c.Provider).AddArgument($c.Type).AddArgument($c.Base).AddArgument($c.Model).AddArgument($apiKey).AddArgument($extraHeaders).AddArgument($timeout).AddArgument($max429Retries)
                $async=$ps.BeginInvoke()
                [void]$active.Add([pscustomobject]@{PS=$ps;Async=$async;Candidate=$c})
                $activeProviders[$providerName]=$true
            }

            # Ctrl+C cancels pending + active probes immediately. PASS results already
            # collected will still be merged into used.list below.
            if([Console]::KeyAvailable){
                while([Console]::KeyAvailable){
                    $key=[Console]::ReadKey($true)
                    if($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)){
                        $cancelled=$true
                        break
                    }
                }
            }
            if($cancelled){
                W '[models test] stopping...' Yellow
                foreach($job in @($active)){
                    try{$job.PS.Stop()}catch{}
                    try{$job.PS.EndInvoke($job.Async)|Out-Null}catch{}
                    try{$job.PS.Dispose()}catch{}
                }
                $active.Clear()
                $activeProviders.Clear()
                break
            }

            for($i=$active.Count-1;$i -ge 0;$i--){
                $job=$active[$i]
                if(-not $job.Async.IsCompleted){continue}
                [void]$active.RemoveAt($i)
                $providerName=[string]$job.Candidate.Provider
                $activeProviders.Remove($providerName)
                try{
                    $result=@($job.PS.EndInvoke($job.Async))
                    if($result.Count -gt 0 -and [bool]$result[0].Success){
                        [void]$passed.Add([string]$result[0].Full)
                        W ('[PASS] '+[string]$result[0].Full) Green
                    }else{
                        $err=if($result.Count -gt 0){[string]$result[0].Error}else{'probe returned no result'}
                        ++$failed
                        W ('[fail] '+[string]$job.Candidate.Full+' — '+$err) DarkGray
                    }
                }catch{
                    ++$failed
                    W ('[fail] '+[string]$job.Candidate.Full+' — '+$_.Exception.Message) DarkGray
                }finally{$job.PS.Dispose()}
                ++$done
                W ('[models test] progress '+$done+'/'+$candidateCount) DarkGray
            }
            if($active.Count -gt 0){Start-Sleep -Milliseconds 50}
        }
    }finally{
        foreach($job in @($active)){
            try{$job.PS.Stop()}catch{}
            try{$job.PS.EndInvoke($job.Async)|Out-Null}catch{}
            try{$job.PS.Dispose()}catch{}
        }
        try{$pool.Close()}catch{}
        try{$pool.Dispose()}catch{}
        if($null -ne $oldTreatControlCAsInput){
            try{[Console]::TreatControlCAsInput=$oldTreatControlCAsInput}catch{}
        }
    }

    if($passed.Count -gt 0){Merge-UsedModels $passed.ToArray()}
    $usedCount=@(Read-UsedModels).Count
    if($cancelled){
        W ('[models test] cancelled: '+$passed.Count+' passed, '+$failed+' failed, '+$skippedName+' pre-filtered; used.list='+$usedCount) Cyan
    }else{
        W ('[models test] done: '+$passed.Count+' passed, '+$failed+' failed, '+$skippedName+' pre-filtered; used.list='+$usedCount) Cyan
    }
}

function Get-DefaultProviderModel($provider){
    $models=@(Get-CachedProviderModels $provider)
    if($models.Count -gt 0){return [string]$models[0]}
    return ''
}

function Set-ModelSelection([string]$spec){
    $s=$spec.Trim()
    $s=$s -replace '^>\s*',''
    $s=$s -replace '^\.\.\.\s*',''
    if($s -match '^\.model\s+'){ $s=$s.Substring(7).Trim() }
    $splice=$s.LastIndexOf('> .model ')
    if($splice -ge 0){$s=$s.Substring($splice+9).Trim()}
    if([string]::IsNullOrWhiteSpace($s)){return $true}
    $providerName=$script:CurrentProviderName
    $model=$s
    $colon=$s.IndexOf(':')
    if($colon -gt 0){$providerName=$s.Substring(0,$colon);$model=$s.Substring($colon+1)}
    elseif($null -ne (Get-Provider $s)){$providerName=$s;$model=''}
    $provider=Get-Provider $providerName
    if($null -eq $provider){W ('[model error] unknown provider: '+$providerName) Red;return $false}
    if([string]::IsNullOrWhiteSpace($model)){
        $model=Get-DefaultProviderModel $provider
        if([string]::IsNullOrWhiteSpace($model)){W ('[model error] provider has no model list: '+$providerName) Red;return $false}
    }
    $old=$script:CurrentProviderName+':'+$script:CurrentModel
    $script:CurrentProviderName=[string]$provider.name
    $script:CurrentModel=$model
    # used.list is learned only after a real successful text response.
    W 'Model changed:' DarkGray;W ('  '+$old) DarkGray;W ('→ '+$script:CurrentProviderName+':'+$script:CurrentModel) DarkGray
    return $true
}

function Show-Model(){W ('[model] '+$script:CurrentProviderName+':'+$script:CurrentModel) Cyan}

function Show-Models(){
    W '' DarkCyan;W 'CACHED TEXT CHAT MODELS' Cyan
    foreach($provider in $script:Providers){
        foreach($model in @(Get-CachedProviderModels $provider)){
            $mark=if(([string]$provider.name -ieq $script:CurrentProviderName) -and ([string]$model -eq $script:CurrentModel)){'* '}else{'  '}
            W ($mark+[string]$provider.name+':'+[string]$model) Gray
        }
    }
    W ('cache: '+$script:ModelCacheRoot) DarkGray;W '' DarkCyan
}

function Show-Providers(){
    W '' DarkCyan;W 'PROVIDERS' Cyan
    foreach($provider in $script:Providers){W ('  '+[string]$provider.name+'  ('+[string]$provider.type+')  '+[string]$provider.api_base) Gray}
    W '  registry: built into mira-tui-slim.ps1' DarkGray;W ('  model cache: '+$script:ModelCacheRoot) DarkGray;W ('  used models: '+$script:UsedModelsCacheFile) DarkGray;W '' DarkCyan
}

function ModelCandidates([string]$typed){
    # .model completion is intentionally ONLY self-learning data.
    # Never read provider catalogs, model caches, or perform network I/O here.
    $q=if($null -eq $typed){''}else{$typed.Trim()}
    $out=New-Object System.Collections.Generic.List[psobject]

    foreach($full in @(Read-UsedModels)){
        $name=[string]$full
        if([string]::IsNullOrWhiteSpace($name)){continue}
        if([string]::IsNullOrEmpty($q) -or $name.StartsWith($q,[StringComparison]::OrdinalIgnoreCase)){
            [void]$out.Add([pscustomobject]@{
                Name=$name
                PSIsContainer=$false
                Kind='used'
            })
        }
    }

    return @($out | Select-Object -First 32)
}

function Clear-ModelMenu(){
    if(-not $script:ModelMenuActive){return}
    Clear-Menu
    $script:ModelMenuActive=$false
    $script:ModelMenuItems=@()
    $script:ModelMenuIndex=0
    $script:ModelMenuTyped=''
}

function Show-ModelMenu($row,$buffer,$cursor){
    Clear-Menu
    $items=@($script:ModelMenuItems)
    if($items.Count -eq 0){Clear-ModelMenu;return}
    $w=Width
    $visible=[Math]::Min(10,$items.Count)
    $start=[Math]::Max(0,[Math]::Min($script:ModelMenuIndex-4,$items.Count-$visible))
    $script:MenuTop=$row+1
    $script:MenuRows=$visible
    $script:MenuVisible=$true
    for($r=0;$r -lt $visible;$r++){
        $idx=$start+$r
        $mark=if($idx -eq $script:ModelMenuIndex){'> '}else{'  '}
        $line=$mark+[string]$items[$idx]
        if(Cursor 0 ($script:MenuTop+$r)){
            [Console]::Write((' ' * ($w-1)))
            [void](Cursor 0 ($script:MenuTop+$r))
            Write-Host $line -NoNewline -ForegroundColor $(if($idx -eq $script:ModelMenuIndex){'Cyan'}else{'DarkGray'})
        }
    }
    if($items.Count -gt $visible){
        $footer=('  ['+($script:ModelMenuIndex+1)+'/'+$items.Count+']  ↑/↓ move  Tab next  Enter accept  Esc cancel')
        if(Cursor 0 ($script:MenuTop+$visible)){
            [Console]::Write((' ' * ($w-1)))
            [void](Cursor 0 ($script:MenuTop+$visible))
            Write-Host $footer -NoNewline -ForegroundColor DarkGray
        }
        ++$script:MenuRows
    }
    Redraw $buffer $cursor $row
}

function Open-ModelMenu($buffer,$row){
    $typed=$buffer.Substring(7)
    $items=@(ModelCandidates $typed | ForEach-Object {[string]$_.Name})
    if($items.Count -eq 0){try{[Console]::Beep(700,50)}catch{};return $buffer}
    $script:ModelMenuItems=$items
    $script:ModelMenuIndex=0
    $script:ModelMenuTyped=$typed
    $script:ModelMenuActive=$true

    # Opening the menu must NOT replace the user's query with the first item.
    # Keep the original buffer until Tab/Up/Down changes the selection or
    # Enter explicitly accepts it.
    Show-ModelMenu $row $buffer $buffer.Length
    return $buffer
}

function Move-ModelMenu([int]$direction,$row,[ref]$buffer,[ref]$cursor){
    if(-not $script:ModelMenuActive -or $script:ModelMenuItems.Count -eq 0){return}
    $count=$script:ModelMenuItems.Count
    $script:ModelMenuIndex=($script:ModelMenuIndex+$direction)%$count
    if($script:ModelMenuIndex -lt 0){$script:ModelMenuIndex=$count-1}
    $buffer.Value='.model '+[string]$script:ModelMenuItems[$script:ModelMenuIndex]
    $cursor.Value=$buffer.Value.Length
    Show-ModelMenu $row $buffer.Value $cursor.Value
}

function Complete-Model($buffer,$row){
    if($script:ModelMenuActive){return $buffer}
    if($buffer.Length -lt 7){return $null}
    $typed=$buffer.Substring(7)
    $items=@(ModelCandidates $typed)
    if($items.Count -eq 0){try{[Console]::Beep(700,50)}catch{};return $null}
    $names=@($items|ForEach-Object{[string]$_.Name})
    if($items.Count -eq 1){return '.model '+$names[0]}
    $comp=CommonPrefix $names
    if($comp.Length -gt $typed.Length){return '.model '+$comp}
    return (Open-ModelMenu $buffer $row)
}

function Build-GeminiPayload($messages,$summary){
    $contents=@()
    foreach($m in $messages){
        $role=if([string]$m.role -eq 'assistant'){'model'}else{'user'}
        $parts=@()
        if($null -ne $m.parts){
            foreach($p in @($m.parts)){
                if([string]$p.kind -eq 'image'){
                    $parts += [ordered]@{inlineData=[ordered]@{mimeType=[string]$p.mimeType;data=[string]$p.data}}
                }else{
                    $parts += [ordered]@{text=[string]$p.text}
                }
            }
        }else{
            $parts += [ordered]@{text=[string]$m.text}
        }
        $contents += [ordered]@{role=$role;parts=$parts}
    }
    $payload=[ordered]@{contents=$contents}
    if($null -ne $script:Providers){
        $provider=Get-Provider 'gemini'
        if($null -ne $provider -and $null -ne $provider.safetySettings){$payload.safetySettings=@($provider.safetySettings)}
    }
    if(-not [string]::IsNullOrWhiteSpace($summary)){
        $payload.systemInstruction=[ordered]@{parts=@([ordered]@{text=$summary})}
    }
    return $payload
}

function Build-OpenAICompatiblePayload($provider,$messages,$model,$summary){
    $msg=@()
    if(-not [string]::IsNullOrWhiteSpace($summary)){
        $msg += [ordered]@{role='system';content=$summary}
    }
    foreach($m in $messages){
        $entry=[ordered]@{role=[string]$m.role}
        if($null -ne $m.parts){
            $content=@()
            foreach($p in @($m.parts)){
                if([string]$p.kind -eq 'image'){
                    $content += [ordered]@{type='image_url';image_url=[ordered]@{url=('data:'+([string]$p.mimeType)+';base64,'+([string]$p.data))}}
                }else{
                    $content += [ordered]@{type='text';text=[string]$p.text}
                }
            }
            $entry.content=$content
        }else{
            $entry.content=[string]$m.text
        }
        if([string]$m.role -eq 'assistant' -and $null -ne $m.reasoning_details){
            $rd=@($m.reasoning_details)
            if($rd.Count -gt 0){$entry.reasoning_details=$rd}
        }
        $msg += $entry
    }
    $payload=[ordered]@{model=$model;messages=$msg;stream=$script:StreamResponses}
    if($script:ShowReasoning){$payload.reasoning=[ordered]@{enabled=$true}}
    return $payload
}

function Send-OpenAICompatibleStream($provider,$model,$payload){
    $apiKey=Get-ProviderKey $provider
    if([string]::IsNullOrWhiteSpace($apiKey)){throw 'OpenAI-compatible provider API key is missing.'}

    $url=([string]$provider.api_base).TrimEnd('/')+'/chat/completions'
    $payload.stream=$true
    $json=$payload | ConvertTo-Json -Depth 40
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)

    $request=[Net.HttpWebRequest]::Create($url)
    $request.Method='POST'
    $request.ContentType='application/json'
    $request.Accept='text/event-stream'
    $request.ContentLength=$bytes.Length
    $request.Timeout=120000
    $request.ReadWriteTimeout=600000
    $request.KeepAlive=$false
    try{$request.ServicePoint.Expect100Continue=$false}catch{}
    $request.Headers['Authorization']='Bearer '+$apiKey
    $request.UserAgent='Mira-TUI/1.0.5'
    if($null -ne $provider.headers){foreach($prop in $provider.headers.PSObject.Properties){$request.Headers[[string]$prop.Name]=[string]$prop.Value}}

    $reqStream=$null;$resp=$null;$reader=$null
    try{
        $reqStream=$request.GetRequestStream();$reqStream.Write($bytes,0,$bytes.Length);$reqStream.Close();$reqStream=$null
        try{$resp=$request.GetResponse()}catch [Net.WebException]{
            $we=$_.Exception;$detail=$we.Message
            if($null -ne $we.Response){$errReader=New-Object IO.StreamReader($we.Response.GetResponseStream());try{$errBody=$errReader.ReadToEnd()}finally{$errReader.Dispose()};if($errBody){$detail+="`n"+$errBody}}
            throw $detail
        }
        $reader=New-Object IO.StreamReader($resp.GetResponseStream(),[Text.Encoding]::UTF8)
        $contentType=[string]$resp.ContentType
        if($contentType -and $contentType -notlike 'text/event-stream*'){
            $body=$reader.ReadToEnd()
            if([string]::IsNullOrWhiteSpace($body)){throw 'Streaming provider returned an empty response.'}
            $full=$body|ConvertFrom-Json -ErrorAction Stop
            $r=Show-Response $full 'openai-compatible'
            return [pscustomobject]@{Text=[string]$r.Text;Reasoning=[string]$r.Reasoning;ReasoningDetails=@($r.ReasoningDetails);Display=[string]$r.Display;FinishReason=[string]$r.FinishReason;PromptTokens=0;CompletionTokens=0;ReasoningTokens=0}
        }

        $answer=New-Object Text.StringBuilder
        $reasoning=New-Object Text.StringBuilder
        $reasoningDetails=New-Object System.Collections.Generic.List[object]
        $finish='';$tokensIn=0;$tokensOut=0;$reasoningTokens=0;$showThought=$false

        while(($line=$reader.ReadLine()) -ne $null){
            if(-not $line.StartsWith('data:')){continue}
            $data=$line.Substring(5).Trim()
            if($data -eq '[DONE]'){break}
            if([string]::IsNullOrWhiteSpace($data)){continue}
            try{$chunk=$data|ConvertFrom-Json -ErrorAction Stop}catch{continue}
            if($null -eq $chunk){continue}

            if($null -ne $chunk.usage){
                if($null -ne $chunk.usage.prompt_tokens){$tokensIn=[int]$chunk.usage.prompt_tokens}
                if($null -ne $chunk.usage.completion_tokens){$tokensOut=[int]$chunk.usage.completion_tokens}
                if($null -ne $chunk.usage.completion_tokens_details -and $null -ne $chunk.usage.completion_tokens_details.reasoning_tokens){$reasoningTokens=[int]$chunk.usage.completion_tokens_details.reasoning_tokens}
            }

            $choices=@($chunk.choices);if($choices.Count -eq 0){continue}
            $choice=$choices[0];$delta=$choice.delta;$finish=[string]$choice.finish_reason
            if($null -eq $delta){continue}

            if($null -ne $delta.reasoning -and -not [string]::IsNullOrEmpty([string]$delta.reasoning)){
                $r=[string]$delta.reasoning;[void]$reasoning.Append($r)
                if($script:ShowReasoning){if(-not $showThought){W '[THOUGHT]' DarkGray;$showThought=$true};[Console]::Write($r)}
            }
            if($null -ne $delta.reasoning_details){foreach($detail in @($delta.reasoning_details)){[void]$reasoningDetails.Add($detail)}}

            if($null -ne $delta.content){
                if($delta.content -is [string]){$pieces=@([string]$delta.content)}else{$pieces=@($delta.content|ForEach-Object{if($null -ne $_.text){[string]$_.text}})}
                foreach($c in $pieces){if([string]::IsNullOrEmpty($c)){continue};if($showThought -and $answer.Length -eq 0){[Console]::Write("`r`n[ANSWER] ")};[void]$answer.Append($c);[Console]::Write($c)}
            }
        }

        [Console]::Write("`r`n")
        $tokenString="[Tokens: $tokensIn in, $tokensOut out]";if($reasoningTokens -gt 0){$tokenString+=" [Reasoning: $reasoningTokens]"};W $tokenString DarkCyan
        if([string]::IsNullOrWhiteSpace($finish)){$finish='stop'}
        return [pscustomobject]@{Text=[string]$answer.ToString();Reasoning=[string]$reasoning.ToString();ReasoningDetails=@($reasoningDetails);Display=$tokenString;FinishReason=$finish;PromptTokens=$tokensIn;CompletionTokens=$tokensOut;ReasoningTokens=$reasoningTokens}
    }
    finally{if($null -ne $reader){$reader.Dispose()};if($null -ne $resp){$resp.Dispose()};if($null -ne $reqStream){$reqStream.Dispose()}}
}

function Send-ProviderPayload($provider,$model,$payload){
    $apiKey=Get-ProviderKey $provider
    $type=[string]$provider.type
    if($type -eq 'gemini'){
        $base=[string]$provider.api_base
        $url=$base.TrimEnd('/')+'/models/'+$model+':generateContent'
        if(-not [string]::IsNullOrWhiteSpace($apiKey)){$url += '?key='+[uri]::EscapeDataString($apiKey)}
        $headers=@{}
    }
    elseif($type -eq 'openai-compatible'){
        $url=([string]$provider.api_base).TrimEnd('/')+'/chat/completions'
        $headers=@{}
        if(-not [string]::IsNullOrWhiteSpace($apiKey)){$headers['Authorization']='Bearer '+$apiKey}
        if($null -ne $provider.headers){
            foreach($prop in $provider.headers.PSObject.Properties){$headers[[string]$prop.Name]=[string]$prop.Value}
        }
    }
    else{ throw ('unsupported provider type: '+$type) }

    $json=$payload | ConvertTo-Json -Depth 30
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $params=@{Uri=$url;Method='Post';ContentType='application/json';Body=$bytes;TimeoutSec=120;ErrorAction='Stop'}
    if($headers.Count -gt 0){$params.Headers=$headers}

    # Keep the foreground thread responsive while the HTTP request is in flight.
    # The same native-console approach used by the earlier Mira build gives us a
    # lightweight waiting animation without PSReadLine or any external module.
    $oldTreatControlCAsInput=$null
    $runspace=$null
    $powershell=$null
    $asyncResult=$null
    $cancelled=$false
    try{
        try{
            $oldTreatControlCAsInput=[Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput=$true
        }catch{}

        $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $powershell=[Management.Automation.PowerShell]::Create()
        $powershell.Runspace=$runspace
        [void]$powershell.AddScript({
            param($p)
            Invoke-RestMethod @p
        }).AddArgument($params)

        $asyncResult=$powershell.BeginInvoke()
        $frames=@('.  ','.. ','...','   ')
        $i=0
        $sw=[Diagnostics.Stopwatch]::StartNew()

        while(-not $asyncResult.IsCompleted){
            try{
                if([Console]::KeyAvailable){
                    $key=[Console]::ReadKey($true)
                    if($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)){
                        $cancelled=$true
                        try{$powershell.Stop()}catch{}
                        break
                    }
                }
            }catch{}

            $frame=$frames[$i % $frames.Length]
            $elapsed=[int]$sw.ElapsedMilliseconds
            $bullet=if($script:SessionActive){'  ●'}else{''}
            $status="$frame  $([math]::Round($elapsed/1000,1))s      $bullet"
            Write-Host ("`r" + (" " * [Math]::Max(1,((Width)-1))) + "`r" + $status) -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 150
            ++$i
        }
        $sw.Stop()
        $script:LastRequestElapsedMs=[int]$sw.ElapsedMilliseconds
        $script:LastRequestFrame=$frames[[Math]::Max(0,$i-1) % $frames.Length]


        if($cancelled){
            try{$powershell.EndInvoke($asyncResult)|Out-Null}catch{}
            Write-Host ("`r" + (" " * 24) + "`r[Request cancelled]") -ForegroundColor Yellow
            throw 'Request cancelled.'
        }

        # Keep the final timer line alive until the response is available, then
        # finalize it with token counts on the same line.
        $elapsed=[int]$sw.ElapsedMilliseconds
        $frame=$frames[$i % $frames.Length]

        $response=@($powershell.EndInvoke($asyncResult))
        $runspaceErrors=@($powershell.Streams.Error)
        if($runspaceErrors.Count -gt 0){
            $err=$runspaceErrors[0]
            $webResp=$err.Exception.Response
            if($null -ne $webResp){
                $status=[int]$webResp.StatusCode
                $statusText=[string]$webResp.StatusDescription
                $body=''
                try{
                    $stream=$webResp.GetResponseStream()
                    if($stream){
                        $reader=New-Object System.IO.StreamReader($stream)
                        try{$body=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
                    }
                }catch{}
                if($body){throw "HTTP $status $statusText`n$body"}
                throw "HTTP $status $statusText"
            }
            throw [string]$err.Exception.Message
        }
        if($response.Count -eq 0 -or $null -eq $response[0]){throw 'The provider returned an empty response.'}

        $final=$response[0]
        $tokensIn=0
        $tokensOut=0
        try{
            if($type -eq 'gemini'){
                if($null -ne $final.usageMetadata){
                    if($null -ne $final.usageMetadata.promptTokenCount){$tokensIn=[int]$final.usageMetadata.promptTokenCount}
                    if($null -ne $final.usageMetadata.candidatesTokenCount){$tokensOut=[int]$final.usageMetadata.candidatesTokenCount}
                }
            }else{
                if($null -ne $final.usage){
                    if($null -ne $final.usage.prompt_tokens){$tokensIn=[int]$final.usage.prompt_tokens}
                    if($null -ne $final.usage.completion_tokens){$tokensOut=[int]$final.usage.completion_tokens}
                }
            }
        }catch{}

        $bullet=if($script:SessionActive){'  ●'}else{''}
        $status="$frame  $([math]::Round($elapsed/1000,1))s      ↑ $tokensIn  ↓ $tokensOut$bullet"
        $script:LastStatusRow=Row
        $script:LastStatusText=$status
        $script:LastStatusHasBullet=$script:SessionActive
        Write-Host ("`r" + (" " * [Math]::Max(1,(Width))) + "`r" + $status) -NoNewline -ForegroundColor DarkGray
        return $final
    }finally{
        if($null -ne $oldTreatControlCAsInput){try{[Console]::TreatControlCAsInput=$oldTreatControlCAsInput}catch{}}
        if($null -ne $powershell){try{$powershell.Dispose()}catch{}}
        if($null -ne $runspace){try{$runspace.Dispose()}catch{}}
    }
}

function Compress-Session(){
    if(-not $script:SessionActive){W '[no active session]' Yellow;return $false}
    if($script:Conversation.Count -lt 6){W '[session too short to compress]' DarkGray;return $false}

    $keep=4
    $old=@()
    for($i=0;$i -lt ($script:Conversation.Count-$keep);++$i){$old += $script:Conversation[$i]}
    $recent=@()
    for($i=[Math]::Max(0,$script:Conversation.Count-$keep);$i -lt $script:Conversation.Count;++$i){$recent += $script:Conversation[$i]}

    $provider=Get-Provider $script:CurrentProviderName
    if($null -eq $provider){return $false}
    $transcript=($old | ForEach-Object { [string]$_.role+': '+[string]$_.text }) -join "`n`n"
    $prompt='Summarize the earlier conversation faithfully and compactly. Preserve important facts, decisions, user preferences, technical state, unresolved tasks, and exact names, paths, and model identifiers that matter. Do not invent information. Keep it under 200 words. Return only the summary.'+"`n`nCONVERSATION:`n"+$transcript
    $summaryMessages=@([pscustomobject]@{role='user';text=$prompt})
    try{
        $type=[string]$provider.type
        if($type -eq 'gemini'){$payload=Build-GeminiPayload $summaryMessages ''}
        elseif($type -eq 'openai-compatible'){$payload=Build-OpenAICompatiblePayload $provider $summaryMessages $script:CurrentModel ''; $payload.stream=$false}
        else{throw ('unsupported provider type: '+$type)}
        $response=Send-ProviderPayload $provider $script:CurrentModel $payload
        $result=Show-Response $response $type
        if([string]::IsNullOrWhiteSpace($result.Text)){throw 'summary response was empty'}
        $script:SessionSummary=$result.Text.Trim()
        $script:Conversation=New-Object System.Collections.Generic.List[object]
        foreach($m in $recent){[void]$script:Conversation.Add($m)}
        $script:LastPromptTokens=0
        W ('[session compressed: summary + '+$keep+' recent messages]') DarkGray
        return $true
    }catch{
        W ('[compression error] '+$_.Exception.Message) Red
        return $false
    }
}

function Start-Session([string]$name){
    $script:SessionActive=$true
    $script:SessionName=if([string]::IsNullOrWhiteSpace($name)){'temp'}else{$name.Trim()}
    $script:SessionSummary=''
    $script:LastPromptTokens=0
    $script:Conversation=New-Object System.Collections.Generic.List[object]
    W ('[session started] '+$script:SessionName+' (memory only)') Cyan
}

function Remove-LastStatusBullet(){
    # The status is embedded into the rendered top border. Do not rewrite the
    # existing frame when the session ends; only affect future responses.
    $script:LastStatusHasBullet=$false
}

function Exit-Session(){
    if(-not $script:SessionActive){W '[no active session]' Yellow;return}
    Remove-LastStatusBullet
    $name=$script:SessionName
    $script:SessionActive=$false
    $script:SessionName=''
    $script:SessionSummary=''
    $script:LastPromptTokens=0
    $script:Conversation=New-Object System.Collections.Generic.List[object]
    W ('[session ended] '+$name+' (not saved)') DarkGray
}

function Empty-Session(){
    if(-not $script:SessionActive){W '[no active session]' Yellow;return}
    $script:SessionSummary=''
    $script:LastPromptTokens=0
    $script:Conversation=New-Object System.Collections.Generic.List[object]
    W '[session emptied]' DarkGray
}



$script:MarkupFrameActive = $false
$script:MarkupFrameWidth = 0
$script:MarkupFrameUsed = 0

function Begin-MarkupLine(){
    $script:MarkupFrameUsed=0
    if($script:MarkupFrameActive){
        $pad=[string]$script:MarkupTheme.MessageLeftPadding
        if($pad.Length -gt 0){
            Write-Host $pad -NoNewline -ForegroundColor Gray
            $script:MarkupFrameUsed=Get-MiraCellWidth $pad
        }
    }
}

function Resolve-UiRenderColor([ConsoleColor]$Color){
    return $Color
}

function Get-MiraCellWidth([string]$Text){
    if([string]::IsNullOrEmpty($Text)){return 0}
    $width=0
    for($i=0;$i -lt $Text.Length;){
        $cp=[char]::ConvertToUtf32($Text,$i)
        $i += if($cp -gt 0xFFFF){2}else{1}

        if($cp -eq 0 -or $cp -lt 32 -or ($cp -ge 0x7F -and $cp -lt 0xA0)){continue}
        if(($cp -ge 0x300 -and $cp -le 0x36F) -or
           ($cp -ge 0x1AB0 -and $cp -le 0x1AFF) -or
           ($cp -ge 0x1DC0 -and $cp -le 0x1DFF) -or
           ($cp -ge 0x20D0 -and $cp -le 0x20FF) -or
           ($cp -ge 0xFE00 -and $cp -le 0xFE0F) -or
           ($cp -ge 0xE0100 -and $cp -le 0xE01EF) -or
           $cp -eq 0x200D){continue}

        if(($cp -ge 0x1100 -and $cp -le 0x115F) -or
           ($cp -ge 0x2329 -and $cp -le 0x232A) -or
           ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
           ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or
           ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
           ($cp -ge 0xFE10 -and $cp -le 0xFE6F) -or
           ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or
           ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or
           ($cp -ge 0x1F300 -and $cp -le 0x1FAFF) -or
           ($cp -ge 0x20000 -and $cp -le 0x3FFFD)){ $width += 2 }
        else{ $width += 1 }
    }
    return $width
}

# -----------------------------------------------------------------------------
# TERMINAL CELL CANVAS / LAYOUT FOUNDATION
# New renderer work starts here. This subsystem owns terminal cells and layout;
# Markdown, math, code and readline remain separate layers.
# -----------------------------------------------------------------------------

function New-MiraCell([string]$Char=' ',[string]$Fg='', [string]$Bg='', [int]$Attr=0, [bool]$Continuation=$false){
    return [pscustomobject]@{
        Ch=[string]$Char
        Fg=[string]$Fg
        Bg=[string]$Bg
        Attr=[int]$Attr
        Continuation=[bool]$Continuation
    }
}

function New-MiraCanvas([int]$Width,[int]$Height){
    $w=[Math]::Max(1,[int]$Width)
    $h=[Math]::Max(1,[int]$Height)
    $cells=New-Object object[,] $h,$w
    for($y=0;$y -lt $h;++$y){
        for($x=0;$x -lt $w;++$x){
            $cells[$y,$x]=New-MiraCell
        }
    }
    return [pscustomobject]@{
        Width=$w
        Height=$h
        Cells=$cells
    }
}

function Clear-MiraCanvas($Canvas){
    if($null -eq $Canvas){return}
    for($y=0;$y -lt [int]$Canvas.Height;++$y){
        for($x=0;$x -lt [int]$Canvas.Width;++$x){
            $Canvas.Cells[$y,$x]=New-MiraCell
        }
    }
}

function Get-MiraCanvasCell($Canvas,[int]$X,[int]$Y){
    if($null -eq $Canvas){return $null}
    if($X -lt 0 -or $Y -lt 0 -or $X -ge [int]$Canvas.Width -or $Y -ge [int]$Canvas.Height){return $null}
    return $Canvas.Cells[$Y,$X]
}

function Set-MiraCanvasCell($Canvas,[int]$X,[int]$Y,[string]$Char=' ',[string]$Fg='',[string]$Bg='',[int]$Attr=0,[bool]$Continuation=$false){
    if($null -eq $Canvas){return}
    if($X -lt 0 -or $Y -lt 0 -or $X -ge [int]$Canvas.Width -or $Y -ge [int]$Canvas.Height){return}
    $Canvas.Cells[$Y,$X]=New-MiraCell $Char $Fg $Bg $Attr $Continuation
}

function Set-MiraCanvasText($Canvas,[int]$X,[int]$Y,[string]$Text,[string]$Fg='', [string]$Bg='', [int]$Attr=0, [int]$MaxWidth=0){
    if($null -eq $Canvas -or $null -eq $Text){return [int]$X}
    if($Y -lt 0 -or $Y -ge [int]$Canvas.Height){return [int]$X}
    $limit=if($MaxWidth -gt 0){[Math]::Min([int]$Canvas.Width,$X+$MaxWidth)}else{[int]$Canvas.Width}
    $cx=[int]$X
    $cy=[int]$Y
    for($i=0;$i -lt $Text.Length -and $cx -lt $limit;){
        $cp=[char]::ConvertToUtf32($Text,$i)
        $units=if($cp -gt 0xFFFF){2}else{1}
        $ch=[string]::Copy($Text,$i,$units)
        if($cp -eq 10){
            ++$cy;$cx=[int]$X;$i += $units
            if($cy -ge [int]$Canvas.Height){break}
            continue
        }
        if($cp -eq 13){$i += $units;continue}
        if($cp -eq 9){
            $spaces=4-($cx%4)
            for($sp=0;$sp -lt $spaces -and $cx -lt $limit;++$sp){
                Set-MiraCanvasCell $Canvas $cx $cy ' ' $Fg $Bg $Attr $false
                ++$cx
            }
            $i += $units
            continue
        }
        $cw=Get-MiraCellWidth $ch
        if($cw -le 0){$i += $units;continue}
        if($cx+$cw -gt $limit){break}        Set-MiraCanvasCell $Canvas $cx $cy $ch $Fg $Bg $Attr $false
        if($cw -gt 1){
            for($k=1;$k -lt $cw;++$k){
                Set-MiraCanvasCell $Canvas ($cx+$k) $cy ' ' $Fg $Bg $Attr $true
            }
        }
        $cx += $cw
        $i += $units
    }
    return [int]$cx
}
function Measure-MiraText([string]$Text){
    if($null -eq $Text){$Text=''}
    $max=0
    $current=0
    for($i=0;$i -lt $Text.Length;){
        $cp=[char]::ConvertToUtf32($Text,$i)
        $units=if($cp -gt 0xFFFF){2}else{1}
        if($cp -eq 10){
            if($current -gt $max){$max=$current}
            $current=0
            $i += $units
            continue
        }
        if($cp -eq 13){$i += $units;continue}
        if($cp -eq 9){$current += 4-($current%4);$i += $units;continue}
        $current += [Math]::Max(0,(Get-MiraCellWidth ([string]::Copy($Text,$i,$units))))
        $i += $units
    }
    if($current -gt $max){$max=$current}
    $lines=if($Text.Length -eq 0){1}else{($Text.Split([char]10).Count)}
    return [pscustomobject]@{Width=[int]$max;Height=[int]$lines}
}
function Wrap-MiraText([string]$Text,[int]$MaxWidth){
    if($null -eq $Text){return @('')}
    $w=[Math]::Max(1,[int]$MaxWidth)
    $out=New-Object System.Collections.Generic.List[string]
    foreach($source in $Text.Split([char]10)){
        if($source.Length -eq 0){[void]$out.Add('');continue}
        $remaining=[string]$source
        while($remaining.Length -gt 0){
            if((Measure-MiraText $remaining).Width -le $w){
                [void]$out.Add($remaining)
                break
            }
            $cut=$remaining.Length
            $used=0
            $lastSpace=-1
            for($i=0;$i -lt $remaining.Length;++$i){
                $cw=Get-MiraCellWidth ([string]$remaining[$i])
                if($used+$cw -gt $w){$cut=$i;break}
                $used += $cw
                if([char]::IsWhiteSpace($remaining[$i])){$lastSpace=$i}
            }
            if($cut -le 0){$cut=1}
            if($lastSpace -gt 0 -and $lastSpace -lt $cut){$cut=$lastSpace}
            $part=$remaining.Substring(0,$cut).TrimEnd()
            [void]$out.Add($part)
            $remaining=$remaining.Substring($cut).TrimStart()
        }
    }
    return @($out)
}

function Draw-MiraCanvasBox($Canvas,[int]$X,[int]$Y,[int]$BoxWidth,[int]$BoxHeight,[string]$Fg='', [string]$Bg='', [int]$Attr=0){
    if($null -eq $Canvas){return}
    $w=[int]$BoxWidth; $h=[int]$BoxHeight
    if($w -lt 2 -or $h -lt 2){return}
    $hline='─'
    $topLeft='┌';$topRight='┐';$bottomLeft='└';$bottomRight='┘'
    Set-MiraCanvasCell $Canvas $X $Y $topLeft $Fg $Bg $Attr
    Set-MiraCanvasCell $Canvas ($X+$w-1) $Y $topRight $Fg $Bg $Attr
    Set-MiraCanvasCell $Canvas $X ($Y+$h-1) $bottomLeft $Fg $Bg $Attr
    Set-MiraCanvasCell $Canvas ($X+$w-1) ($Y+$h-1) $bottomRight $Fg $Bg $Attr
    for($i=1;$i -lt $w-1;++$i){
        Set-MiraCanvasCell $Canvas ($X+$i) $Y $hline $Fg $Bg $Attr
        Set-MiraCanvasCell $Canvas ($X+$i) ($Y+$h-1) $hline $Fg $Bg $Attr
    }
    for($i=1;$i -lt $h-1;++$i){
        Set-MiraCanvasCell $Canvas $X ($Y+$i) '│' $Fg $Bg $Attr
        Set-MiraCanvasCell $Canvas ($X+$w-1) ($Y+$i) '│' $Fg $Bg $Attr
    }
}

function Get-MiraCanvasStyleCode($Cell){
    if($null -eq $Cell){return ''}
    $parts=New-Object System.Collections.Generic.List[string]
    if([int]$Cell.Attr -ne 0){[void]$parts.Add([string]([int]$Cell.Attr))}
    if(-not [string]::IsNullOrEmpty([string]$Cell.Fg)){[void]$parts.Add('38;2;'+[string]$Cell.Fg)}
    if(-not [string]::IsNullOrEmpty([string]$Cell.Bg)){[void]$parts.Add('48;2;'+[string]$Cell.Bg)}
    if($parts.Count -eq 0){return '0'}
    return ($parts -join ';')
}

function Convert-MiraRgbToConsoleColor([string]$Rgb,[ConsoleColor]$Fallback=[ConsoleColor]::Gray){
    if([string]::IsNullOrEmpty($Rgb)){return $Fallback}
    $m=[regex]::Match($Rgb,'^(\d{1,3});(\d{1,3});(\d{1,3})$')
    if(-not $m.Success){return $Fallback}
    $r=[int]$m.Groups[1].Value;$g=[int]$m.Groups[2].Value;$b=[int]$m.Groups[3].Value
    $palette=@{
        Black=@(0,0,0);DarkBlue=@(0,0,128);DarkGreen=@(0,128,0);DarkCyan=@(0,128,128)
        DarkRed=@(128,0,0);DarkMagenta=@(128,0,128);DarkYellow=@(128,128,0);Gray=@(192,192,192)
        DarkGray=@(128,128,128);Blue=@(0,0,255);Green=@(0,255,0);Cyan=@(0,255,255)
        Red=@(255,0,0);Magenta=@(255,0,255);Yellow=@(255,255,0);White=@(255,255,255)
    }
    $best=$Fallback;$distance=[double]::PositiveInfinity
    foreach($name in $palette.Keys){
        $p=$palette[$name];$dr=$r-$p[0];$dg=$g-$p[1];$db=$b-$p[2];$d=($dr*$dr)+($dg*$dg)+($db*$db)
        if($d -lt $distance){$distance=$d;$best=[ConsoleColor]$name}
    }
    return $best
}

function Write-MiraCanvas($Canvas,[int]$X=0,[int]$Y=0){
    if($null -eq $Canvas){return}
    for($row=0;$row -lt [int]$Canvas.Height;++$row){
        if(-not (Cursor $X ($Y+$row))){continue}
        $runStart=0
        while($runStart -lt [int]$Canvas.Width){
            $base=$Canvas.Cells[$row,$runStart]
            $key=([string]$base.Fg)+'|'+([string]$base.Bg)+'|'+([int]$base.Attr)
            $runEnd=$runStart+1
            while($runEnd -lt [int]$Canvas.Width){
                $n=$Canvas.Cells[$row,$runEnd];$nk=([string]$n.Fg)+'|'+([string]$n.Bg)+'|'+([int]$n.Attr)
                if($nk -ne $key){break}
                ++$runEnd
            }
            $sb=New-Object System.Text.StringBuilder
            for($col=$runStart;$col -lt $runEnd;++$col){$cell=$Canvas.Cells[$row,$col];if(-not $cell.Continuation){[void]$sb.Append([string]$cell.Ch)}}
            if($sb.Length -gt 0){
                $fg=Convert-MiraRgbToConsoleColor ([string]$base.Fg) ([ConsoleColor]::Gray)
                $bg=Convert-MiraRgbToConsoleColor ([string]$base.Bg) ([ConsoleColor]::Black)
                Write-Host $sb.ToString() -NoNewline -ForegroundColor $fg -BackgroundColor $bg
            }
            $runStart=$runEnd
        }
        try{[Console]::ForegroundColor=[ConsoleColor]::Gray;[Console]::BackgroundColor=[ConsoleColor]::Black}catch{}
    }
}

function Fill-MiraCanvasRow($Canvas,[int]$X,[int]$Y,[int]$Width,[string]$Fg='',[string]$Bg='',[int]$Attr=0){
    if($null -eq $Canvas -or $Y -lt 0 -or $Y -ge [int]$Canvas.Height){return}
    $x0=[Math]::Max(0,$X);$x1=[Math]::Min([int]$Canvas.Width,$x0+[Math]::Max(0,$Width))
    for($x=$x0;$x -lt $x1;++$x){Set-MiraCanvasCell $Canvas $x $Y ' ' $Fg $Bg $Attr $false}
}

# -----------------------------------------------------------------------------
# FLOW LAYOUT# -----------------------------------------------------------------------------
# FLOW LAYOUT
# Blocks become layout nodes first. Parsers will create these nodes later;
# this layer knows nothing about Markdown or TeX.
# -----------------------------------------------------------------------------

function New-MiraLayoutTextNode([string]$Text,[string]$Fg='', [string]$Bg='', [int]$Attr=0, [int]$MaxWidth=0){
    return [pscustomobject]@{
        Kind='Text'
        Text=if($null -eq $Text){''}else{[string]$Text}
        Fg=[string]$Fg
        Bg=[string]$Bg
        Attr=[int]$Attr
        MaxWidth=[int]$MaxWidth
    }
}

function New-MiraLayoutRuleNode([string]$Char='─',[string]$Fg='', [string]$Bg='', [int]$Attr=0, [int]$Width=0){
    return [pscustomobject]@{
        Kind='Rule'
        Char=if([string]::IsNullOrEmpty($Char)){'─'}else{[string]$Char}
        Fg=[string]$Fg
        Bg=[string]$Bg
        Attr=[int]$Attr
        Width=[int]$Width
    }
}

function New-MiraLayoutGroupNode($Children,[int]$Gap=0,[int]$PaddingLeft=0,[int]$PaddingRight=0){
    return [pscustomobject]@{
        Kind='Group'
        Children=@($Children)
        Gap=[Math]::Max(0,[int]$Gap)
        PaddingLeft=[Math]::Max(0,[int]$PaddingLeft)
        PaddingRight=[Math]::Max(0,[int]$PaddingRight)
    }
}

function Measure-MiraLayoutNode($Node,[int]$MaxWidth=0){
    if($null -eq $Node){return [pscustomobject]@{Width=0;Height=0}}
    $kind=[string]$Node.Kind
    switch($kind){
        'Text' {
            $limit=[int]$MaxWidth
            if([int]$Node.MaxWidth -gt 0){
                $limit=if($limit -gt 0){[Math]::Min($limit,[int]$Node.MaxWidth)}else{[int]$Node.MaxWidth}
            }
            $lines=if($limit -gt 0){@(Wrap-MiraText ([string]$Node.Text) $limit)}else{([string]$Node.Text).Split([char]10)}
            $width=0
            foreach($line in $lines){
                $mw=(Measure-MiraText ([string]$line)).Width
                if($mw -gt $width){$width=$mw}
            }
            return [pscustomobject]@{
                Width=[int]$width
                Height=[int]([Math]::Max(1,$lines.Count))
            }
        }
        'Rule' {
            $width=[int]$Node.Width
            if($width -le 0){$width=if($MaxWidth -gt 0){$MaxWidth}else{1}}
            if($MaxWidth -gt 0){$width=[Math]::Min($width,$MaxWidth)}
            return [pscustomobject]@{Width=[int][Math]::Max(1,$width);Height=1}
        }
        'Group' {
            $inner=[Math]::Max(0,$MaxWidth-[int]$Node.PaddingLeft-[int]$Node.PaddingRight)
            $width=0
            $height=0
            $hasChild=$false
            foreach($child in @($Node.Children)){
                $m=Measure-MiraLayoutNode $child $inner
                if($m.Width -gt $width){$width=$m.Width}
                if($hasChild){$height += [int]$Node.Gap}
                $height += [int]$m.Height
                $hasChild=$true
            }
            $width += [int]$Node.PaddingLeft+[int]$Node.PaddingRight
            return [pscustomobject]@{Width=[int]$width;Height=[int]$height}
        }
        default {
            return [pscustomobject]@{Width=0;Height=0}
        }
    }
}

function Place-MiraLayoutNode($Canvas,$Node,[int]$X,[int]$Y,[int]$MaxWidth){
    if($null -eq $Canvas -or $null -eq $Node){return [int]$Y}
    switch([string]$Node.Kind){
        'Text' {
            $limit=[int]$MaxWidth
            if([int]$Node.MaxWidth -gt 0){
                $limit=if($limit -gt 0){[Math]::Min($limit,[int]$Node.MaxWidth)}else{[int]$Node.MaxWidth}
            }
            $lines=if($limit -gt 0){@(Wrap-MiraText ([string]$Node.Text) $limit)}else{([string]$Node.Text).Split([char]10)}
            $row=[int]$Y
            foreach($line in $lines){
                Set-MiraCanvasText $Canvas $X $row ([string]$line) ([string]$Node.Fg) ([string]$Node.Bg) ([int]$Node.Attr) $limit
                ++$row
            }
            return $row
        }
        'Rule' {
            $width=[int]$Node.Width
            if($width -le 0){$width=$MaxWidth}
            if($MaxWidth -gt 0){$width=[Math]::Min($width,$MaxWidth)}
            $width=[Math]::Max(1,$width)
            $text=([string]$Node.Char)[0].ToString()
            $repeat=New-Object System.Text.StringBuilder
            for($i=0;$i -lt $width;++$i){[void]$repeat.Append($text)}
            Set-MiraCanvasText $Canvas $X $Y $repeat.ToString() ([string]$Node.Fg) ([string]$Node.Bg) ([int]$Node.Attr) $width
            return [int]$Y+1
        }
        'Group' {
            $inner=[Math]::Max(0,$MaxWidth-[int]$Node.PaddingLeft-[int]$Node.PaddingRight)
            $row=[int]$Y
            $first=$true
            foreach($child in @($Node.Children)){
                if(-not $first){$row += [int]$Node.Gap}
                $row=Place-MiraLayoutNode $Canvas $child ($X+[int]$Node.PaddingLeft) $row $inner
                $first=$false
            }
            return $row
        }
        default {
            return [int]$Y
        }
    }
}

function Render-MiraLayout($Node,[int]$Width=0,[int]$X=0,[int]$Y=0){
    if($Width -le 0){$Width=[Math]::Max(1,(Width)-$X-1)}
    $measure=Measure-MiraLayoutNode $Node $Width
    $canvas=New-MiraCanvas $Width ([Math]::Max(1,[int]$measure.Height))
    Place-MiraLayoutNode $canvas $Node 0 0 $Width | Out-Null
    Write-MiraCanvas $canvas $X $Y
    return $canvas
}

# -----------------------------------------------------------------------------
# DOCUMENT NODES / MARKDOWN PARSER BRIDGE
# Semantic layer only: parse response text into nodes. No terminal writes here.
# -----------------------------------------------------------------------------

function New-MiraInlineSpan([string]$Text,[string]$Fg='', [string]$Bg='', [int]$Attr=0){
    return [pscustomobject]@{Kind='Span';Text=if($null -eq $Text){''}else{[string]$Text};Fg=[string]$Fg;Bg=[string]$Bg;Attr=[int]$Attr}
}

function New-MiraParagraphNode($Spans){return [pscustomobject]@{Kind='Paragraph';Spans=@($Spans)}}
function New-MiraHeadingNode([int]$Level,$Spans){return [pscustomobject]@{Kind='Heading';Level=[Math]::Max(1,[Math]::Min(6,[int]$Level));Spans=@($Spans)}}
function New-MiraCodeNode([string[]]$Lines,[string]$Language=''){return [pscustomobject]@{Kind='Code';Lines=@($Lines);Language=[string]$Language}}
function New-MiraMathNode([string[]]$Lines,[bool]$Display=$true){return [pscustomobject]@{Kind='Math';Lines=@($Lines);Display=[bool]$Display}}
function New-MiraRuleNode(){return [pscustomobject]@{Kind='Rule'}}
function New-MiraTableNode($Rows){return [pscustomobject]@{Kind='Table';Rows=@($Rows)}}

function Split-MiraTableRow([string]$Line){
    if($null -eq $Line){return @()}
    $s=[string]$Line.Trim()
    if($s.StartsWith('|')){$s=$s.Substring(1)}
    if($s.EndsWith('|') -and $s.Length -gt 0){$s=$s.Substring(0,$s.Length-1)}
    return @($s.Split('|') | ForEach-Object {[string]$_.Trim()})
}

function Test-MiraTableSeparator([string]$Line){
    $cells=@(Split-MiraTableRow $Line)
    if($cells.Count -eq 0){return $false}
    foreach($cell in $cells){if([string]$cell -notmatch '^:?-{3,}:?$'){return $false}}
    return $true
}

function Get-MiraSpanWidth($Spans){
    $n=0
    foreach($span in @($Spans)){$n += Get-MiraCellWidth ([string]$span.Text)}
    return [int]$n
}

function Get-MiraInlineState([string]$Fg,[string]$Bg,[int]$Attr,[string]$Mode=''){
    return [pscustomobject]@{Fg=[string]$Fg;Bg=[string]$Bg;Attr=[int]$Attr;Mode=[string]$Mode}
}

function Convert-MiraSuperscript([string]$Text){
    $map=@{'0'='⁰';'1'='¹';'2'='²';'3'='₃';'4'='⁴';'5'='⁵';'6'='⁶';'7'='⁷';'8'='⁸';'9'='⁹';'+'='⁺';'-'='⁻';'='='⁼';'('='⁽';')'='⁾';'a'='ᵃ';'b'='ᵇ';'c'='ᶜ';'d'='ᵈ';'e'='ᵉ';'f'='ᶠ';'g'='ᵍ';'h'='ʰ';'i'='ⁱ';'j'='ʲ';'k'='ᵏ';'l'='ˡ';'m'='ᵐ';'n'='ⁿ';'o'='ᵒ';'p'='ᵖ';'r'='ʳ';'s'='ˢ';'t'='ᵗ';'u'='ᵘ';'v'='ᵛ';'w'='ʷ';'x'='ˣ';'y'='ʸ';'z'='ᶻ'}
    $out=New-Object System.Text.StringBuilder
    foreach($ch in ([string]$Text).ToCharArray()){if($map.ContainsKey([string]$ch)){[void]$out.Append($map[[string]$ch])}else{[void]$out.Append($ch)}}
    return $out.ToString()
}

function Convert-MiraSubscript([string]$Text){
    $map=@{'0'='₀';'1'='₁';'2'='₂';'3'='₃';'4'='₄';'5'='₅';'6'='₆';'7'='₇';'8'='₈';'9'='₉';'+'='₊';'-'='₋';'='='₌';'('='₍';')'='₎';'a'='ₐ';'e'='ₑ';'h'='ₕ';'i'='ᵢ';'j'='ⱼ';'k'='ₖ';'l'='ₗ';'m'='ₘ';'n'='ₙ';'o'='ₒ';'p'='ₚ';'r'='ᵣ';'s'='ₛ';'t'='ₜ';'u'='ᵤ';'v'='ᵥ';'x'='ₓ'}
    $out=New-Object System.Text.StringBuilder
    foreach($ch in ([string]$Text).ToCharArray()){if($map.ContainsKey([string]$ch)){[void]$out.Append($map[[string]$ch])}else{[void]$out.Append($ch)}}
    return $out.ToString()
}

function Parse-MiraInline([string]$Line){
    if($null -eq $Line){return @()}
    $s=[string]$Line;$out=New-Object System.Collections.Generic.List[object]
    $state=Get-MiraInlineState ([string]$script:MarkupTheme.InlineTextRGB) '' 0 ''
    $stack=New-Object System.Collections.Generic.Stack[object]
    $emit={param([string]$Text,[string]$Fg,[string]$Bg,[int]$Attr,[string]$Mode)
        if([string]::IsNullOrEmpty($Text)){return}
        $v=[string]$Text
        if($Mode -eq 'sup'){$v=Convert-MiraSuperscript $v}elseif($Mode -eq 'sub'){$v=Convert-MiraSubscript $v}
        [void]$out.Add((New-MiraInlineSpan $v $Fg $Bg $Attr))
    }
    $tags=@('b','strong','i','em','u','s','strike','del','code','mark','kbd','sup','sub','small','a','br','hr','img')
    $pos=0;$plainStart=0
    while($pos -lt $s.Length){
        $kind='';$end=$pos;$value='';$tagClosing=$false;$tag=''
        if($s[$pos] -eq '<'){
            if($s.Substring($pos).StartsWith('<!--')){
                $ce=$s.IndexOf('-->',$pos+4)
                if($ce -ge 0){
                    if($pos -gt $plainStart){&$emit $s.Substring($plainStart,$pos-$plainStart) $state.Fg $state.Bg $state.Attr $state.Mode}
                    $pos=$ce+3;$plainStart=$pos;continue
                }
            }
            $gt=$s.IndexOf('>',$pos+1)
            if($gt -gt $pos){
                $raw=$s.Substring($pos+1,$gt-$pos-1).Trim()
                if($raw.StartsWith('/')){$tagClosing=$true;$raw=$raw.Substring(1).Trim()}
                if($raw.EndsWith('/')){$raw=$raw.Substring(0,$raw.Length-1).Trim()}
                $n=0;while($n -lt $raw.Length -and (([char]::IsLetterOrDigit($raw[$n])) -or $raw[$n] -eq ':')){++$n}
                if($n -gt 0){$tag=$raw.Substring(0,$n).ToLowerInvariant();if($tags -contains $tag){$kind='tag';$end=$gt+1;$value=$raw}}
            }
        }
        if($kind -eq '' -and $s[$pos] -eq [char]96){
            $q=$s.IndexOf([char]96,$pos+1);if($q -gt $pos+1){$kind='code';$end=$q+1;$value=$s.Substring($pos+1,$q-$pos-1)}
        }
        if($kind -eq '' -and $s[$pos] -eq '$' -and ($pos+1 -ge $s.Length -or $s[$pos+1] -ne '$')){
            $q=$s.IndexOf('$',$pos+1);if($q -gt $pos+1){$kind='math';$end=$q+1;$value=$s.Substring($pos+1,$q-$pos-1)}
        }
        if($kind -eq '' -and ($s.Substring($pos).StartsWith('**') -or $s.Substring($pos).StartsWith('__'))){
            $d=$s.Substring($pos,2);$q=$s.IndexOf($d,$pos+2);if($q -gt $pos+2){$kind='bold';$end=$q+2;$value=$s.Substring($pos+2,$q-$pos-2)}
        }
        if($kind -eq '' -and $s.Substring($pos).StartsWith('~~')){
            $q=$s.IndexOf('~~',$pos+2);if($q -gt $pos+2){$kind='strike';$end=$q+2;$value=$s.Substring($pos+2,$q-$pos-2)}
        }
        if($kind -eq '' -and ($s[$pos] -eq '*' -or $s[$pos] -eq '_')){
            $d=[string]$s[$pos];$open=($pos+1 -lt $s.Length -and -not [char]::IsWhiteSpace($s[$pos+1]))
            if($d -eq '_' -and $pos -gt 0 -and [char]::IsLetterOrDigit($s[$pos-1])){$open=$false}
            if($open){$q=$s.IndexOf($d,$pos+1);if($q -gt $pos+1){$close=($q+1 -ge $s.Length -or -not [char]::IsLetterOrDigit($s[$q+1]));if($close){$kind='italic';$end=$q+1;$value=$s.Substring($pos+1,$q-$pos-1)}}}
        }
        if($kind -eq '' -and $s[$pos] -eq '['){
            $mid=$s.IndexOf('](',$pos+1);if($mid -gt $pos+1){$q=$s.IndexOf(')',$mid+2);if($q -gt $mid+2){$kind='link';$end=$q+1;$value=$s.Substring($pos+1,$mid-$pos-1)}}
        }
        if($kind -ne ''){
            if($pos -gt $plainStart){&$emit $s.Substring($plainStart,$pos-$plainStart) $state.Fg $state.Bg $state.Attr $state.Mode}
            switch($kind){
                'code'   {&$emit $value ([string]$script:MarkupTheme.InlineCodeRGB) ([string]$script:MarkupTheme.InlineCodeBG) 0 ''}
                'math'   {&$emit (Convert-LatexToUnicode $value) ([string]$script:MarkupTheme.MathTextColor) $state.Bg $state.Attr $state.Mode}
                'bold'   {&$emit $value ([string]$script:MarkupTheme.InlineBoldRGB) $state.Bg ($state.Attr -bor 1) $state.Mode}
                'strike' {&$emit $value ([string]$script:MarkupTheme.InlineStrikeRGB) $state.Bg ($state.Attr -bor 9) $state.Mode}
                'italic' {&$emit $value ([string]$script:MarkupTheme.InlineItalicRGB) $state.Bg ($state.Attr -bor 3) $state.Mode}
                'link'   {&$emit $value ([string]$script:MarkupTheme.InlineLinkRGB) $state.Bg ($state.Attr -bor 4) $state.Mode}
                'tag' {
                    if($tagClosing){
                        if($stack.Count -gt 0){while($stack.Count -gt 0){$e=$stack.Pop();$state=$e.State;if([string]$e.Tag -eq $tag){break}}}
                    }elseif($tag -in @('br','hr','img')){
                        $glyph=if($tag -eq 'br'){'↵'}elseif($tag -eq 'hr'){'─'}else{'[image]'}
                        $fg=if($tag -eq 'hr'){$script:MarkupTheme.MathFrameRGB}else{$script:MarkupTheme.InlineTagRGB}
                        &$emit $glyph ([string]$fg) $state.Bg $state.Attr $state.Mode
                    }else{
                        [void]$stack.Push([pscustomobject]@{Tag=$tag;State=$state})
                        $next=Get-MiraInlineState $state.Fg $state.Bg $state.Attr $state.Mode
                        switch($tag){
                            'b' {$next.Fg=$script:MarkupTheme.InlineBoldRGB;$next.Attr=$next.Attr-bor 1}
                            'strong' {$next.Fg=$script:MarkupTheme.InlineBoldRGB;$next.Attr=$next.Attr-bor 1}
                            'i' {$next.Fg=$script:MarkupTheme.InlineItalicRGB;$next.Attr=$next.Attr-bor 3}
                            'em' {$next.Fg=$script:MarkupTheme.InlineItalicRGB;$next.Attr=$next.Attr-bor 3}
                            'u' {$next.Fg=$script:MarkupTheme.InlineUnderlineRGB;$next.Attr=$next.Attr-bor 4}
                            's' {$next.Fg=$script:MarkupTheme.InlineStrikeRGB;$next.Attr=$next.Attr-bor 9}
                            'strike' {$next.Fg=$script:MarkupTheme.InlineStrikeRGB;$next.Attr=$next.Attr-bor 9}
                            'del' {$next.Fg=$script:MarkupTheme.InlineStrikeRGB;$next.Attr=$next.Attr-bor 9}
                            'code' {$next.Fg=$script:MarkupTheme.InlineCodeRGB;$next.Bg=$script:MarkupTheme.InlineCodeBG;$next.Attr=0}
                            'mark' {$next.Fg=$script:MarkupTheme.InlineMarkRGB;$next.Bg=$script:MarkupTheme.InlineMarkBG}
                            'kbd' {$next.Fg=$script:MarkupTheme.InlineKbdRGB;$next.Bg=$script:MarkupTheme.InlineKbdBG;$next.Attr=$next.Attr-bor 1}
                            'sup' {$next.Mode='sup'}
                            'sub' {$next.Mode='sub'}
                            'small' {$next.Attr=$next.Attr-bor 2}
                            'a' {$next.Fg=$script:MarkupTheme.InlineLinkRGB;$next.Attr=$next.Attr-bor 4}
                        }
                        $state=$next
                    }
                }
            }
            $pos=$end;$plainStart=$pos;continue
        }
        ++$pos
    }
    if($plainStart -lt $s.Length){&$emit $s.Substring($plainStart) $state.Fg $state.Bg $state.Attr $state.Mode}
    return @($out)
}

function Flush-MiraParagraphNode($Nodes,$Paragraph){
    if($Paragraph.Count -eq 0){return}
    [void]$Nodes.Add((New-MiraParagraphNode (Parse-MiraInline ($Paragraph -join ' '))))
    $Paragraph.Clear()
}

function Parse-MiraMarkdown([string]$Text){
    if($null -eq $Text){return @()}
    $lines=@([regex]::Split([string]$Text,"\r?\n"))
    $nodes=New-Object System.Collections.Generic.List[object]
    $paragraph=New-Object System.Collections.Generic.List[string]
    $code=New-Object System.Collections.Generic.List[string]
    $math=New-Object System.Collections.Generic.List[string]
    $inCode=$false;$inMath=$false;$codeLanguage=''

    for($i=0;$i -lt $lines.Count;++$i){
        $line=[string]$lines[$i];$trim=$line.Trim()
        if($inCode){
            if($line -match ('^[ \t]*\x60\x60\x60[^\r\n]*[ \t]*$')){
                [void]$nodes.Add((New-MiraCodeNode @($code) $codeLanguage));$code.Clear();$codeLanguage='';$inCode=$false
            }else{[void]$code.Add($line)}
            continue
        }
        if($inMath){
            $close=$line.IndexOf('$$')
            if($line.Trim() -eq '\]'){
                [void]$nodes.Add((New-MiraMathNode @($math) $true));$math.Clear();$inMath=$false
            }elseif($close -ge 0){
                $before=$line.Substring(0,$close)
                if(-not [string]::IsNullOrWhiteSpace($before)){[void]$math.Add($before)}
                [void]$nodes.Add((New-MiraMathNode @($math) $true));$math.Clear();$inMath=$false
                $after=$line.Substring($close+2)
                if(-not [string]::IsNullOrWhiteSpace($after)){[void]$paragraph.Add($after.Trim())}
            }else{[void]$math.Add($line)}
            continue
        }
        if($line -match ('^[ \t]*\x60\x60\x60([^\r\n]*)[ \t]*$')){
            Flush-MiraParagraphNode $nodes $paragraph;$inCode=$true;$codeLanguage=$Matches[1].Trim().ToLowerInvariant();continue
        }
        if($line -match '^[ \t]*\$\$(.*)$'){
            Flush-MiraParagraphNode $nodes $paragraph
            $rest=[string]$Matches[1];$close=$rest.IndexOf('$$')
            if($close -ge 0){
                [void]$nodes.Add((New-MiraMathNode @($rest.Substring(0,$close)) $true))
                $after=$rest.Substring($close+2)
                if(-not [string]::IsNullOrWhiteSpace($after)){[void]$paragraph.Add($after.Trim())}
            }else{
                $inMath=$true
                if(-not [string]::IsNullOrWhiteSpace($rest)){[void]$math.Add($rest)}
            }
            continue
        }
        if($line -match '^[ \t]*\\\[(.*)$'){
            Flush-MiraParagraphNode $nodes $paragraph
            $rest=[string]$Matches[1]
            if($rest -match '^(.*)\\\](.*)$'){
                [void]$nodes.Add((New-MiraMathNode @([string]$Matches[1]) $true))
                if(-not [string]::IsNullOrWhiteSpace([string]$Matches[2])){[void]$paragraph.Add([string]$Matches[2].Trim())}
            }else{
                $inMath=$true
                if(-not [string]::IsNullOrWhiteSpace($rest)){[void]$math.Add($rest)}
            }
            continue
        }
        if([string]::IsNullOrWhiteSpace($trim)){Flush-MiraParagraphNode $nodes $paragraph;continue}
        if($trim -match '^(#{1,6})[ \t]+(.*)$'){
            Flush-MiraParagraphNode $nodes $paragraph
            [void]$nodes.Add((New-MiraHeadingNode $Matches[1].Length (Parse-MiraInline ([string]$Matches[2]))));continue
        }
        if($trim -match '^([-*_])([ \t]*\1){2,}[ \t]*$'){
            Flush-MiraParagraphNode $nodes $paragraph;[void]$nodes.Add((New-MiraRuleNode));continue
        }
        if(($i+1) -lt $lines.Count -and (Test-MiraTableSeparator $lines[$i+1]) -and $trim -match '^\|?.+\|.+\|?$'){
            Flush-MiraParagraphNode $nodes $paragraph
            $rows=New-Object System.Collections.Generic.List[object];[void]$rows.Add((Split-MiraTableRow $line));++$i
            while($i -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace([string]$lines[$i])){
                $candidate=[string]$lines[$i]
                if($candidate -notmatch '\|'){break}
                if(Test-MiraTableSeparator $candidate){++$i;continue}
                [void]$rows.Add((Split-MiraTableRow $candidate));++$i
            }
            --$i;[void]$nodes.Add((New-MiraTableNode @($rows)));continue
        }
        $content=$trim
        if($content -match '^[-*+][ \t]+(.+)$'){$content='• '+[string]$Matches[1]}
        elseif($content -match '^\d+[.)][ \t]+(.+)$'){$content='• '+[string]$Matches[1]}
        elseif($content -match '^>[ \t]?(.*)$'){$content='│ '+[string]$Matches[1]}
        [void]$paragraph.Add($content)
    }
    if($inCode){[void]$nodes.Add((New-MiraCodeNode @($code) $codeLanguage))}
    if($inMath){[void]$nodes.Add((New-MiraMathNode @($math) $true))}
    Flush-MiraParagraphNode $nodes $paragraph
    return @($nodes)
}

# -----------------------------------------------------------------------------
# DOCUMENT LAYOUT / V2 WRITER
# Semantic nodes are measured and placed on the shared cell canvas.
# -----------------------------------------------------------------------------

function Wrap-MiraSpans($Spans,[int]$MaxWidth){
    $limit=[Math]::Max(1,[int]$MaxWidth)
    $lines=New-Object System.Collections.Generic.List[object]
    $current=New-Object System.Collections.Generic.List[object]
    $used=0

    foreach($span in @($Spans)){
        $text=[string]$span.Text
        if($text.Length -eq 0){continue}
        $tokens=@([regex]::Matches($text,'\s+|\S+') | ForEach-Object {[string]$_.Value})
        foreach($token in $tokens){
            $tw=Measure-MiraText $token
            $tokenWidth=[int]$tw.Width
            $isSpace=[string]::IsNullOrWhiteSpace($token)

            if($isSpace -and $current.Count -eq 0){continue}

            if($tokenWidth -le $limit - $used){
                [void]$current.Add((New-MiraInlineSpan $token ([string]$span.Fg) ([string]$span.Bg) ([int]$span.Attr)))
                $used += $tokenWidth
                continue
            }

            if($current.Count -gt 0){
                [void]$lines.Add(@($current))
                $current=New-Object System.Collections.Generic.List[object]
                $used=0
            }
            if($isSpace){continue}

            if($tokenWidth -le $limit){
                [void]$current.Add((New-MiraInlineSpan $token ([string]$span.Fg) ([string]$span.Bg) ([int]$span.Attr)))
                $used=$tokenWidth
                continue
            }

            $piece=New-Object System.Text.StringBuilder
            $pieceWidth=0
            for($ci=0;$ci -lt $token.Length;){
                $cp=[char]::ConvertToUtf32($token,$ci)
                $units=if($cp -gt 0xFFFF){2}else{1}
                $ch=[string]::Copy($token,$ci,$units)
                $cw=Get-MiraCellWidth $ch
                if($cw -gt 0){
                    if($pieceWidth+$cw -gt $limit){
                        if($piece.Length -gt 0){
                            [void]$lines.Add(@((New-MiraInlineSpan $piece.ToString() ([string]$span.Fg) ([string]$span.Bg) ([int]$span.Attr))))
                        }
                        [void]$piece.Clear();$pieceWidth=0
                    }
                    [void]$piece.Append($ch);$pieceWidth += $cw
                }
                $ci += $units
            }
            if($piece.Length -gt 0){
                [void]$current.Add((New-MiraInlineSpan $piece.ToString() ([string]$span.Fg) ([string]$span.Bg) ([int]$span.Attr)))
                $used=$pieceWidth
            }
        }
    }

    if($current.Count -gt 0 -or $lines.Count -eq 0){[void]$lines.Add(@($current))}
    return @($lines)
}

function Measure-MiraDocumentNodeV2([object]$Node,[int]$MaxWidth){
    if($null -eq $Node){return [pscustomobject]@{Width=0;Height=0}}
    switch([string]$Node.Kind){
        'Paragraph' {
            $wrapped=@(Wrap-MiraSpans $Node.Spans $MaxWidth)
            $w=0
            foreach($line in $wrapped){$w=[Math]::Max($w,(Get-MiraSpanWidth $line))}
            return [pscustomobject]@{Width=[int]$w;Height=[int][Math]::Max(1,$wrapped.Count)}
        }
        'Heading' {
            $wrapped=@(Wrap-MiraSpans $Node.Spans $MaxWidth)
            $w=0
            foreach($line in $wrapped){$w=[Math]::Max($w,(Get-MiraSpanWidth $line))}
            return [pscustomobject]@{Width=[int]$w;Height=[int][Math]::Max(1,$wrapped.Count)}
        }
        'Code' {
            $h=[Math]::Max(1,@($Node.Lines).Count+2)
            $w=(Measure-MiraText (('∙∙ '+$(if([string]::IsNullOrWhiteSpace([string]$Node.Language)){'CODE'}else{[string]$Node.Language}))).Width)
            foreach($line in @($Node.Lines)){$w=[Math]::Max($w,(Measure-MiraText ([string]$line)).Width)}
            return [pscustomobject]@{Width=[int][Math]::Min($w,$MaxWidth);Height=[int]$h}
        }
        'Math' {
            $h=[Math]::Max(1,@($Node.Lines).Count+2);$w=6
            foreach($line in @($Node.Lines)){$w=[Math]::Max($w,(Measure-MiraText (Convert-LatexToUnicode ([string]$line))).Width)}
            return [pscustomobject]@{Width=[int][Math]::Min($w,$MaxWidth);Height=[int]$h}
        }
        'Rule' {return [pscustomobject]@{Width=[int]$MaxWidth;Height=1}}
        'Table' {
            $cols=0
            foreach($row in @($Node.Rows)){$cols=[Math]::Max($cols,@($row).Count)}
            if($cols -eq 0){return [pscustomobject]@{Width=0;Height=0}}
            $widths=New-Object int[] $cols
            foreach($row in @($Node.Rows)){
                for($j=0;$j -lt @($row).Count;++$j){$widths[$j]=[Math]::Max($widths[$j],[Math]::Min(30,(Measure-MiraText ([string]$row[$j])).Width))}
            }
            $total=1;foreach($cw in $widths){$total += $cw+3}
            return [pscustomobject]@{Width=[int][Math]::Min($total,$MaxWidth);Height=[int][Math]::Max(1,@($Node.Rows).Count*2-1)}
        }
        default {return [pscustomobject]@{Width=0;Height=0}}
    }
}

function Place-MiraDocumentNodeV2($Canvas,$Node,[int]$X,[int]$Y,[int]$MaxWidth){
    if($null -eq $Canvas -or $null -eq $Node){return [int]$Y}
    switch([string]$Node.Kind){
        'Paragraph' {
            foreach($line in @(Wrap-MiraSpans $Node.Spans $MaxWidth)){Set-MiraSpans $Canvas $X $Y $line $MaxWidth;++$Y}
            return [int]$Y
        }
        'Heading' {
            $glyph=switch([int]$Node.Level){1{'◆'}2{'◇'}3{'▸'}4{'›'}default{'·'}}
            foreach($line in @(Wrap-MiraSpans $Node.Spans ([Math]::Max(1,$MaxWidth-3)))){
                Set-MiraCanvasText $Canvas $X $Y ($glyph+' ') '175;185;200' '' 0 2
                foreach($span in @($line)){$span.Fg=[string]$script:MarkupTheme.InlineBoldRGB;$span.Attr=$span.Attr -bor 1}
                Set-MiraSpans $Canvas ($X+2) $Y $line ([Math]::Max(1,$MaxWidth-2));++$Y
            }
            return [int]$Y
        }
        'Code' {
            $label=if([string]::IsNullOrWhiteSpace([string]$Node.Language)){'CODE'}else{'CODE '+([string]$Node.Language).ToUpperInvariant()}
            Fill-MiraCanvasRow $Canvas $X $Y $MaxWidth ([string]$script:MarkupTheme.CodeHeaderRGB) ([string]$script:MarkupTheme.CodeHeaderBG) 1
            Set-MiraCanvasText $Canvas $X $Y ('∙∙ '+$label) ([string]$script:MarkupTheme.CodeHeaderRGB) ([string]$script:MarkupTheme.CodeHeaderBG) 1 $MaxWidth;++$Y
            foreach($line in @($Node.Lines)){
                Fill-MiraCanvasRow $Canvas $X $Y $MaxWidth ([string]$script:MarkupTheme.CodePanelRGB) ([string]$script:MarkupTheme.CodePanelBG)
                Set-MiraCanvasText $Canvas $X $Y ([string]$line) ([string]$script:MarkupTheme.CodePanelRGB) ([string]$script:MarkupTheme.CodePanelBG) 0 $MaxWidth;++$Y
            }
            Fill-MiraCanvasRow $Canvas $X $Y $MaxWidth ([string]$script:MarkupTheme.CodePanelRGB) ([string]$script:MarkupTheme.CodePanelBG)
            Set-MiraCanvasText $Canvas $X $Y ('─'*[Math]::Min(18,$MaxWidth)) '120;125;135' ([string]$script:MarkupTheme.CodePanelBG) 0 $MaxWidth
            return [int]$Y+1
        }
        'Math' {
            Set-MiraCanvasText $Canvas $X $Y '∙∙ MATH' '100;180;210' '' 0 $MaxWidth;++$Y
            foreach($line in @($Node.Lines)){Set-MiraCanvasText $Canvas $X $Y (Convert-LatexToUnicode ([string]$line)) '185;185;190' '' 0 $MaxWidth;++$Y}
            Set-MiraCanvasText $Canvas $X $Y ('∙'*[Math]::Max(1,[Math]::Min(18,$MaxWidth))) '120;125;135' '' 0 $MaxWidth
            return [int]$Y+1
        }
        'Rule' {Set-MiraCanvasText $Canvas $X $Y ('─'*[Math]::Max(1,$MaxWidth)) '80;84;92' '' 0 $MaxWidth;return [int]$Y+1}
        'Table' {
            $rows=@($Node.Rows);$cols=0
            foreach($row in $rows){$cols=[Math]::Max($cols,@($row).Count)}
            if($cols -le 0){return [int]$Y}
            $widths=New-Object int[] $cols
            foreach($row in $rows){for($j=0;$j -lt @($row).Count;++$j){$widths[$j]=[Math]::Max($widths[$j],[Math]::Min(30,(Measure-MiraText ([string]$row[$j])).Width))}}
            for($ri=0;$ri -lt $rows.Count;++$ri){
                $row=$rows[$ri];$parts=New-Object System.Collections.Generic.List[string]
                for($j=0;$j -lt $cols;++$j){$v=if($j -lt @($row).Count){[string]$row[$j]}else{''};[void]$parts.Add(' '+(Pad-MiraCells $v $widths[$j])+' ')}
                if($ri -eq 0){Fill-MiraCanvasRow $Canvas $X $Y $MaxWidth ([string]$script:MarkupTheme.TableHeaderRGB) ([string]$script:MarkupTheme.TableHeaderBG) 1}
                $fg=if($ri -eq 0){[string]$script:MarkupTheme.TableHeaderRGB}else{'175;175;180'}
                $bg=if($ri -eq 0){[string]$script:MarkupTheme.TableHeaderBG}else{''}
                $attr=if($ri -eq 0){1}else{0}
                Set-MiraCanvasText $Canvas $X $Y ('|'+($parts -join '|')+'|') $fg $bg $attr $MaxWidth;++$Y
                if($ri -lt $rows.Count-1){
                    $pieces=@($widths|ForEach-Object{('-' * ($_+2))})
                    Set-MiraCanvasText $Canvas $X $Y ('+'+($pieces -join '+')+'+') '100;105;115' '' 0 $MaxWidth;++$Y
                }
            }
            return [int]$Y
        }
        default {return [int]$Y}
    }
}

function Render-MiraDocumentV2([string]$Text){
    if($null -eq $Text){return}
    if(-not $script:MarkupFrameActive){Begin-MessageFrame}
    try{
        try{
            $nodes=@(Parse-MiraMarkdown $Text)
        }catch{
            # Parser failure must never destroy Mira's response surface.
            $nodes=@((New-MiraParagraphNode (Parse-MiraInline ([string]$Text))))
        }

        $available=[Math]::Max(10,(Width)-4)
        $height=0
        foreach($node in $nodes){
            try{
                $height += [int](Measure-MiraDocumentNodeV2 $node $available).Height+1
            }catch{
                $height += [Math]::Max(1,([string]$Text -split "
?
").Count)+1
            }
        }
        $height=[Math]::Max(1,$height)
        $canvas=New-MiraCanvas $available $height
        $y=0

        foreach($node in $nodes){
            try{
                $y=Place-MiraDocumentNodeV2 $canvas $node 2 $y ($available-2)
            }catch{
                # A broken node is rendered as plain text on the same canvas.
                $fallback=[string]$Text
                $fallbackLines=@($fallback -split "
?
",-1)
                foreach($fl in $fallbackLines){
                    if($y -ge $canvas.Height){break}
                    Set-MiraCanvasText $canvas 2 $y ([string]$fl) ([string]$script:MarkupTheme.InlineTextRGB) '' 0 ($available-2)
                    ++$y
                }
                break
            }
            ++$y
        }

        $canvasTop=(Row)
        Write-MiraCanvas $canvas 0 $canvasTop
        [void](Cursor 0 ($canvasTop+$canvas.Height))
    }catch{
        # Last-resort surface: keep the frame/status visible and expose the
        # renderer error instead of silently losing the response.
        try{
            $msg=[string]$_.Exception.Message
            $w=[Math]::Max(20,(Width))
            Write-Host ('  [v2 renderer: '+$msg+')') -ForegroundColor Yellow
            foreach($line in @(([string]$Text -split "
?
",-1))){
                Write-Host ('  '+[string]$line) -ForegroundColor Gray
            }
        }catch{
            try{Write-Host ([string]$Text) -ForegroundColor Gray}catch{}
        }
    }finally{
        End-MessageFrame
    }
}
function Get-MiraCellPrefixLength([string]$Text,[int]$MaxCells){
    if([string]::IsNullOrEmpty($Text) -or $MaxCells -le 0){return 0}
    $used=0
    for($i=0;$i -lt $Text.Length;){
        $start=$i
        $cp=[char]::ConvertToUtf32($Text,$i)
        $chars=if($cp -gt 0xFFFF){2}else{1}
        $cell=if($cp -eq 0 -or $cp -lt 32 -or ($cp -ge 0x7F -and $cp -lt 0xA0) -or
                   ($cp -ge 0x300 -and $cp -le 0x36F) -or ($cp -ge 0x1AB0 -and $cp -le 0x1AFF) -or
                   ($cp -ge 0x1DC0 -and $cp -le 0x1DFF) -or ($cp -ge 0x20D0 -and $cp -le 0x20FF) -or
                   ($cp -ge 0xFE00 -and $cp -le 0xFE0F) -or ($cp -ge 0xE0100 -and $cp -le 0xE01EF) -or
                   $cp -eq 0x200D){0}
              elseif(($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2329 -and $cp -le 0x232A) -or
                     ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or
                     ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or ($cp -ge 0xFE10 -and $cp -le 0xFE6F) -or
                     ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or
                     ($cp -ge 0x1F300 -and $cp -le 0x1FAFF) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD)){2}else{1}
        if(($used+$cell) -gt $MaxCells){break}
        $used += $cell
        $i += $chars
    }
    return $i
}

function Pad-MiraCells([string]$Text,[int]$TargetCells){
    $s=[string]$Text
    $pad=[Math]::Max(0,$TargetCells-(Get-MiraCellWidth $s))
    return $s + (' '*$pad)
}

function Write-MiraRgb([string]$Text,[string]$Rgb,[ConsoleColor]$Fallback=[ConsoleColor]::DarkGray){
    Write-Host $Text -ForegroundColor $Fallback
}

function Add-MarkupSegment([string]$Text,[ConsoleColor]$Color){
    if($null -eq $Text -or $Text.Length -eq 0){return}

    # Width here means terminal display cells, not UTF-16 code units.
    while($Text.Length -gt 0){
        if(-not $script:MarkupFrameActive){
            Write-Host $Text -NoNewline -ForegroundColor (Resolve-UiRenderColor $Color)
            return
        }

        $room=$script:MarkupFrameWidth-$script:MarkupFrameUsed
        if($room -le 0){
            Write-Host ''
            Begin-MarkupLine
            $room=$script:MarkupFrameWidth-$script:MarkupFrameUsed
        }

        $takeChars=Get-MiraCellPrefixLength $Text $room
        if($takeChars -le 0){break}

        $part=$Text.Substring(0,$takeChars)
        Write-Host $part -NoNewline -ForegroundColor (Resolve-UiRenderColor $Color)
        $script:MarkupFrameUsed += Get-MiraCellWidth $part
        $Text=$Text.Substring($takeChars)

        if($Text.Length -gt 0){
            Write-Host ''
            Begin-MarkupLine
        }
    }
}

function End-MarkupLine(){
    if($script:MarkupFrameActive){
        $remaining=[Math]::Max(0,$script:MarkupFrameWidth-$script:MarkupFrameUsed)
        if($remaining -gt 0){Write-Host (' ' * $remaining) -NoNewline -ForegroundColor Gray}
        Write-Host ''
    }else{
        Write-Host ''
    }
    $script:MarkupFrameUsed=0
}

function Write-MarkupPlainLine([string]$Text,[ConsoleColor]$Color=[ConsoleColor]::Gray){
    Begin-MarkupLine
    Add-MarkupSegment ([string]$Text) $Color
    End-MarkupLine
}

function Get-MessageFrameTop([string]$Status,[int]$WidthOverride=0){
    $width=if($WidthOverride -gt 0){[int]$WidthOverride}else{[Math]::Max(20,(Width))}
    $boxWidth=$width-1
    $status=[string]$Status
    if([string]::IsNullOrWhiteSpace($status)){$status='...  0.0s'}
    $prefix=[string]$script:MarkupTheme.MessageTopLeft + [string]$script:MarkupTheme.MessageTopPrefix + $status + ' '
    $right=[string]$script:MarkupTheme.MessageTopRight
    $fill=[Math]::Max(0,$boxWidth-1-(Get-MiraCellWidth $prefix))
    return ($prefix + ([string]$script:MarkupTheme.MessageHorizontal*$fill) + $right)
}

function Write-MiraFrameCells([string]$Text,[string]$Rgb,[ConsoleColor]$Fallback,[bool]$NewLine=$false){
    $oldFg=$null
    try{$oldFg=[Console]::ForegroundColor}catch{}
    try{
        [Console]::ForegroundColor=Resolve-UiRenderColor $Fallback
        [Console]::Write([string]$Text)
        if($NewLine){[Console]::WriteLine('')}
    }finally{
        if($null -ne $oldFg){try{[Console]::ForegroundColor=$oldFg}catch{}}
    }
}

function Start-MessageFrameWait(){
    if(-not [bool]$script:MarkupTheme.MessageFrameEnabled -or -not $script:UiRenderEnabled){return}
    $script:ResponseFrameWaiting=$true
    try{$script:ResponseFrameLiveRow=[Console]::CursorTop}catch{$script:ResponseFrameLiveRow=(Row)}
    $script:ResponseFrameWidth=[Math]::Max(20,(Width))
    $script:ResponseFrameCursorCaptured=$false

    try{
        $script:ResponseFrameCursorVisible=[Console]::CursorVisible
        $script:ResponseFrameCursorCaptured=$true
        # Animation may hide the cursor, but its original state is restored
        # exactly when the response surface is finished or aborted.
        [Console]::CursorVisible=$false
    }catch{}

    Write-MessageFrameStatus '...  0.0s'
}

function Write-MessageFrameStatus([string]$Status){
    if(-not $script:ResponseFrameWaiting){return}
    $width=[Math]::Max(20,[int]$script:ResponseFrameWidth)
    $writeWidth=[Math]::Max(1,$width-1)
    $line=[string]$Status
    if([string]::IsNullOrWhiteSpace($line)){$line='...  0.0s'}
    if((Get-MiraCellWidth $line) -gt $writeWidth){
        $n=Get-MiraCellPrefixLength $line $writeWidth
        $line=$line.Substring(0,$n)
    }
    $line=$line.PadRight($writeWidth)

    try{
        # This is intentionally the old known-good live renderer:
        # repaint the current physical row with CR, never move vertically.
        # We leave one terminal column unwritten so the line cannot wrap.
        [Console]::Write("`r")
        Write-MiraFrameCells $line ([string]$script:MarkupTheme.MessageFrameRGB) ([ConsoleColor]$script:MarkupTheme.MessageFrameColor) $false
        [Console]::Write("`r")
        try{[Console]::Out.Flush()}catch{}
    }catch{
        # Animation failure must never produce another physical row.
    }
}

function Restore-MessageFrameCursor(){
    if($script:ResponseFrameCursorCaptured){
        try{[Console]::CursorVisible=$script:ResponseFrameCursorVisible}catch{}
    }
    $script:ResponseFrameCursorCaptured=$false
}

function Abort-MessageFrameWait(){
    if(-not $script:ResponseFrameWaiting){return}
    $width=[Math]::Max(20,[int]$script:ResponseFrameWidth)
    $writeWidth=[Math]::Max(1,$width-1)
    try{
        # The live row is also the current row. Clear it without vertical
        # cursor movement, exactly like the old stable animation path.
        [Console]::Write("`r")
        [Console]::Write(' '*$writeWidth)
        [Console]::Write("`r")
        try{[Console]::Out.Flush()}catch{}
    }catch{}
    $script:ResponseFrameWaiting=$false
    Restore-MessageFrameCursor
    $script:ResponseFrameLiveRow=-1
    $script:ResponseFrameWidth=0
}

function Begin-MessageFrame(){
    if(-not [bool]$script:MarkupTheme.MessageFrameEnabled){$script:MarkupFrameActive=$false;return}
    if($script:MarkupFrameActive){return}

    $width=[Math]::Max(20,(Width))
    $boxWidth=$width-1
    $script:MarkupFrameWidth=[Math]::Max(8,$boxWidth)
    $script:MarkupFrameActive=$true

    $status=[string]$script:LastStatusText
    if([string]::IsNullOrWhiteSpace($status)){
        $elapsed=[math]::Round(([int]$script:LastRequestElapsedMs)/1000,1)
        $frame=if([string]::IsNullOrWhiteSpace([string]$script:LastRequestFrame)){'... '}else{[string]$script:LastRequestFrame}
        $status=$frame+'  '+$elapsed+'s      ↑ '+[int]$script:LastPromptTokens+'  ↓ 0'+$(if($script:SessionActive){'  ●'}else{''})
    }

    $top=Get-MessageFrameTop $status $width

    # Normal v1 uses the proven CR repaint: replace the current
    # animation/status row in place, then advance exactly one line.
    # V2 retains its explicit captured-row path.
    try{
        if($script:ResponseFrameWaiting -and [int]$script:ResponseFrameLiveRow -ge 0){
            [Console]::SetCursorPosition(0,[int]$script:ResponseFrameLiveRow)
            Write-MiraFrameCells $top ([string]$script:MarkupTheme.MessageFrameRGB) ([ConsoleColor]$script:MarkupTheme.MessageFrameColor) $true
        }else{
            Write-Host ("`r" + (' ' * $width) + "`r" + $top) -ForegroundColor ([ConsoleColor]$script:MarkupTheme.MessageFrameColor)
        }
    }catch{
        $script:MarkupFrameActive=$false
        Abort-MessageFrameWait
        return
    }

    $script:ResponseFrameWaiting=$false
    $script:ResponseFrameLiveRow=-1
    $script:ResponseFrameWidth=0
}

function End-MessageFrame(){
    if($script:MarkupFrameActive){
        $width=[Math]::Max(20,(Width))
        $boxWidth=$width-1
        $bottom=[string]$script:MarkupTheme.MessageBottomLeft + ([string]$script:MarkupTheme.MessageHorizontal*[Math]::Max(0,$boxWidth-2)) + [string]$script:MarkupTheme.MessageBottomRight
        Write-MiraFrameCells $bottom ([string]$script:MarkupTheme.MessageFrameRGB) ([ConsoleColor]$script:MarkupTheme.MessageFrameColor) $true
    }

    $script:MarkupFrameActive=$false
    $script:MarkupFrameUsed=0
    $script:MarkupFrameWidth=0
    Restore-MessageFrameCursor
}

function Write-MarkupInline([string]$line,[bool]$ContinueLine=$false){
    if($null -eq $line){$line=''}
    if(-not $ContinueLine){Begin-MarkupLine}
    try{
        foreach($span in @(Parse-MiraInline $line)){
            $fg=Convert-MiraRgbToConsoleColor ([string]$span.Fg) ([ConsoleColor]::Gray)
            Add-MarkupSegment ([string]$span.Text) $fg
        }
    }catch{Add-MarkupSegment ([string]$line) ([ConsoleColor]::Gray)}
    if(-not $ContinueLine){End-MarkupLine}
}

function Write-JsonColored([string]$line){
    if($null -eq $line){$line=''}
    Begin-MarkupLine
    $pos=0;$plainStart=0
    while($pos -lt $line.Length){
        $end=$pos;$kind=''
        $ch=$line[$pos]
        if($ch -eq [char]34){
            $end=$pos+1;$escaped=$false
            while($end -lt $line.Length){
                $q=$line[$end]
                if($q -eq [char]34 -and -not $escaped){++$end;break}
                if($q -eq [char]92 -and -not $escaped){$escaped=$true}else{$escaped=$false}
                ++$end
            }
            $kind='string'
        }elseif(([char]::IsDigit($ch)) -or ($ch -eq '-' -and $pos+1 -lt $line.Length -and [char]::IsDigit($line[$pos+1]))){
            ++$end
            while($end -lt $line.Length){
                $n=[string]$line[$end]
                if('0123456789+-.eE'.IndexOf($n) -lt 0){break}
                ++$end
            }
            $kind='number'
        }else{
            $tail=$line.Substring($pos)
            if($tail.StartsWith('true')){$end=$pos+4;$kind='literal'}
            elseif($tail.StartsWith('false')){$end=$pos+5;$kind='literal'}
            elseif($tail.StartsWith('null')){$end=$pos+4;$kind='literal'}
            elseif('{}[],'.IndexOf($ch) -ge 0){$end=$pos+1;$kind='punct'}
        }
        if($kind -ne ''){
            if($pos -gt $plainStart){Add-MarkupSegment $line.Substring($plainStart,$pos-$plainStart) ([ConsoleColor]::Gray)}
            $fg=switch($kind){'string'{[ConsoleColor]::Yellow};'number'{[ConsoleColor]::Green};'literal'{[ConsoleColor]::Magenta};default{[ConsoleColor]::DarkCyan}}
            Add-MarkupSegment $line.Substring($pos,$end-$pos) $fg
            $pos=$end;$plainStart=$pos;continue
        }
        ++$pos
    }
    if($plainStart -lt $line.Length){Add-MarkupSegment $line.Substring($plainStart) ([ConsoleColor]::Gray)}
    End-MarkupLine
}

function Write-JsonColoredCodeLine([string]$line,[string]$background,[int]$fillWidth){
    # Kept as a compatibility wrapper. Code blocks no longer paint a full
    # background; they use the normal terminal background for clean framing.
    Write-MarkupPlainLine ([string]$line) ([ConsoleColor]$script:MarkupTheme.CodeTextColor)
}

function Normalize-CodeBlockLines([string[]]$lines){
    if($null -eq $lines){return @()}

    # Code fences are structural delimiters. Ignore only blank lines that sit
    # directly against the opening/closing fence. Preserve blank lines inside
    # the actual source code. This keeps the renderer unbreakable without
    # destroying intentional spacing in the code itself.
    $out=New-Object System.Collections.Generic.List[string]
    foreach($line in @($lines)){[void]$out.Add($(if($null -eq $line){''}else{[string]$line}))}

    while($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$out[0])){$out.RemoveAt(0)}
    while($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$out[$out.Count-1])){$out.RemoveAt($out.Count-1)}
    return @($out)
}

function Get-MarkupGraphicWidth([double]$percent,[int]$minimum){
    # Graphics and text share the same width captured by Begin-MessageFrame.
    # This keeps the renderer stable even if the terminal is resized mid-reply.
    $frameWidth=[Math]::Max(8,[int]$script:MarkupFrameWidth)
    $frameLimit=[Math]::Max(8,$frameWidth-2)
    $w=[Math]::Max($minimum,[int][Math]::Floor($frameWidth*$percent))
    return [Math]::Min($w,$frameLimit)
}

function Write-DotRule([int]$width,[ConsoleColor]$color){
    $n=[Math]::Max(0,$width)
    if($n -gt 0){Write-MarkupPlainLine (([string]$script:MarkupTheme.CodeRuleChar)*$n) $color}
    else{Write-MarkupPlainLine '' $color}
}

function Convert-LatexToUnicode([string]$Expression){
    if($null -eq $Expression){return ''}
    $s=[string]$Expression
    try{
        $s=$s -replace '\\left','' -replace '\\right',''
        $s=$s -replace '\\begin\{(pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|aligned)\}','' -replace '\\end\{(pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|aligned)\}',''
        $s=$s -replace '\\begin(pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|aligned)','' -replace '\\end(pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|aligned)',''
        $s=$s -replace '&','  '
        $s=$s -replace '\\\\','    '
        $s=$s -replace '\\infty','∞' -replace '\\int','∫' -replace '\\sum','∑' -replace '\\prod','∏'
        $s=[regex]::Replace($s,'\\sqrt\s*\{([^{}]*)\}',{param($m) ([char]0x221A).ToString()+$m.Groups[1].Value})
        $s=$s -replace '\\pi','π' -replace '\\lambda','λ' -replace '\\mu','μ' -replace '\\sigma','σ'
        $s=$s -replace '\\pm','±' -replace '\\mp','∓' -replace '\\partial','∂' -replace '\\nabla','∇' -replace '\\rho','ρ' -replace '\\varepsilon','ε' -replace '\\epsilon','ε' -replace '\\phi','φ' -replace '\\psi','ψ' -replace '\\omega','ω'
        $s=$s -replace '\\mathbf\s*\{([^{}]*)\}','$1' -replace '\\mathbf(?=[A-Za-z])',''
        $s=$s -replace '\\mathcal\s*\{([^{}]*)\}','$1' -replace '\\bar\s*\{([^{}]*)\}','$1'
        $s=$s -replace '\\alpha','α' -replace '\\beta','β' -replace '\\gamma','γ' -replace '\\delta','δ' -replace '\\theta','θ'
        $s=$s -replace '\\leq','≤' -replace '\\geq','≥' -replace '\\neq','≠' -replace '\\approx','≈' -replace '\\times','×'
        $s=$s -replace '\\cdot','·' -replace '\\to','→' -replace '\\rightarrow','→'
        $s=$s -replace '\\{','{' -replace '\\}','}' -replace '\\,',' ' -replace '\\;',' '
        $sup=@{'0'='⁰';'1'='¹';'2'='²';'3'='³';'4'='⁴';'5'='⁵';'6'='⁶';'7'='⁷';'8'='⁸';'9'='⁹';'+'='⁺';'-'='⁻';'='='⁼';'('='⁽';')'='⁾';'a'='ᵃ';'b'='ᵇ';'c'='ᶜ';'d'='ᵈ';'e'='ᵉ';'f'='ᶠ';'g'='ᵍ';'h'='ʰ';'i'='ⁱ';'j'='ʲ';'k'='ᵏ';'l'='ˡ';'m'='ᵐ';'n'='ⁿ';'o'='ᵒ';'p'='ᵖ';'r'='ʳ';'s'='ˢ';'t'='ᵗ';'u'='ᵘ';'v'='ᵛ';'w'='ʷ';'x'='ˣ';'y'='ʸ';'z'='ᶻ'}
        $sub=@{'0'='₀';'1'='₁';'2'='₂';'3'='₃';'4'='₄';'5'='₅';'6'='₆';'7'='₇';'8'='₈';'9'='₉';'+'='₊';'-'='₋';'='='₌';'('='₍';')'='₎';'a'='ₐ';'e'='ₑ';'h'='ₕ';'i'='ᵢ';'j'='ⱼ';'k'='ₖ';'l'='ₗ';'m'='ₘ';'n'='ₙ';'o'='ₒ';'p'='ₚ';'r'='ᵣ';'s'='ₛ';'t'='ₜ';'u'='ᵤ';'v'='ᵥ';'x'='ₓ'}
        $s=[regex]::Replace($s,'\^\{([^{}]*)\}',{param($m) -join @($m.Groups[1].Value.ToCharArray() | ForEach-Object { if($sup.ContainsKey([string]$_)){$sup[[string]$_]}else{[string]$_} })})
        $s=[regex]::Replace($s,'_\{([^{}]*)\}',{param($m) -join @($m.Groups[1].Value.ToCharArray() | ForEach-Object { if($sub.ContainsKey([string]$_)){$sub[[string]$_]}else{[string]$_} })})
        $s=[regex]::Replace($s,'\^([0-9A-Za-z+\-=\(\)])',{param($m) $c=$m.Groups[1].Value.ToLowerInvariant();if($sup.ContainsKey($c)){$sup[$c]}else{'^'+$m.Groups[1].Value}})
        $s=[regex]::Replace($s,'_([0-9A-Za-z+\-=\(\)])',{param($m) $c=$m.Groups[1].Value.ToLowerInvariant();if($sub.ContainsKey($c)){$sub[$c]}else{'_'+$m.Groups[1].Value}})
        $s=$s -replace '\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}','($1)/($2)'
        $s=$s -replace '\s{2,}',' '
        $s=$s.Replace('{','').Replace('}','')
    }catch{}
    return $s
}

function Write-MathBlock([string[]]$lines,[bool]$unfinished=$false){
    $out=New-Object System.Collections.Generic.List[string]
    foreach($line in @($lines)){[void]$out.Add($(if($null -eq $line){''}else{[string]$line}))}
    while($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$out[0])){$out.RemoveAt(0)}
    while($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$out[$out.Count-1])){$out.RemoveAt($out.Count-1)}

    $frame=[ConsoleColor]$script:MarkupTheme.MathFrameColor
    $labelFg=[ConsoleColor]$script:MarkupTheme.MathLanguageColor
    $textFg=[ConsoleColor]$script:MarkupTheme.MathTextColor
    $target=Get-MarkupGraphicWidth ([double]$script:MarkupTheme.MathRulePercent) ([int]$script:MarkupTheme.MathRuleMinWidth)
    $prefix=[string]$script:MarkupTheme.MathHeaderPrefix + 'MATH' + [string]$script:MarkupTheme.MathLanguageGap
    if((Get-MiraCellWidth $prefix) -gt $target){$prefix=$prefix.Substring(0,[Math]::Min($prefix.Length,(Get-MiraCellPrefixLength $prefix $target)))}
    $ruleCount=[Math]::Max(0,$target-$prefix.Length)

    Begin-MarkupLine
    Add-MarkupSegment ([string]$script:MarkupTheme.MathHeaderPrefix) $frame
    Add-MarkupSegment 'MATH' $labelFg
    Add-MarkupSegment ([string]$script:MarkupTheme.MathLanguageGap) $frame
    if($ruleCount -gt 0){Add-MarkupSegment (([string]$script:MarkupTheme.MathRuleChar)*$ruleCount) $frame}
    End-MarkupLine

    if($out.Count -eq 0){Write-MarkupPlainLine '' $textFg}
    else{foreach($line in @($out)){Write-MarkupPlainLine (Convert-LatexToUnicode ([string]$line)) $textFg}}

    Begin-MarkupLine
    $bottomRule=([string]$script:MarkupTheme.MathRuleChar)*$target
    Add-MarkupSegment $bottomRule $frame
    End-MarkupLine
}

function Write-CodeBlock([string[]]$lines,[string]$language='', [bool]$unfinished=$false){
    $lines=Normalize-CodeBlockLines $lines
    $frame=[ConsoleColor]$script:MarkupTheme.CodeFrameColor
    $langFg=[ConsoleColor]$script:MarkupTheme.CodeLanguageColor
    $textFg=[ConsoleColor]$script:MarkupTheme.CodeTextColor

    $langRaw=''+$language
    if(-not [bool]$script:MarkupTheme.CodeShowLanguage){$langRaw=''}
    $lang=$langRaw
    if(-not [string]::IsNullOrWhiteSpace($langRaw) -and $null -ne $script:MarkupTheme.CodeLanguageMap){
        $key=$langRaw.ToLowerInvariant()
        if($script:MarkupTheme.CodeLanguageMap.ContainsKey($key)){$lang=[string]$script:MarkupTheme.CodeLanguageMap[$key]}
    }
    if([string]::IsNullOrWhiteSpace($lang)){$lang='Code'}
    $lang=$lang.ToUpperInvariant()

    # IMPORTANT: the graphic has ONE exact width. The bottom rule uses that
    # same total width, so its right edge always matches the header's right edge.
    $target=Get-MarkupGraphicWidth ([double]$script:MarkupTheme.CodeRulePercent) ([int]$script:MarkupTheme.CodeRuleMinWidth)
    $prefix=[string]$script:MarkupTheme.CodeHeaderPrefix + $lang + [string]$script:MarkupTheme.CodeLanguageGap
    if((Get-MiraCellWidth $prefix) -ge $target){$prefix=$prefix.Substring(0,[Math]::Min($prefix.Length,(Get-MiraCellPrefixLength $prefix ([Math]::Max(0,$target-1)))))}
    $ruleWidth=[Math]::Max(0,$target-(Get-MiraCellWidth $prefix))

    Begin-MarkupLine
    Add-MarkupSegment ([string]$script:MarkupTheme.CodeHeaderPrefix) $frame
    if(-not [string]::IsNullOrWhiteSpace($lang)){Add-MarkupSegment $lang $langFg}
    Add-MarkupSegment ([string]$script:MarkupTheme.CodeLanguageGap) $frame
    if($ruleWidth -gt 0){Add-MarkupSegment (([string]$script:MarkupTheme.CodeRuleChar)*$ruleWidth) $frame}
    End-MarkupLine

    foreach($line in @($lines)){Write-MarkupPlainLine ([string]$line) $textFg}

    Begin-MarkupLine
    Add-MarkupSegment (([string]$script:MarkupTheme.CodeRuleChar)*$target) $frame
    End-MarkupLine
}

function Write-MarkupTable([string[]]$lines){
    if($null -eq $lines -or $lines.Count -lt 2){foreach($line in @($lines)){Write-MarkupInline ([string]$line)};return}

    $rows=@()
    $separators=@()
    foreach($line in @($lines)){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $clean=$line.Trim().Trim('|')
        $parts=@($clean.Split('|') | ForEach-Object {[string]$_.Trim()})
        if($parts.Count -eq 0){continue}
        $isSep=$true
        foreach($p in $parts){if($p -notmatch '^:?-{3,}:?$'){$isSep=$false;break}}
        $rows += ,$parts
        $separators += $isSep
    }
    if($rows.Count -lt 2){foreach($line in @($lines)){Write-MarkupInline ([string]$line)};return}

    $cols=0
    foreach($r in $rows){if($r.Count -gt $cols){$cols=$r.Count}}
    $widths=New-Object int[] $cols
    for($ri=0;$ri -lt $rows.Count;$ri++){
        for($i=0;$i -lt $rows[$ri].Count;$i++){
            $n=Get-MiraCellWidth ([string]$rows[$ri][$i])
            if($n -gt 36){$n=36}
            if($n -gt $widths[$i]){$widths[$i]=$n}
        }
    }

    for($ri=0;$ri -lt $rows.Count;$ri++){
        $r=$rows[$ri]
        $cells=@()
        for($i=0;$i -lt $cols;$i++){
            $v=if($i -lt $r.Count){[string]$r[$i]}else{''}
            if((Get-MiraCellWidth $v) -gt $widths[$i]){
                $cut=Get-MiraCellPrefixLength $v ([Math]::Max(0,$widths[$i]-1))
                $v=$v.Substring(0,$cut)+'…'
            }
            $cells += Pad-MiraCells $v $widths[$i]
        }
        if($separators[$ri]){
            $parts=@()
            foreach($w in $widths){$parts += ('-' * ($w+2))}
            Write-MarkupPlainLine ('  +'+($parts -join '+')+'+') ([ConsoleColor]::DarkGray)
        }else{
            $color=if($ri -eq 0){[ConsoleColor]::Cyan}else{[ConsoleColor]::Gray}
            Write-MarkupPlainLine ('  | '+($cells -join ' | ')+' |') $color
        }
    }
}

function Get-MiraHeadingBody([string]$Text){
    if($null -eq $Text){return $null}
    $s=[string]$Text;$i=0
    while($i -lt $s.Length -and $s[$i] -eq '#'){$i++}
    if($i -lt 1 -or $i -gt 6 -or $i -ge $s.Length){return $null}
    if(-not [char]::IsWhiteSpace($s[$i])){return $null}
    return $s.Substring($i).TrimStart()
}

function Get-MiraListParts([string]$Text){
    if($null -eq $Text){return $null}
    $s=[string]$Text;$i=0
    while($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])){++$i}
    $indent=$s.Substring(0,$i);$markerStart=$i
    if($i -lt $s.Length -and ($s[$i] -eq '-' -or $s[$i] -eq '*' -or $s[$i] -eq '+')){
        ++$i
        if($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])){
            while($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])){++$i}
            return [pscustomobject]@{Indent=$indent;Marker=$s.Substring($markerStart,$i-$markerStart);Body=$s.Substring($i)}
        }
        return $null
    }
    $digitsStart=$i
    while($i -lt $s.Length -and [char]::IsDigit($s[$i])){++$i}
    if($i -gt $digitsStart -and $i -lt $s.Length -and ($s[$i] -eq '.' -or $s[$i] -eq ')')){
        ++$i
        if($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])){
            while($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])){++$i}
            return [pscustomobject]@{Indent=$indent;Marker=$s.Substring($markerStart,$i-$markerStart);Body=$s.Substring($i)}
        }
    }
    return $null
}

function Test-MiraRuleLine([string]$Text){
    if($null -eq $Text){return $false}
    $s=([string]$Text).Trim();if($s.Length -lt 3){return $false}
    $glyph='';$count=0
    foreach($ch in $s.ToCharArray()){
        if([char]::IsWhiteSpace($ch)){continue}
        if($glyph -eq ''){$glyph=[string]$ch}
        if([string]$ch -ne $glyph){return $false}
        ++$count
    }
    return ($count -ge 3 -and ($glyph -eq '-' -or $glyph -eq '*' -or $glyph -eq '_'))
}

function Write-MarkupText([string]$Text){
    # Rendering is non-critical UI. It must never terminate the REPL.
    if([string]::IsNullOrEmpty($Text)){return}
    if(-not $script:UiRenderEnabled){
        Write-Host $Text
        return
    }
    Begin-MessageFrame
    try{
        $lines=@(([string]$Text).Replace("`r",'').Split([char]10))
        $inCode=$false
        $codeLang=''
        $codeBuffer=New-Object System.Collections.Generic.List[string]
        $inMath=$false
        $mathBuffer=New-Object System.Collections.Generic.List[string]
        $tableBuffer=New-Object System.Collections.Generic.List[string]

        foreach($line in $lines){
            try{
                $safeLine=[string]$line
                $trim=$safeLine.Trim()

                # CODE BLOCK STATE COMES FIRST. A literal $$ inside source code
                # must remain source code and can never open/close a math block.
                if($inCode){
                    if($safeLine.Trim().StartsWith('```')){
                        try{Write-CodeBlock @($codeBuffer) $codeLang $false}catch{foreach($t in @($codeBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $codeBuffer.Clear()
                        $inCode=$false
                        $codeLang=''
                    }else{
                        [void]$codeBuffer.Add($safeLine)
                    }
                    continue
                }

                # Standalone display-math fences. Support both $$ ... $$ and
                # LaTeX \\[ ... \\], which models commonly emit.
                if($inMath){
                    # Display math may close with $$ or \] on the same line as content.
                    if($safeLine.Trim() -eq '\]'){
                        try{Write-MathBlock @($mathBuffer) $false}catch{foreach($t in @($mathBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $mathBuffer.Clear()
                        $inMath=$false
                        continue
                    }

                    $close=$safeLine.IndexOf('$$')
                    if($close -ge 0){
                        $before=$safeLine.Substring(0,$close)
                        if(-not [string]::IsNullOrWhiteSpace($before)){[void]$mathBuffer.Add($before)}
                        try{Write-MathBlock @($mathBuffer) $false}catch{foreach($t in @($mathBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $mathBuffer.Clear()
                        $inMath=$false

                        $after=$safeLine.Substring($close+2)
                        if(-not [string]::IsNullOrWhiteSpace($after)){
                            try{Write-MarkupInline $after}catch{Write-MarkupPlainLine $after ([ConsoleColor]::Gray)}
                        }
                        continue
                    }

                    [void]$mathBuffer.Add($safeLine)
                    continue
                }

                # Display-math $$ may contain content on the opening line and may
                # close on a later line. This covers:
                # $$E = mc^2$$
                # $$A = \begin{pmatrix ... \end{pmatrix}$$
                if($safeLine.TrimStart().StartsWith('$')){
                    if($tableBuffer.Count -gt 0){
                        try{Write-MarkupTable @($tableBuffer)}catch{foreach($t in @($tableBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $tableBuffer.Clear()
                    }

                    $rest=[string]$safeLine.TrimStart().Substring(2)
                    $close=$rest.IndexOf('$$')
                    if($close -ge 0){
                        $inside=$rest.Substring(0,$close)
                        if([string]::IsNullOrWhiteSpace($inside)){
                            try{Write-MathBlock @() $false}catch{}
                        }else{
                            try{Write-MathBlock @($inside) $false}catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                        }
                        $after=$rest.Substring($close+2)
                        if(-not [string]::IsNullOrWhiteSpace($after)){
                            try{Write-MarkupInline $after}catch{Write-MarkupPlainLine $after ([ConsoleColor]::Gray)}
                        }
                    }else{
                        $inMath=$true
                        $mathBuffer.Clear()
                        if(-not [string]::IsNullOrWhiteSpace($rest)){[void]$mathBuffer.Add($rest)}
                    }
                    continue
                }

                # \[ ... \] display math, including content on the opening line.
                if($safeLine.TrimStart().StartsWith('\[')){
                    if($tableBuffer.Count -gt 0){
                        try{Write-MarkupTable @($tableBuffer)}catch{foreach($t in @($tableBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $tableBuffer.Clear()
                    }

                    $rest=[string]$safeLine.TrimStart().Substring(2)
                    $close=$rest.IndexOf('\]')
                    if($close -ge 0){
                        try{Write-MathBlock @([string]$rest.Substring(0,$close)) $false}catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                        $after=[string]$rest.Substring($close+2)
                        if(-not [string]::IsNullOrWhiteSpace($after)){
                            try{Write-MarkupInline $after}catch{Write-MarkupPlainLine $after ([ConsoleColor]::Gray)}
                        }
                    }else{
                        $inMath=$true
                        $mathBuffer.Clear()
                        if(-not [string]::IsNullOrWhiteSpace($rest)){[void]$mathBuffer.Add($rest)}
                    }
                    continue
                }

                # Markdown code fence MUST be a standalone line. This is the
                # highest-priority renderer rule when not already inside math.
                if($safeLine.Trim().StartsWith('```')){
                    if($tableBuffer.Count -gt 0){
                        try{Write-MarkupTable @($tableBuffer)}catch{foreach($t in @($tableBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $tableBuffer.Clear()
                    }
                    if(-not $inCode){
                        $inCode=$true
                        $codeLang=$trim.Substring(3).Trim().ToLowerInvariant()
                        $codeBuffer.Clear()
                    }else{
                        try{Write-CodeBlock @($codeBuffer) $codeLang $false}catch{foreach($t in @($codeBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                        $codeBuffer.Clear()
                        $inCode=$false
                        $codeLang=''
                    }
                    continue
                }

                if($trim.StartsWith('|') -and $trim.EndsWith('|')){
                    [void]$tableBuffer.Add($safeLine)
                    continue
                }
                if($tableBuffer.Count -gt 0){
                    try{Write-MarkupTable @($tableBuffer)}catch{foreach($t in @($tableBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
                    $tableBuffer.Clear()
                }

                $heading=Get-MiraHeadingBody $trim
                if($null -ne $heading){
                    try{Write-MarkupPlainLine $heading ([ConsoleColor]::Magenta)}catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                    continue
                }

                # Unordered / ordered lists: convert only the Markdown marker.
                # The actual text and all Unicode punctuation stay untouched.
                $listMatch=Get-MiraListParts $safeLine
                if($null -ne $listMatch){
                    try{
                        $indent=[string]$listMatch.Indent
                        $marker=[string]$listMatch.Marker
                        $body=[string]$listMatch.Body
                        Begin-MarkupLine
                        if($marker.Length -gt 0 -and ($marker[0] -eq '-' -or $marker[0] -eq '*' -or $marker[0] -eq '+')){
                            Add-MarkupSegment ($indent+'• ') ([ConsoleColor]::Yellow)
                        }else{
                            Add-MarkupSegment ($indent+$marker) ([ConsoleColor]::Yellow)
                        }
                        Write-MarkupInline $body $true
                        End-MarkupLine
                    }catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                    continue
                }
                if($trim.StartsWith('>')){
                    try{
                        $quote=$trim.Substring(1).TrimStart()
                        Begin-MarkupLine
                        Add-MarkupSegment '│ ' ([ConsoleColor]::DarkGray)
                        Write-MarkupInline $quote $true
                        End-MarkupLine
                    }catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                    continue
                }

                # Only color complete JSON-looking lines; invalid JSON-like text is left alone.
                if(($trim.StartsWith('{') -and $trim.EndsWith('}')) -or ($trim.StartsWith('[') -and $trim.EndsWith(']'))){
                    try{Write-JsonColored $safeLine}catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
                    continue
                }

                try{Write-MarkupInline $safeLine}catch{Write-MarkupPlainLine $safeLine ([ConsoleColor]::Gray)}
            }catch{
                try{Write-MarkupPlainLine ([string]$line) ([ConsoleColor]::Gray)}catch{}
            }
        }

        if($inCode){
            try{Write-CodeBlock @($codeBuffer) $codeLang $true}catch{foreach($t in @($codeBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
        }
        if($inMath){
            try{Write-MathBlock @($mathBuffer) $true}catch{foreach($t in @($mathBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
        }
        if($tableBuffer.Count -gt 0){
            try{Write-MarkupTable @($tableBuffer)}catch{foreach($t in @($tableBuffer)){Write-MarkupPlainLine ([string]$t) ([ConsoleColor]::Gray)}}
        }
    }catch{
        try{
            foreach($fallbackLine in @(([string]$Text).Replace("`r",'').Split([char]10))){Write-MarkupPlainLine ([string]$fallbackLine) ([ConsoleColor]::Gray)}
        }catch{}
    }finally{
        End-MessageFrame
    }
}

function Show-Response($response,$providerType){
    $tokensIn=0
    $tokensOut=0
    if($providerType -eq 'gemini'){
        if($null -ne $response.usageMetadata){
            if($null -ne $response.usageMetadata.promptTokenCount){$tokensIn=[int]$response.usageMetadata.promptTokenCount}
            if($null -ne $response.usageMetadata.candidatesTokenCount){$tokensOut=[int]$response.usageMetadata.candidatesTokenCount}
        }
        $tokenString="[Tokens: $tokensIn in, $tokensOut out]"
        $candidates=@($response.candidates)
        if($candidates.Count -eq 0){
            $reply='[NO CANDIDATES RETURNED]'
            if($null -ne $response.promptFeedback -and $null -ne $response.promptFeedback.safetyRatings){
                foreach($rating in $response.promptFeedback.safetyRatings){$reply += "`n$($rating.category): $($rating.probability)"}
            }
            return [pscustomobject]@{Text=$reply;Display="$tokenString`n$reply";FinishReason='';PromptTokens=$tokensIn;CompletionTokens=$tokensOut}
        }
        $candidate=$candidates[0]
        $reply=''
        if($null -ne $candidate.content -and $null -ne $candidate.content.parts){$reply=(@($candidate.content.parts | ForEach-Object {[string]$_.text}) -join '')}
        $finish=[string]$candidate.finishReason
        if($finish -eq 'MAX_TOKENS'){$reply += "`n`n[WARNING: Response truncated due to token limit]"}
        elseif($finish -eq 'SAFETY'){
            $reply='[BLOCKED BY SAFETY FILTERS]'
            if($null -ne $candidate.safetyRatings){foreach($rating in $candidate.safetyRatings){$reply += "`n$($rating.category): $($rating.probability)"}}
        }
        return [pscustomobject]@{Text=$reply;Display="$tokenString`n$reply";FinishReason=$finish;PromptTokens=$tokensIn;CompletionTokens=$tokensOut}
    }

    if($null -ne $response.usage){
        if($null -ne $response.usage.prompt_tokens){$tokensIn=[int]$response.usage.prompt_tokens}
        if($null -ne $response.usage.completion_tokens){$tokensOut=[int]$response.usage.completion_tokens}
    }
    $tokenString="[Tokens: $tokensIn in, $tokensOut out]"
    $choices=@($response.choices)
    if($choices.Count -eq 0){
        $reply='[NO CHOICES RETURNED]'
        return [pscustomobject]@{Text=$reply;Display="$tokenString`n$reply";FinishReason='';PromptTokens=$tokensIn;CompletionTokens=$tokensOut}
    }
    $choice=$choices[0]
    $reply=''
    $reasoning=''
    $reasoningDetails=@()
    if($null -ne $choice.message){
        $content=$choice.message.content
        if($content -is [string]){
            $reply=[string]$content
        }
        elseif($null -ne $content){
            # Some compatible providers return content as an array of typed parts.
            $chunks=New-Object System.Collections.Generic.List[string]
            foreach($part in @($content)){
                if($part -is [string]){[void]$chunks.Add([string]$part);continue}
                if($null -ne $part.text){[void]$chunks.Add([string]$part.text);continue}
                if($null -ne $part.content -and $part.content -is [string]){[void]$chunks.Add([string]$part.content)}
            }
            $reply=$chunks -join ''
        }
        if($null -ne $choice.message.reasoning){$reasoning=[string]$choice.message.reasoning}
        if($null -ne $choice.message.reasoning_details){$reasoningDetails=@($choice.message.reasoning_details)}
    }
    $finish=[string]$choice.finish_reason
    if($finish -eq 'length'){$reply += "`n`n[WARNING: Response truncated due to token limit]"}
    return [pscustomobject]@{Text=$reply;Reasoning=$reasoning;ReasoningDetails=$reasoningDetails;Display="$tokenString`n$reply";FinishReason=$finish;PromptTokens=$tokensIn;CompletionTokens=$tokensOut}
}

function Invoke-Provider($text,$parts=$null){
    $provider=Get-Provider $script:CurrentProviderName
    if($null -eq $provider){W ('[provider error] unknown provider: '+$script:CurrentProviderName) Red;return $false}
    if($script:SessionActive -and $script:LastPromptTokens -ge $script:CompressThreshold){[void](Compress-Session)}

    $messages=@($script:Conversation|ForEach-Object{$_})
    # Initialize parts explicitly; assigning a new property to a PSObject fails in PS 5.1.
    $user=[pscustomobject]@{role='user';text=[string]$text;parts=$null}
    if($null -ne $parts){$user.parts=@($parts)}
    $messages+=$user
    $type=[string]$provider.type
    if($type -eq 'gemini'){$payload=Build-GeminiPayload $messages $script:SessionSummary}
    elseif($type -eq 'openai-compatible'){$payload=Build-OpenAICompatiblePayload $provider $messages $script:CurrentModel $script:SessionSummary}
    else{W ('[provider error] unsupported type: '+$type) Red;return $false}

    $jsonPayload=$payload|ConvertTo-Json -Depth 40
    $script:LastRequest=$jsonPayload
    if($script:DryRunMode){
        W '[dry-run] no request sent' Yellow
        W ('provider : '+$script:CurrentProviderName) Gray
        W ('model    : '+$script:CurrentModel) Gray
        W ''
        W $jsonPayload Gray
        $script:LastText=$jsonPayload
        return $true
    }

    try{
        if($type -eq 'openai-compatible' -and $script:StreamResponses){
            try{
                $result=Send-OpenAICompatibleStream $provider $script:CurrentModel $payload
            }catch{
                W ('[stream error] '+$_.Exception.Message) Yellow
                W '[stream fallback] retrying non-stream request...' DarkGray
                $payload.stream=$false
                $response=Send-ProviderPayload $provider $script:CurrentModel $payload
                $result=Show-Response $response $type
            }
        }else{
            $response=Send-ProviderPayload $provider $script:CurrentModel $payload
            $result=Show-Response $response $type
        }

        if($type -eq 'openai-compatible' -and $script:ShowReasoning -and $result.Reasoning){
            W '[THOUGHT]' DarkGray
            W ([string]$result.Reasoning) DarkGray
        }
    }catch{
        $msg=$_.Exception.Message
        Abort-MessageFrameWait
        if($msg -eq 'Request cancelled.'){return $false}
        if($_.ErrorDetails -and $_.ErrorDetails.Message){$msg+=[Environment]::NewLine+$_.ErrorDetails.Message}
        W ('[API error] '+$msg) Red
        return $false
    }

    $script:LastPromptTokens=0
    if($null -ne $result.PromptTokens){$script:LastPromptTokens=[int]$result.PromptTokens}
    if($type -eq 'gemini' -and
       $script:LastPromptTokens -eq 0 -and
       $null -ne $response -and
       $null -ne $response.usageMetadata -and
       $null -ne $response.usageMetadata.promptTokenCount){
        $script:LastPromptTokens=[int]$response.usageMetadata.promptTokenCount
    }

    $script:LastText=$result.Text

    # Final status is prepared before the renderer converts the reserved live
    # row into the top frame. No second status row is created.
    $elapsedSec=[math]::Round(([int]$script:LastRequestElapsedMs)/1000,1)
    $statusFrame=if([string]::IsNullOrEmpty([string]$script:LastRequestFrame)){'... '}else{[string]$script:LastRequestFrame}
    $tokensIn=if($null -ne $result.PromptTokens){[int]$result.PromptTokens}else{0}
    $tokensOut=if($null -ne $result.CompletionTokens){[int]$result.CompletionTokens}else{0}
    $bullet=if($script:SessionActive){'  ●'}else{''}
    $script:LastStatusText=$statusFrame+'  '+$elapsedSec+'s      ↑ '+$tokensIn+'  ↓ '+$tokensOut+$bullet
    $script:LastStatusHasBullet=$script:SessionActive

    if($type -eq 'gemini' -or -not $script:StreamResponses){
        try{
            Write-MarkupText ([string]$result.Text)
        }catch{
            try{ W '[markup warning] raw response fallback' Yellow }catch{}
            try{ Write-Host ([string]$result.Text) -ForegroundColor Gray }catch{}
            if($script:ResponseFrameWaiting){Abort-MessageFrameWait}
        }
    }

    # Self-learning used.list: only remember models that produced a real
    # non-empty text answer through Mira's normal chat path. Model selection
    # itself never writes to used.list, so failed/TTS/non-text models stay out.
    $ok=($result.FinishReason -ne 'SAFETY') -and
        -not [string]::IsNullOrEmpty([string]$result.Text) -and
        ([string]$result.Text -notmatch '^\[NO CHOICES RETURNED\]$') -and
        ([string]$result.Text -notmatch '^\[NO CANDIDATES RETURNED\]$')
    if($ok){Add-UsedModel $script:CurrentProviderName $script:CurrentModel}
    if($ok -and $script:SessionActive){[void]$script:Conversation.Add($user);Add-Message 'assistant' $result.Text $result.ReasoningDetails}
    return $ok
}

function Show-ApiKeyStatus(){
    W '' DarkCyan
    W 'API key status (safe; never prints secrets):' Cyan
    $names=@('GEMINI_API_KEY','OPENROUTER_API_KEY','GROQ_API_KEY','OPENAI_API_KEY','DEEPSEEK_API_KEY','MISTRAL_API_KEY','TOGETHER_API_KEY','FIREWORKS_API_KEY','XAI_API_KEY','PERPLEXITY_API_KEY')
    foreach($name in $names){
        $v=Get-Item ('Env:'+ $name) -ErrorAction SilentlyContinue
        if($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v.Value)){
            W ($name+' = <empty>') DarkGray
        }else{
            W ($name+' = <set>') DarkGray
        }
    }
}

function Help(){
    W '' DarkCyan; W 'MIRA-TUI SLIM PROVIDERS / IO TEST' Magenta; W ''
    W 'Enter            submit' Gray; W '.history         show recent command history' Gray; W 'Ctrl+J/Ctrl+Enter insert newline' Gray; W 'Up/Down          history / prefix history' Gray; W 'Ctrl+P            previous prefix match' Gray; W 'PageUp/PageDown   history prefix search' Gray; W 'Tab              completion' Gray; W 'Ctrl+C            clear line' Gray; W 'Ctrl+L            redraw window' Gray
    Show-ApiKeyStatus
    W '' DarkCyan; W ('COMMANDS:  '+($script:Commands -join '  ')) Gray; W '  .file <path>               send text/image file to model' DarkGray; W '  .read <path>                read text file and send to model' DarkGray; W '  .shot [path]               send clipboard/image to model' DarkGray; W '  .diff <a> <b>              send file diff to model' DarkGray; W '  .model <provider:model>   switch live provider/model; successful text replies learn into used.list' DarkGray; W '  .models                    show cached text-chat models' DarkGray; W '  .models <Tab>              refresh only providers with a non-empty API key env' DarkGray; W '  .models test               pre-filter fetched models, probe API, learn successful text models into used.list' DarkGray; W '  .providers                 built-in provider registry' DarkGray; W '  .session [name]            begin RAM-only context session' DarkGray; W '  .empty session             clear active session' DarkGray; W '  .compress session          summarize old session messages' DarkGray; W '  .delete session             leave session; context is discarded' DarkGray; W '  .request                   show useful summary of last JSON request' DarkGray; W '  .request json|raw           show raw last JSON request' DarkGray; W '  .save [name]               save each fenced snippet as its own source file' DarkGray; W '  .copy                      copy the whole raw last message to clipboard' DarkGray; W '  .grab [name.txt]           save the whole raw last message to TXT' DarkGray; W '  .ui on|off                 enable/disable Markdown renderer' DarkGray; W '  .stream / .stream on|off  live OpenAI-compatible streaming' DarkGray; W '  .reasoning on|off          enable provider reasoning output' DarkGray; W ''
}

function Add-Message($role,$text,$reasoningDetails=$null,$parts=$null){
    # Keep optional fields present so PowerShell 5.1 can assign them later.
    $m=[pscustomobject]@{role=$role;text=[string]$text;reasoning_details=$null;parts=$null}
    if($null -ne $reasoningDetails){$rd=@($reasoningDetails);if($rd.Count -gt 0){$m.reasoning_details=$rd}}
    if($null -ne $parts){$m.parts=@($parts)}
    [void]$script:Conversation.Add($m)
}

function Get-SaveExtension([string]$language){
    switch(([string]$language).Trim().ToLowerInvariant()){
        'powershell' {'ps1'} 'ps1' {'ps1'} 'pwsh' {'ps1'} 'ps' {'ps1'}
        'bash' {'sh'} 'sh' {'sh'}
        'python' {'py'} 'py' {'py'}
        'javascript' {'js'} 'js' {'js'} 'typescript' {'ts'} 'ts' {'ts'}
        'json' {'json'} 'xml' {'xml'} 'html' {'html'} 'css' {'css'}
        'yaml' {'yaml'} 'yml' {'yml'} 'sql' {'sql'} 'csharp' {'cs'} 'cs' {'cs'}
        'cpp' {'cpp'} 'c++' {'cpp'} 'c' {'c'} 'java' {'java'} 'rust' {'rs'} 'go' {'go'} 'lua' {'lua'}
        'markdown' {'md'} 'md' {'md'} 'text' {'txt'} 'txt' {'txt'} default { if($language){$language.TrimStart('.')}else{'txt'} }
    }
}

function Get-UniqueSavePath([string]$baseName,[string]$extension){
    $safe=[IO.Path]::GetFileNameWithoutExtension([string]$baseName)
    if([string]::IsNullOrWhiteSpace($safe)){$safe='mira'}
    $ext=[string]$extension
    if(-not $ext.StartsWith('.')){$ext='.'+$ext}
    $path=Join-Path (Get-Location).Path ($safe+$ext)
    $n=1
    while(Test-Path -LiteralPath $path){
        $path=Join-Path (Get-Location).Path ($safe+'_'+$n+$ext)
        ++$n
    }
    return $path
}

function Save-LastMessage([string]$Text,[string]$Name=''){
    if([string]::IsNullOrWhiteSpace($Text)){W '[No output to save]' Yellow;return}

    # Markdown fence parser: one opening ``` line, any body, one closing ``` line.
    # No blank line is required after the opening fence.
    $pattern='(?ms)^[ \t]*```([^\r\n`]*)[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*(?:\r?\n|$)'
    $matches=[regex]::Matches($Text,$pattern)

    if($matches.Count -gt 0){
        $saved=0
        foreach($m in $matches){
            $lang=$m.Groups[1].Value.Trim()
            $body=$m.Groups[2].Value.TrimEnd([char]13,[char]10)
            $ext=Get-SaveExtension $lang
            if([string]::IsNullOrWhiteSpace($ext)){$ext='txt'}

            if(-not [string]::IsNullOrWhiteSpace($Name) -and $matches.Count -eq 1){
                $base=$Name
            }elseif(-not [string]::IsNullOrWhiteSpace($Name)){
                $label=if($lang){$lang.ToLowerInvariant()}else{'text'}
                $base=$Name+'_'+('{0:D2}' -f ($saved+1))+'_'+$label
            }else{
                $label=if($lang){$lang.ToLowerInvariant()}else{'text'}
                $base='mira_{0:D2}_{1}' -f ($saved+1),$label
            }

            $path=Get-UniqueSavePath $base ('.'+$ext)
            [IO.File]::WriteAllText($path,$body,(New-Object System.Text.UTF8Encoding($true)))
            W ('[Saved: '+(Split-Path -Leaf $path)+']') Green
            ++$saved
        }
        return
    }

    # No fenced code: keep the historical behavior and save the whole response.
    $base=if([string]::IsNullOrWhiteSpace($Name)){'mira_message'}else{$Name}
    if([IO.Path]::GetExtension($base)){
        $ext=[IO.Path]::GetExtension($base)
        $base=[IO.Path]::GetFileNameWithoutExtension($base)
    }else{$ext='.txt'}
    $path=Get-UniqueSavePath $base $ext
    [IO.File]::WriteAllText($path,$Text,(New-Object System.Text.UTF8Encoding($true)))
    W ('[Saved: '+(Split-Path -Leaf $path)+']') Green
}

function Set-TuiClipboardText([string]$Text){
    if([string]::IsNullOrEmpty($Text)){throw 'no output to copy'}
    try{
        Set-Clipboard -Value $Text -ErrorAction Stop
        return
    }catch{}

    try{
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Clipboard]::SetText($Text)
        return
    }catch{
        throw ('clipboard unavailable: '+$_.Exception.Message)
    }
}

function Copy-LastMessage([string]$Text){
    try{
        Set-TuiClipboardText $Text
        W ('[copied '+$Text.Length+' chars]') Green
    }catch{W ('[copy error] '+$_.Exception.Message) Red}
}

function Grab-LastMessage([string]$Text,[string]$Name=''){
    if([string]::IsNullOrWhiteSpace($Text)){W '[No output to grab]' Yellow;return}
    try{
        $base=if([string]::IsNullOrWhiteSpace($Name)){'mira_'+(Get-Date -Format 'yyyyMMdd_HHmmss')}else{$Name}
        if(-not [IO.Path]::GetExtension($base)){$base += '.txt'}
        else{$base=[IO.Path]::GetFileNameWithoutExtension($base)+[IO.Path]::GetExtension($base)}
        $ext=[IO.Path]::GetExtension($base)
        $stem=[IO.Path]::GetFileNameWithoutExtension($base)
        $path=Get-UniqueSavePath $stem $ext
        [IO.File]::WriteAllText($path,$Text,(New-Object System.Text.UTF8Encoding($true)))
        W ('[Grabbed: '+(Split-Path -Leaf $path)+']') Green
    }catch{W ('[grab error] '+$_.Exception.Message) Red}
}
function Show-CliArgumentStatus(){
    W '[CLI arguments]' Cyan
    W '  implemented      -d, --dry-run' Gray
    W '  not implemented  -m, --model <name>  •  -e, --execute  •  -h, --help  •  --' DarkGray
}

function Show-Request([switch]$Raw){
    if([string]::IsNullOrEmpty($script:LastRequest)){W '[no request sent yet]' Yellow;return}
    if($Raw){W $script:LastRequest Gray;return}

    $obj=$null
    try{$obj=$script:LastRequest | ConvertFrom-Json -ErrorAction Stop}catch{}
    W '[last request]' Cyan
    W ('provider : '+$script:CurrentProviderName) Gray
    W ('model    : '+$script:CurrentModel) Gray
    W ('bytes    : '+([Text.Encoding]::UTF8.GetByteCount([string]$script:LastRequest))) Gray
    W ('session  : '+$(if($script:SessionActive){$script:SessionName}else{'off'})) Gray
    if($null -ne $obj){
        $keys=@($obj.PSObject.Properties | ForEach-Object {$_.Name})
        if($keys.Count -gt 0){W ('fields   : '+($keys -join ', ')) DarkGray}
        if($null -ne $obj.contents){W ('contents : '+@($obj.contents).Count+' item(s)') DarkGray}
        elseif($null -ne $obj.messages){W ('messages : '+@($obj.messages).Count+' item(s)') DarkGray}
        if($null -ne $obj.generationConfig){
            $cfg=@($obj.generationConfig.PSObject.Properties | ForEach-Object {$_.Name})
            if($cfg.Count -gt 0){W ('config   : '+($cfg -join ', ')) DarkGray}
        }
        if($null -ne $obj.tools){W ('tools    : '+@($obj.tools).Count+' item(s)') DarkGray}
    }
    W 'use .request json for the raw JSON payload' DarkGray
}

function Run-Local($line){
    $cmd=$line.Substring(1).Trim(); if(!$cmd){Help;return}
    try{ $o=Invoke-Expression $cmd 2>&1|Out-String -Width 4096; $script:LastText=$o.TrimEnd(); if($script:LastText){W $script:LastText Gray}else{W '' Gray} }
    catch{W ('[local error] '+$_.Exception.Message) Red}
}

function Get-FileMimeType([string]$path){
    switch(([IO.Path]::GetExtension($path)).ToLowerInvariant()){
        '.png'  {'image/png'} '.jpg'  {'image/jpeg'} '.jpeg' {'image/jpeg'} '.gif' {'image/gif'} '.webp' {'image/webp'} '.bmp' {'image/bmp'} default {'application/octet-stream'}
    }
}

function New-TextPart([string]$text){return [pscustomobject]@{kind='text';text=[string]$text}}
function New-ImagePart([string]$path){$bytes=[IO.File]::ReadAllBytes($path);return [pscustomobject]@{kind='image';mimeType=(Get-FileMimeType $path);data=[Convert]::ToBase64String($bytes)}}

function Send-FileToProvider([string]$path,[bool]$ForceText=$false){
    if([string]::IsNullOrWhiteSpace($path)){W '[Usage: .file <path>]' Yellow;return}
    try{
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer){throw 'path is a directory'}
        $mime=Get-FileMimeType $item.FullName
        if(-not $ForceText -and $mime -ne 'application/octet-stream'){
            if($item.Length -gt 8388608){throw 'image is larger than 8 MB for this test build'}
            $label='[IMAGE FILE: '+$item.FullName+']'
            $parts=@([pscustomobject]@{kind='text';text=$label},(New-ImagePart $item.FullName))
            [void](Invoke-Provider $label $parts);return
        }
        if($item.Length -gt 2097152){throw 'text file is larger than 2 MB for this test build'}
        $text=[IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8)
        $payloadText='[FILE: '+$item.FullName+']'+"`n`n"+$text
        [void](Invoke-Provider $payloadText @(New-TextPart $payloadText))
    }catch{W ('[file send error] '+$_.Exception.Message) Red}
}

function Send-TextFileToProvider([string]$path){
    if([string]::IsNullOrWhiteSpace($path)){W '[Usage: .read <path>]' Yellow;return}
    try{
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer){throw 'path is a directory'}
        if($item.Length -gt 2097152){throw 'text file is larger than 2 MB for this test build'}
        $text=[IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8)
        $payloadText='[TEXT: '+$item.FullName+']'+"`n`n"+$text
        [void](Invoke-Provider $payloadText @(New-TextPart $payloadText))
    }catch{W ('[read send error] '+$_.Exception.Message) Red}
}

function New-SimpleDiff([string]$a,[string]$b){
    $left=@([IO.File]::ReadAllLines($a,[Text.Encoding]::UTF8));$right=@([IO.File]::ReadAllLines($b,[Text.Encoding]::UTF8));$sb=New-Object Text.StringBuilder
    [void]$sb.AppendLine(('--- '+$a));[void]$sb.AppendLine(('+++ '+$b))
    $max=[Math]::Max($left.Count,$right.Count)
    for($i=0;$i -lt $max;++$i){
        if($i -lt $left.Count -and $i -lt $right.Count -and $left[$i] -eq $right[$i]){[void]$sb.AppendLine('  '+$left[$i]);continue}
        if($i -lt $left.Count){[void]$sb.AppendLine('- '+$left[$i])}
        if($i -lt $right.Count){[void]$sb.AppendLine('+ '+$right[$i])}
    }
    return $sb.ToString().TrimEnd()
}

function Send-DiffToProvider([string]$a,[string]$b){
    try{
        $x=Get-Item -LiteralPath $a -Force -ErrorAction Stop;$y=Get-Item -LiteralPath $b -Force -ErrorAction Stop
        if($x.PSIsContainer -or $y.PSIsContainer){throw 'both paths must be files'}
        $diff=New-SimpleDiff $x.FullName $y.FullName
        $payloadText='[DIFF]'+"`n`n"+$diff
        [void](Invoke-Provider $payloadText @(New-TextPart $payloadText))
    }catch{W ('[diff send error] '+$_.Exception.Message) Red}
}

function Send-ShotToProvider([string]$path=''){
    try{
        $mime='image/png'
        if([string]::IsNullOrWhiteSpace($path)){
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $img=[System.Windows.Forms.Clipboard]::GetImage();if($null -eq $img){throw 'no image found on clipboard'}
            $stream=New-Object IO.MemoryStream
            try{$img.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png);$bytes=$stream.ToArray()}finally{$stream.Dispose();$img.Dispose()}
            $label='[CLIPBOARD SCREENSHOT]'
        }else{
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($item.PSIsContainer){throw 'path is a directory'}
            $mime=Get-FileMimeType $item.FullName;if($mime -eq 'application/octet-stream'){throw 'unsupported image type'}
            $bytes=[IO.File]::ReadAllBytes($item.FullName);$label='[IMAGE: '+$item.FullName+']'
        }
        if($bytes.Length -gt 8388608){throw 'image is larger than 8 MB for this test build'}
        $parts=@([pscustomobject]@{kind='text';text=$label},[pscustomobject]@{kind='image';mimeType=$mime;data=[Convert]::ToBase64String($bytes)})
        [void](Invoke-Provider $label $parts)
    }catch{W ('[shot send error] '+$_.Exception.Message) Red}
}

function Handle-UiCommand([string]$t){
    $x=$t.Trim().ToLowerInvariant()
    if($x -eq '.ui'){
        W ('[ui] '+$(if($script:UiRenderEnabled){'on'}else{'off'})) Cyan
        return $true
    }
    if($x -eq '.ui on' -or $x -eq '.ui off'){
        $script:UiRenderEnabled=($x -eq '.ui on')
        W ('[ui '+$(if($script:UiRenderEnabled){'on]'}else{'off]'})) Cyan
        return $true
    }
    return $false
}

function Handle($line){
    $t=$line.Trim()
    if($t -in @('.q',':q',':wq','quit')){$script:Running=$false;return}
    if($t -eq '.help'){Help;return}
    if($t -eq '.clear'){Clear-Host;return}
    if($t -eq '.clear history'){$script:History.Clear();$script:HistIndex=-1;$script:HistDraft='';Reset-TuiHistorySearch;Save-TuiHistory;W '[history cleared]' DarkGray;return}
    if($t -eq '.history persist on'){Set-TuiHistoryPersistence $true;return}
    if($t -eq '.history persist off'){Set-TuiHistoryPersistence $false;return}
    if($t -eq '.history'){Show-TuiHistory;return}
    if($t.StartsWith('!')){Run-Local $t;return}
    if($t -eq '.file' -or $t.StartsWith('.file ')){Send-FileToProvider (($t.Substring(5)).Trim());return}
    if($t -eq '.read' -or $t.StartsWith('.read ')){Send-TextFileToProvider (($t.Substring(5)).Trim());return}
    if($t -eq '.shot' -or $t.StartsWith('.shot ')){Send-ShotToProvider (($t.Substring(5)).Trim());return}
    if($t -eq '.model'){Show-Model;return}
    if($t.StartsWith('.model ')){[void](Set-ModelSelection ($t.Substring(7)));return}
    if($t -eq '.models test'){Test-CachedModels;return}
    if($t -eq '.models'){Show-Models;return}
    if($t -eq '.providers'){Show-Providers;return}
    if($t -eq '.ui' -or $t -eq '.ui on' -or $t -eq '.ui off'){
        if(Handle-UiCommand $t){return}
    }
    if($t -eq '.request'){Show-Request;return}
    if($t -eq '.request json' -or $t -eq '.request raw'){Show-Request -Raw;return}
    if($t -eq '.save' -or $t.StartsWith('.save ')){Save-LastMessage $script:LastText (($t.Substring(5)).Trim());return}
    if($t -eq '.copy'){Copy-LastMessage $script:LastText;return}
    if($t -eq '.grab' -or $t.StartsWith('.grab ')){Grab-LastMessage $script:LastText (($t.Substring(5)).Trim());return}
    if($t -eq '.stream'){W ('[stream] '+$(if($script:StreamResponses){'on'}else{'off'})+' (OpenAI-compatible)') Cyan;return}
    if($t -in @('.stream on','.stream off')){$script:StreamResponses=($t -eq '.stream on');W ('[stream '+$(if($script:StreamResponses){'on'}else{'off'})+']') Cyan;return}
    if($t -eq '.reasoning'){W ('[reasoning] '+$(if($script:ShowReasoning){'on'}else{'off'})) Cyan;return}
    if($t -in @('.reasoning on','.reasoning off')){$script:ShowReasoning=($t -eq '.reasoning on');W ('[reasoning '+$(if($script:ShowReasoning){'on'}else{'off'})+']') Cyan;return}
    if($t -eq '.session'){Start-Session '';return}
    if($t.StartsWith('.session ')){Start-Session ($t.Substring(9));return}
    if($t -eq '.empty session'){Empty-Session;return}
    if($t -eq '.compress session'){[void](Compress-Session);return}
    if($t -eq '.delete session'){Exit-Session;return}
    if($t.StartsWith('.diff ')){$a=$t.Substring(6).Trim() -split '\s+',2;if($a.Count -lt 2){W '[Usage: .diff <a> <b>]' Yellow;return};Send-DiffToProvider $a[0] $a[1];return}
    [void](Invoke-Provider $line)
}

function Read-Line {
    param([int]$PromptRow)
    $buffer=''
    $cursor=0
    $historyPos=$script:History.Count
    $draft=''
    $historySearch=$false
    $historyPrefix=''
    $historySearchPos=$script:History.Count
    $killRing=''
    $undoStack=New-Object System.Collections.Stack
    [Console]::Write((Get-TuiPrompt 0))

    while($true){
        $key=Read-Key
        $ctrl=(($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
        $alt=(($key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0)
        $shift=(($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0)
        $isCtrlEnter=($key.Key -eq [ConsoleKey]::Enter -and $ctrl)
        $isCtrlJ=(($key.Key -eq [ConsoleKey]::J -and $ctrl) -or ([int][char]$key.KeyChar -eq 10))
        $isCtrlUnderscore=(($ctrl -and $shift -and $key.Key -eq [ConsoleKey]::OemMinus) -or ($ctrl -and ([string]$key.KeyChar -eq '_')))

        $SaveUndo = {
            param([string]$oldBuffer,[int]$oldCursor)
            if($undoStack.Count -eq 0 -or $undoStack.Peek().Buffer -ne $oldBuffer -or $undoStack.Peek().Cursor -ne $oldCursor){
                [void]$undoStack.Push([pscustomobject]@{Buffer=$oldBuffer;Cursor=$oldCursor})
                while($undoStack.Count -gt 100){[void]$undoStack.Pop()}
            }
        }
        $Undo = {
            param([ref]$outBuffer,[ref]$outCursor)
            if($undoStack.Count -gt 0){
                $u=$undoStack.Pop()
                $outBuffer.Value=$u.Buffer
                $outCursor.Value=$u.Cursor
                Clear-Menu
                Redraw $outBuffer.Value $outCursor.Value $PromptRow
                return $true
            }
            return $false
        }
        $WordStart = {
            param([string]$text,[int]$pos)
            $i=$pos
            while($i -gt 0 -and [char]::IsWhiteSpace($text[$i-1])){--$i}
            while($i -gt 0 -and -not [char]::IsWhiteSpace($text[$i-1])){--$i}
            return $i
        }
        $WordEnd = {
            param([string]$text,[int]$pos)
            $i=$pos
            while($i -lt $text.Length -and [char]::IsWhiteSpace($text[$i])){++$i}
            while($i -lt $text.Length -and -not [char]::IsWhiteSpace($text[$i])){++$i}
            return $i
        }

        # Interactive .model completion menu owns Up/Down/Tab/Enter/Esc while active.
        if($script:ModelMenuActive){
            if($key.Key -eq [ConsoleKey]::Tab){
                Move-ModelMenu 1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::UpArrow){
                Move-ModelMenu -1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::DownArrow -or ($key.Key -eq [ConsoleKey]::J -and -not $ctrl)){
                Move-ModelMenu 1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if(($key.Key -eq [ConsoleKey]::K -and -not $ctrl)){
                Move-ModelMenu -1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::Enter){
                if($script:ModelMenuItems.Count -gt 0){
                    $idx=[Math]::Max(0,[Math]::Min($script:ModelMenuIndex,$script:ModelMenuItems.Count-1))
                    $buffer='.model '+[string]$script:ModelMenuItems[$idx]
                    $cursor=$buffer.Length
                }
                Clear-ModelMenu
                Redraw $buffer $cursor $PromptRow
                continue
            }
            if($key.Key -eq [ConsoleKey]::Escape){
                $buffer='.model '+$script:ModelMenuTyped
                $cursor=$buffer.Length
                Clear-ModelMenu
                Redraw $buffer $cursor $PromptRow
                continue
            }
            Clear-ModelMenu
            Redraw $buffer $cursor $PromptRow
        }

        if($script:MenuVisible){
            # Completion menu owns navigation while it is open.
            # Use both ConsoleKey and KeyChar so this works with native Console.ReadKey
            # and the RawUI fallback used on older PowerShell hosts.
            $kc=[string]$key.KeyChar
            $isJ=($kc -ceq 'j')
            $isK=($kc -ceq 'k')

            if($key.Key -eq [ConsoleKey]::Tab){
                $dir=if(($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0){-1}else{1}
                Move-Menu $dir $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::UpArrow -or $isK){
                Move-Menu -1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::DownArrow -or $isJ){
                Move-Menu 1 $PromptRow ([ref]$buffer) ([ref]$cursor)
                continue
            }
            if($key.Key -eq [ConsoleKey]::Enter){
                [void](Accept-Menu $PromptRow ([ref]$buffer) ([ref]$cursor))
                continue
            }
            if($key.Key -eq [ConsoleKey]::Escape){
                Clear-Menu
                Redraw $buffer $cursor $PromptRow
                continue
            }
            # Any other key means the user is editing/filtering the query.
            # Close the old menu and let normal readline processing handle the key.
            Clear-Menu
            Redraw $buffer $cursor $PromptRow
        }

        if($isCtrlEnter -or $isCtrlJ){
            Clear-Menu
            $buffer=$buffer.Insert($cursor,"`n")
            ++$cursor
            $draft=$buffer
            $historyPos=$script:History.Count
            $historySearch=$false
            $historyPrefix=''
            $historySearchPos=$script:History.Count
            Redraw $buffer $cursor $PromptRow
            continue
        }

        # Fish-like history:
        # - Empty line: normal Up/Down navigation through all history.
        # - Non-empty line: Up/Ctrl+P searches backward for entries starting with the current text.
        # - Down/Ctrl+N searches forward through the same prefix matches and then restores the draft.
        $historyPrevious=($key.Key -eq [ConsoleKey]::UpArrow) -or ($ctrl -and $key.Key -eq [ConsoleKey]::P)
        $historyNext=($key.Key -eq [ConsoleKey]::DownArrow) -or ($ctrl -and $key.Key -eq [ConsoleKey]::N)

        if($historyPrevious -or $historyNext){
            if($script:History.Count -gt 0){
                $direction=if($historyPrevious){-1}else{1}

                if(-not $historySearch -and $buffer.Length -gt 0 -and $historyPos -eq $script:History.Count){
                    # Start a fish-like prefix search from the newest end of history.
                    $historySearch=$true
                    $historyPrefix=$buffer
                    $historySearchPos=$script:History.Count
                    $draft=$buffer
                }

                if($historySearch){
                    $i=$historySearchPos+$direction
                    $found=$false
                    while($i -ge 0 -and $i -lt $script:History.Count){
                        $candidate=[string]$script:History[$i]
                        if($candidate.StartsWith($historyPrefix,[StringComparison]::OrdinalIgnoreCase)){
                            $historySearchPos=$i
                            $historyPos=$i
                            $buffer=$candidate
                            $cursor=$buffer.Length
                            $found=$true
                            break
                        }
                        $i+=$direction
                    }

                    if(-not $found -and $direction -gt 0){
                        # Past the newest matching entry: restore what the user originally typed.
                        $buffer=$draft
                        $cursor=$buffer.Length
                        $historyPos=$script:History.Count
                        $historySearch=$false
                        $historyPrefix=''
                        $historySearchPos=$script:History.Count
                    }
                } else {
                    # Ordinary full-history navigation on an empty line.
                    if($direction -lt 0){
                        if($historyPos -eq $script:History.Count){$draft=$buffer}
                        if($historyPos -gt 0){--$historyPos}
                    } elseif($historyPos -lt $script:History.Count){
                        ++$historyPos
                    }

                    if($historyPos -lt $script:History.Count){
                        $buffer=[string]$script:History[$historyPos]
                        $cursor=$buffer.Length
                    } else {
                        $buffer=$draft
                        $cursor=$buffer.Length
                    }
                }

                Clear-Menu
                Redraw $buffer $cursor $PromptRow
            }
            continue
        }

        # Any normal editing action leaves history-search mode.
        if($historySearch){
            $historySearch=$false
            $historyPrefix=''
            $historySearchPos=$script:History.Count
            $historyPos=$script:History.Count
            $draft=$buffer
        }

        if($key.Key -eq [ConsoleKey]::Tab){
            if($script:MenuVisible){continue}
            if($cursor -ne $buffer.Length){continue}

            # NETWORK REFRESH IS EXPLICIT: only .models + Tab writes model cache files.
            if($buffer -eq '.models' -or $buffer -eq '.models '){
                Clear-Menu
                Refresh-ModelCaches
                $buffer='.models ';$cursor=$buffer.Length
                Redraw $buffer $cursor $PromptRow
                continue
            }

            if($buffer -match '^\.models\s+[^\s]+$'){
                $only=$buffer.Substring(8).Trim();$p=Get-Provider $only
                Clear-Menu
                if($null -eq $p){
                    $matches=@($script:Providers|ForEach-Object{[string]$_.name}|Where-Object{$_.StartsWith($only,[StringComparison]::OrdinalIgnoreCase)})
                    if($matches.Count -eq 1){Refresh-ModelCaches $matches[0]}else{W '[models] unknown/ambiguous provider' Yellow}
                }else{Refresh-ModelCaches $only}
                Redraw $buffer $cursor $PromptRow
                continue
            }

            if($buffer.StartsWith('!')){
                $c=Complete-LocalApp $buffer $PromptRow
                if($null -ne $c -and $c -is [string] -and $c -ne $buffer){
                    $buffer=$c;$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow
                }
                continue
            }
            if($buffer.Length -eq 0){
                $mi=@($script:Commands|ForEach-Object{[pscustomobject]@{Name=$_;PSIsContainer=$false}})
                Show-Menu $mi $PromptRow $buffer $cursor
                continue
            }
            if($buffer -in @('.file','.read','.shot','.diff','.model')){
                $buffer+=' ';$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow;continue
            }
            # Argument completion must run before the generic dot-command completer.
            # Otherwise '.diff <Tab>' and '.model <Tab>' are swallowed by Complete-Command.
            if($buffer -match '^\.model\s'){
                try{
                    $r=Complete-Model $buffer $PromptRow
                    if($null -ne $r){$buffer=$r;$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow}
                }catch{Clear-Menu;W ('[model completion error] '+$_.Exception.Message) Red;Redraw $buffer $cursor $PromptRow}
                continue
            }
            if($buffer -match '^\.(file|read|shot|diff)(?:\s|$)'){
                $cmd='.'+$Matches[1]
                try{
                    $r=Complete-Path $buffer $cursor $PromptRow $cmd
                    if($null -ne $r -and $r -is [string]){$buffer=$r;$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow}
                }catch{Clear-Menu;W ('[completion error] '+$_.Exception.Message) Red;Redraw $buffer $cursor $PromptRow}
                continue
            }
            if($buffer.StartsWith('.')){
                $c=Complete-Command $buffer $PromptRow
                if($null -ne $c -and $c -is [string] -and $c -ne $buffer){
                    $buffer=$c;$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow
                }
                continue
            }
            continue
        }

        # Emacs/readline-style editing extensions. Ctrl+_ is the usual Emacs undo key;
        # on Windows it arrives as Ctrl+Shift+- / OemMinus, or occasionally KeyChar '_'.
        if($ctrl -and $isCtrlUnderscore){
            if(-not (&$Undo ([ref]$buffer) ([ref]$cursor))){try{[Console]::Beep(700,35)}catch{}}
            continue
        }

        if($alt){
            # Windows console commonly reports Meta/Alt as a modifier on the
            # same key event. Handle it here and then explicitly continue the
            # readline loop so the plain character is NOT inserted afterward.
            $altHandled=$false
            switch($key.Key){
                ([ConsoleKey]::B){
                    $cursor=(& $WordStart $buffer $cursor)
                    Redraw $buffer $cursor $PromptRow
                    $altHandled=$true
                }
                ([ConsoleKey]::F){
                    $cursor=(& $WordEnd $buffer $cursor)
                    Redraw $buffer $cursor $PromptRow
                    $altHandled=$true
                }
                ([ConsoleKey]::D){
                    if($cursor -lt $buffer.Length){
                        $oldBuffer=$buffer; $oldCursor=$cursor; $end=(& $WordEnd $buffer $cursor)
                        $killRing=$buffer.Substring($cursor,$end-$cursor)
                        & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Remove($cursor,$end-$cursor)
                        Redraw $buffer $cursor $PromptRow
                    }
                    $altHandled=$true
                }
                ([ConsoleKey]::Backspace){
                    if($cursor -gt 0){
                        $oldBuffer=$buffer; $oldCursor=$cursor; $start=(& $WordStart $buffer $cursor)
                        $killRing=$buffer.Substring($start,$cursor-$start)
                        & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Remove($start,$cursor-$start); $cursor=$start
                        Redraw $buffer $cursor $PromptRow
                    }
                    $altHandled=$true
                }
                ([ConsoleKey]::H){
                    if($cursor -gt 0){
                        $oldBuffer=$buffer; $oldCursor=$cursor; $start=(& $WordStart $buffer $cursor)
                        $killRing=$buffer.Substring($start,$cursor-$start)
                        & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Remove($start,$cursor-$start); $cursor=$start
                        Redraw $buffer $cursor $PromptRow
                    }
                    $altHandled=$true
                }
            }
            if($altHandled){ continue }
        }

        if($ctrl){
            switch($key.Key){
                ([ConsoleKey]::A){$cursor=0;Redraw $buffer $cursor $PromptRow;continue}
                ([ConsoleKey]::E){$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow;continue}
                ([ConsoleKey]::B){if($cursor -gt 0){--$cursor};Redraw $buffer $cursor $PromptRow;continue}
                ([ConsoleKey]::F){if($cursor -lt $buffer.Length){++$cursor};Redraw $buffer $cursor $PromptRow;continue}
                ([ConsoleKey]::U){
                    if($cursor -gt 0){
                        $oldBuffer=$buffer; $oldCursor=$cursor;
                        $killRing=$buffer.Substring(0,$cursor)
                        & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Substring($cursor); $cursor=0
                    }
                    Redraw $buffer $cursor $PromptRow; continue
                }
                ([ConsoleKey]::W){
                    if($cursor -gt 0){
                        $oldBuffer=$buffer; $oldCursor=$cursor; $start=(& $WordStart $buffer $cursor)
                        $killRing=$buffer.Substring($start,$cursor-$start)
                        & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Remove($start,$cursor-$start); $cursor=$start
                    }
                    Redraw $buffer $cursor $PromptRow; continue
                }
                ([ConsoleKey]::Y){
                    if(-not [string]::IsNullOrEmpty($killRing)){
                        $oldBuffer=$buffer; $oldCursor=$cursor; & $SaveUndo $oldBuffer $oldCursor
                        $buffer=$buffer.Insert($cursor,$killRing); $cursor += $killRing.Length
                    }
                    Redraw $buffer $cursor $PromptRow; continue
                }
                ([ConsoleKey]::C){
                    if($buffer.Length -gt 0){$oldBuffer=$buffer;$oldCursor=$cursor;& $SaveUndo $oldBuffer $oldCursor}
                    $buffer='';$cursor=0;$draft='';$historyPos=$script:History.Count;$historySearch=$false;$historyPrefix='';$historySearchPos=$script:History.Count;Redraw $buffer $cursor $PromptRow;continue
                }
                ([ConsoleKey]::D){
                    if($cursor -lt $buffer.Length){$oldBuffer=$buffer;$oldCursor=$cursor;& $SaveUndo $oldBuffer $oldCursor;$buffer=$buffer.Remove($cursor,1)}
                    Redraw $buffer $cursor $PromptRow;continue
                }
                ([ConsoleKey]::H){
                    if($cursor -gt 0){$oldBuffer=$buffer;$oldCursor=$cursor;& $SaveUndo $oldBuffer $oldCursor;$buffer=$buffer.Remove($cursor-1,1);--$cursor}
                    Redraw $buffer $cursor $PromptRow;continue
                }
                ([ConsoleKey]::L){
                    Clear-Menu
                    [void](Refresh-TuiWindow)
                    Redraw $buffer $cursor $PromptRow
                    continue
                }
            }
        }

        if($key.Key -eq [ConsoleKey]::LeftArrow){if($cursor -gt 0){--$cursor};Redraw $buffer $cursor $PromptRow;continue}
        if($key.Key -eq [ConsoleKey]::RightArrow){if($cursor -lt $buffer.Length){++$cursor};Redraw $buffer $cursor $PromptRow;continue}
        if($key.Key -eq [ConsoleKey]::Home){$cursor=0;Redraw $buffer $cursor $PromptRow;continue}
        if($key.Key -eq [ConsoleKey]::End){$cursor=$buffer.Length;Redraw $buffer $cursor $PromptRow;continue}
        if($key.Key -eq [ConsoleKey]::Backspace){
            if($cursor -gt 0){$oldBuffer=$buffer;$oldCursor=$cursor;& $SaveUndo $oldBuffer $oldCursor;$buffer=$buffer.Remove($cursor-1,1);--$cursor}
            $historyPos=$script:History.Count;$draft=$buffer
            Redraw $buffer $cursor $PromptRow;continue
        }
        if($key.Key -eq [ConsoleKey]::Delete){
            if($cursor -lt $buffer.Length){$oldBuffer=$buffer;$oldCursor=$cursor;& $SaveUndo $oldBuffer $oldCursor;$buffer=$buffer.Remove($cursor,1)}
            $historyPos=$script:History.Count;$draft=$buffer
            Redraw $buffer $cursor $PromptRow;continue
        }
        if($key.Key -eq [ConsoleKey]::Enter){Clear-Menu;[Console]::Write("`r`n");return $buffer}

        if(-not [Char]::IsControl($key.KeyChar)){
            $oldBuffer=$buffer; $oldCursor=$cursor; & $SaveUndo $oldBuffer $oldCursor
            $historyPos=$script:History.Count
            $draft=''
            if($cursor -eq $buffer.Length){$buffer+=$key.KeyChar}else{$buffer=$buffer.Insert($cursor,[string]$key.KeyChar)}
            ++$cursor
            if(Available){
                while(Available){
                    $p=Read-Key
                    if($p.Key -eq [ConsoleKey]::Enter){$buffer=$buffer.Insert($cursor,"`n");++$cursor;continue}
                    if($p.Key -eq [ConsoleKey]::Tab){$buffer=$buffer.Insert($cursor,"`t");++$cursor;continue}
                    if(-not [Char]::IsControl($p.KeyChar)){$buffer=$buffer.Insert($cursor,[string]$p.KeyChar);++$cursor}
                }
            }
            Redraw $buffer $cursor $PromptRow
        }
    }
}
$cliArgs=@($cliArgs)
if($cliArgs.Count -gt 0){
    foreach($arg in $cliArgs){
        if($arg -eq '--mira-console'){
            continue
        }
        if($arg -eq '-d' -or $arg -eq '--dry-run'){
            $script:DryRunMode=$true
            continue
        }
        Write-Host ('[cli] argument not implemented: '+$arg) -ForegroundColor Red
        Write-Host ''
        Show-CliArgumentStatus
        exit 2
    }
}

Clear-Host
Load-Providers
Load-TuiHistory
W 'MIRA-TUI / SLIM PROVIDERS' Cyan
W ('Own readline • no PSReadLine • Tab • history • multiline • attachments • model: ' + $script:CurrentProviderName + ':' + $script:CurrentModel) DarkGray
W ('Session: off (one-shot requests) • .session enables RAM context • compress threshold: ' + $script:CompressThreshold) DarkGray
W ('History persistence: ' + $(if($script:PersistHistory){$script:HistoryFile}else{'OFF (RAM only)'}) + ' • loaded last ' + $script:HistoryLoadLimit + ' entries • .history persist on/off') DarkGray
W ('OpenAI-compatible stream: ' + $(if($script:StreamResponses){'on'}else{'off'}) + ' • reasoning: ' + $(if($script:ShowReasoning){'on'}else{'off'})) DarkGray
W ('Model cache: ' + $script:ModelCacheRoot + ' • refresh only with .models <Tab> • verify with .models test') DarkGray
W ('Used models: ' + $script:UsedModelsCacheFile + ' • learned from successful text replies/probes') DarkGray
W ''
$script:MiraConsoleInputConfigured=$false
try{
    try{
        if($Host.Name -ne 'Windows PowerShell ISE Host'){
            [Console]::TreatControlCAsInput=$true
            $script:MiraConsoleInputConfigured=$true
        }
    }catch{}
    while($script:Running){
        Reset-TuiHistorySearch;Clear-Menu
        $line=Read-Line (Row)
        if([string]::IsNullOrEmpty($line)){continue}
        Add-TuiHistory $line;Save-TuiHistory
        try{ Handle $line }catch{
            try{ W ('[command error] '+$_.Exception.Message) Red }catch{}
        }
    }
}finally{
    Save-TuiHistory
    if($script:MiraConsoleInputConfigured){
        try{[Console]::TreatControlCAsInput=$false}catch{}
    }
}