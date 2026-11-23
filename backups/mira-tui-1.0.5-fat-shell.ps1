#requires -Version 5.1

# ============================================================================
# MIRA-TUI / MICROSCRIPT UNIVERSAL TUI TEMPLATE
#
# Windows PowerShell 5.1+ / PowerShell 7+
# No PSReadLine dependency. No external modules.
# Own input buffer, cursor, history, completion and renderer.
# License: MIT. Copyright (c) 2026 Jeroen.
# References: PowerShell/PSReadLine, standardbeagle/ps-bash,
#             pswpswpsw/unix-like-powershell, Vim community configs, sigoden/aichat.
# Version: 1.0.5-completion-menu-fix
# Status : A/B test build / positional TEXT restored from MONKEY baseline
# TODO   : [MONKEY] WORKING BASELINE — positional TEXT restored for regression test.
#          Compare Explorer context-menu launch against 1.0.3-no-positional-text.
#          Keep TUI core independent from application/API semantics.
#          Context Menu: zero-argument interactive launch is a required contract.
# ============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ----------------------------------------------------------------------------
# TERMINAL BACKEND
#
# Classic PowerShell / ConHost keeps the Windows Console API path.
# Windows Terminal / modern VT hosts get ANSI cursor positioning.
# The TUI core calls only these small helpers.
# ----------------------------------------------------------------------------
$script:TuiUseVtCursor = $false
try {
    if ($env:WT_SESSION -or $env:ConEmuANSI -eq 'ON' -or $env:TERM) {
        $script:TuiUseVtCursor = $true
    }
}
catch {}

function Set-TuiCursorPosition {
    param(
        [int]$X,
        [int]$Y
    )

    try {
        if ($script:TuiUseVtCursor) {
            [Console]::Write(([char]27).ToString() + '[' + ($Y + 1) + ';' + ($X + 1) + 'H')
        }
        else {
            [Console]::SetCursorPosition($X, $Y)
        }
        return $true
    }
    catch {
        # Last-resort fallback for odd hosts.
        try {
            [Console]::SetCursorPosition($X, $Y)
            return $true
        }
        catch { return $false }
    }
}

function Get-TuiCursorTop {
    try { return [Console]::CursorTop } catch { return 0 }
}

function Read-TuiKey {
    # Primary path: System.Console for normal conhost / Windows Terminal input.
    try {
        return [Console]::ReadKey($true)
    }
    catch {
        # Explorer "Run with PowerShell" may not expose Console.ReadKey in the
        # same way. PowerShell RawUI is the native fallback for such hosts.
        $raw = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

        $mods = [ConsoleModifiers]0
        $state = [int]$raw.ControlKeyState
        if (($state -band 16) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Shift }
        if (($state -band 12) -ne 0) { $mods = $mods -bor [ConsoleModifiers]::Control }
        if (($state -band 3) -ne 0)  { $mods = $mods -bor [ConsoleModifiers]::Alt }

        return New-Object PSObject -Property @{
            Key       = [ConsoleKey][int]$raw.VirtualKeyCode
            KeyChar   = [char]$raw.Character
            Modifiers = $mods
        }
    }
}

function Test-TuiKeyAvailable {
    try { return [Console]::KeyAvailable }
    catch {
        try { return $Host.UI.RawUI.KeyAvailable }
        catch { return $false }
    }
}


# ----------------------------------------------------------------------------
# STATE
# ----------------------------------------------------------------------------
$script:TuiHistory = [System.Collections.Generic.List[string]]::new()
$script:TuiHistoryIndex = -1
$script:TuiHistoryDraft = ''
$script:TuiHistoryMax = 500
$script:TuiRunning = $true
$script:TuiLastText = ''
$script:TuiLastRequestJson = ''
$script:TuiHistorySearchActive = $false
$script:TuiHistorySearchPrefix = ''
$script:TuiHistorySearchIndex = -1
$script:TuiCompletionMenuVisible = $false
$script:TuiCompletionMenuTop = 0
$script:TuiCompletionMenuRows = 0

# ----------------------------------------------------------------------------
# CLI / ONE-SHOT TEMPLATE
#
# Options are intentionally kept separate from TUI input.
# Positional TEXT starts generic one-shot mode; interactive TUI remains the
# normal path when no positional TEXT is supplied.
# A legacy Microsoft Explorer Run-with-PowerShell launcher tail is filtered
# before positional TEXT detection.
# ----------------------------------------------------------------------------
$script:TuiCli = [ordered]@{
    Model   = ''
    Execute = $false
    Help    = $false
    DryRun  = $false
    Text    = @()
}

$script:TuiCommands = @(
    '.help',
    '.info',
    '.clear',
    '.diff',
    '.file',
    '.text',
    '.save',
    '.savesession',
    '.loadsession',
    '.shot',
    '.request',
    '.mira-update',
    '.exit',
    '.q',
    ':q',
    ':wq'
)

# ----------------------------------------------------------------------------
# CLI ARGUMENT PARSER
#
# PowerShell has already handled Windows quoting and produced $args.
# We only interpret the small Unix-style option layer here.
#
# Rules:
#   options before the first positional token are parsed as CLI options;
#   the first positional token starts TEXT phase;
#   after TEXT starts, every remaining token is literal text;
#   -- ends option parsing and itself is not part of TEXT;
#   --- is not special and therefore becomes TEXT (when TEXT has started)
#   or an unknown option error (when it has not).
# ----------------------------------------------------------------------------
function Test-TuiMicrosoftRunWithPowerShellTail {
    param(
        [string[]]$Arguments,
        [int]$Index
    )

    if ($Index -ge $Arguments.Count) { return $false }
    if (-not ([string]$Arguments[$Index]).Equals('-Command', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    if (($Index + 1) -ge $Arguments.Count) { return $false }

    # Windows Explorer's legacy "Run with PowerShell" verb can append a
    # PowerShell execution-policy command after -file "%1". After -File,
    # that tail is visible to the script as $args and is NOT user CLI text.
    # Recognize the documented/observed execution-policy signature and ignore
    # the rest of the launcher tail. Do not treat arbitrary -Command text as
    # launcher noise.
    $commandText = [string]$Arguments[$Index + 1]

    return (
        $commandText -match '(?i)Get-ExecutionPolicy' -and
        $commandText -match '(?i)Set-ExecutionPolicy' -and
        $commandText -match '(?i)Scope\s+Process' -and
        $commandText -match '(?i)Bypass'
    )
}

function Parse-TuiArguments {
    param([string[]]$Arguments)

    $result = [ordered]@{
        Model   = ''
        Execute = $false
        Help    = $false
        DryRun  = $false
        Text    = New-Object System.Collections.Generic.List[string]
    }

    $textStarted = $false
    $endOptions = $false

    for ($i = 0; $i -lt $Arguments.Count; ++$i) {
        $arg = [string]$Arguments[$i]

        if ($endOptions -or $textStarted) {
            [void]$result.Text.Add($arg)
            continue
        }

        # Microsoft Explorer launcher tail: ignore it completely.
        if (Test-TuiMicrosoftRunWithPowerShellTail -Arguments $Arguments -Index $i) {
            break
        }

        if ($arg -eq '--') {
            $endOptions = $true
            continue
        }

        switch -Regex ($arg) {
            '^(?i)-h$|^(?i)--help$' {
                $result.Help = $true
                continue
            }
            '^(?i)-e$|^(?i)--execute$' {
                $result.Execute = $true
                continue
            }
            '^(?i)-d$|^(?i)--dry-run$' {
                $result.DryRun = $true
                continue
            }
            '^(?i)-m$|^(?i)--model$' {
                if (($i + 1) -ge $Arguments.Count -or [string]$Arguments[$i + 1] -eq '--') {
                    throw 'Option -m/--model requires a value.'
                }
                ++$i
                $result.Model = [string]$Arguments[$i]
                continue
            }
            default {
                if ($arg.StartsWith('-')) {
                    throw ('Unknown option: ' + $arg)
                }

                $textStarted = $true
                [void]$result.Text.Add($arg)
                continue
            }
        }
    }

    return $result
}

# ----------------------------------------------------------------------------
# CONSOLE HELPERS
# ----------------------------------------------------------------------------
function Get-TuiWindowWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 0) { return $w }
    } catch {}

    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -gt 0) { return $w }
    } catch {}

    return 80
}

function Get-TuiUniqueFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $name = "$BaseName$Extension"
    $number = 2

    while (Test-Path -LiteralPath $name) {
        $name = "${BaseName}_$number$Extension"
        ++$number
    }

    return $name
}

function Write-TuiColorBlocks {
    $colors = @(
        'Black','DarkBlue','DarkGreen','DarkCyan',
        'DarkRed','DarkMagenta','DarkYellow','Gray',
        'DarkGray','Blue','Green','Cyan',
        'Red','Magenta','Yellow','White'
    )

    Write-Host 'COLORBLOCKS:' -ForegroundColor White
    foreach ($colorName in $colors) {
        $color = [ConsoleColor]$colorName
        Write-Host ('  ' + $colorName.PadRight(12) + '  ') -BackgroundColor $color -ForegroundColor White
    }
}

function Write-TuiHeader {
    Clear-Host

    $width = Get-TuiWindowWidth
    if ($width -lt 50) { $width = 50 }

    $inner = $width - 2
    $title = ' MIRA-TUI / MICROSCRIPT '
    $room = [Math]::Max(0, $inner - $title.Length)
    $left = [int]($room / 2)
    $right = $room - $left

    Write-Host ('┌' + ('─' * $left) + $title + ('─' * $right) + '┐') -ForegroundColor DarkGray
    Write-Host ('│  Own readline. PSReadLine independent. Ctrl+D=delete-forward.  │') -ForegroundColor DarkGray
    Write-Host ('│  Emacs: C-A/E/B/F  M-B/F  C-J/C-Enter=newline  Enter=accept.│') -ForegroundColor DarkGray
    Write-Host ('└' + ('─' * $inner) + '┘') -ForegroundColor DarkGray
    Write-Host ''
}

# ----------------------------------------------------------------------------
# HISTORY
# ----------------------------------------------------------------------------
function Add-TuiHistory {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }

    if ($script:TuiHistory.Count -gt 0 -and
        $script:TuiHistory[$script:TuiHistory.Count - 1] -eq $Text) {
        return
    }

    [void]$script:TuiHistory.Add($Text)

    while ($script:TuiHistory.Count -gt $script:TuiHistoryMax) {
        $script:TuiHistory.RemoveAt(0)
    }
}

function Reset-TuiHistorySearch {
    $script:TuiHistorySearchActive = $false
    $script:TuiHistorySearchPrefix = ''
    $script:TuiHistorySearchIndex = -1
}

# ----------------------------------------------------------------------------
# OUTPUT RENDERER
#
# Cheap by design:
#   ```...```     -> code mode
#   **text**       -> White
#   <tag ...>      -> Cyan
#   ordinary text  -> Gray
#
# Code mode does not parse Markdown/XML.
# ----------------------------------------------------------------------------
function Write-TuiInline {
    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) {
        Write-Host ''
        return
    }

    # Bold-like accents are bright; XML-like tags stay deliberately quiet.
    $tokenPattern = '(\*\*[^*\r\n]+\*\*|<\/?[A-Za-z_][A-Za-z0-9_.:-]*(?:\s+[^<>]*?)?\/?>)'
    $matches = [regex]::Matches($Line, $tokenPattern)
    $pos = 0

    foreach ($m in $matches) {
        if ($m.Index -gt $pos) {
            Write-Host $Line.Substring($pos, $m.Index - $pos) -NoNewline -ForegroundColor Gray
        }

        $token = $m.Value

        if ($token.StartsWith('**') -and $token.EndsWith('**')) {
            $accent = $token.Substring(2, $token.Length - 4)
            Write-Host $accent -NoNewline -ForegroundColor White -BackgroundColor DarkGray
        }
        else {
            # Gemma-style XML-like control tags are not parsed or changed.
            Write-Host $token -NoNewline -ForegroundColor DarkGray
        }

        $pos = $m.Index + $m.Length
    }

    if ($pos -lt $Line.Length) {
        Write-Host $Line.Substring($pos) -NoNewline -ForegroundColor Gray
    }

    Write-Host ''
}

function Write-TuiCodeBlock {
    param(
        [string]$Language,
        [string[]]$Lines
    )

    # JSON gets one cheap readability upgrade when it is actually valid.
    if ($Language -eq 'json' -and $Lines.Count -gt 0) {
        try {
            $jsonText = [string]::Join("`n", $Lines)
            $pretty = $jsonText | ConvertFrom-Json | ConvertTo-Json -Depth 50
            if (-not [string]::IsNullOrWhiteSpace($pretty)) {
                Write-Host $pretty -ForegroundColor Gray
                return
            }
        }
        catch {
            # Invalid / partial JSON: leave the source untouched.
        }
    }

    foreach ($line in $Lines) {
        Write-Host $line -ForegroundColor Gray
    }
}

function Write-TuiText {
    param([string]$Text)

    if ($null -eq $Text) { return }

    # Whole-response JSON: pretty-print only when PowerShell can parse it.
    $probe = $Text.Trim()
    if (($probe.StartsWith('{') -or $probe.StartsWith('[')) -and
        (($probe.EndsWith('}') -or $probe.EndsWith(']')))) {
        try {
            $pretty = $probe | ConvertFrom-Json | ConvertTo-Json -Depth 50
            if (-not [string]::IsNullOrWhiteSpace($pretty)) {
                Write-Host $pretty -ForegroundColor Gray
                return
            }
        }
        catch {
            # Not valid JSON: render normally.
        }
    }

    $inCode = $false
    $codeLanguage = ''
    $codeLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($Text -split "`r?`n", -1)) {
        if ($line.Trim() -like '```*') {
            if (-not $inCode) {
                $inCode = $true
                $codeLanguage = $line.Trim().Substring(3).Trim().ToLower()
                $codeLines.Clear()

                if ($codeLanguage) {
                    Write-Host ('[ code: ' + $codeLanguage + ' ]') -ForegroundColor DarkCyan
                }
                else {
                    Write-Host '[ code ]' -ForegroundColor DarkCyan
                }
            }
            else {
                $inCode = $false
                Write-TuiCodeBlock -Language $codeLanguage -Lines @($codeLines)
                Write-Host '[ /code ]' -ForegroundColor DarkCyan
                $codeLanguage = ''
                $codeLines.Clear()
            }
            continue
        }

        if ($inCode) {
            [void]$codeLines.Add($line)
            continue
        }

        Write-TuiInline $line
    }

    # Gracefully render an unfinished code fence as code.
    if ($inCode -and $codeLines.Count -gt 0) {
        Write-TuiCodeBlock -Language $codeLanguage -Lines @($codeLines)
    }
}

# ----------------------------------------------------------------------------
# INFO
# ----------------------------------------------------------------------------
function Show-TuiInfo {
    Write-Host ''
    Write-Host 'MICROSCRIPT / MIRA-TUI' -ForegroundColor Magenta
    Write-Host '======================' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'SCRIPT' -ForegroundColor Cyan
    Write-Host '  Name       : Mira-TUI universal TUI template' -ForegroundColor Gray
    Write-Host '  Philosophy : tiny script, no unnecessary machinery' -ForegroundColor Gray
    Write-Host '  Input      : own buffer + own cursor' -ForegroundColor Gray
    Write-Host '  Rendering  : cheap text / code / XML-like accents' -ForegroundColor Gray
    Write-Host '  PSReadLine : not required, not used by the TUI' -ForegroundColor Gray
    Write-Host ('  Terminal   : ' + $(if ($script:TuiUseVtCursor) { 'VT cursor backend' } else { 'Console cursor backend' })) -ForegroundColor Gray
    Write-Host ''

    Write-Host 'RUNTIME' -ForegroundColor Cyan
    Write-Host ('  PowerShell : ' + $PSVersionTable.PSVersion) -ForegroundColor Gray
    Write-Host ('  Edition    : ' + $PSVersionTable.PSEdition) -ForegroundColor Gray
    Write-Host ''

    Write-Host 'CREW' -ForegroundColor Cyan
    Write-Host '  Operator   : Jeroen — TUI destroyer' -ForegroundColor Gray
    Write-Host '  Co-pilot   : GPT-5.6 Luna — professional TUI archaeologist' -ForegroundColor Gray
    Write-Host '  Mission    : break it until it becomes boringly reliable' -ForegroundColor Gray
    Write-Host ''

    Write-Host 'BASELINE' -ForegroundColor Cyan
    Write-Host '  Version    : 1.0.5-positional-text-launcher-safe' -ForegroundColor Gray
    Write-Host '  Status     : A/B test build / positional TEXT restored / Explorer launcher tail ignored' -ForegroundColor Gray
    Write-Host '  TODO       : [MONKEY] WORKING BASELINE — positional TEXT restored for regression test.
    #         Microsoft Run-with-PowerShell execution-policy tail is ignored.
    #         Compare Explorer context-menu launch against 1.0.3-no-positional-text.
    #         CLI argument meanings remain project-specific template semantics.
    #         Exit commands do not auto-save; session persistence is explicit.' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'ORIGINS' -ForegroundColor Cyan
    Write-Host '  PSReadLine                 : readline / Emacs / history UX ideas' -ForegroundColor DarkGray
    Write-Host '  standardbeagle/ps-bash     : Unix-style command conventions' -ForegroundColor DarkGray
    Write-Host '  pswpswpsw/unix-like-powershell : shell muscle-memory conventions' -ForegroundColor DarkGray
    Write-Host '  Vim community              : compact keyboard-mapping ideas' -ForegroundColor DarkGray
    Write-Host '  sigoden/aichat             : Unix-style AI CLI conventions' -ForegroundColor DarkGray
    Write-Host '  Git                        : source history / forks / collaboration' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'LICENSE' -ForegroundColor Cyan
    Write-Host '  MicroScript : MIT — use, fork, modify, redistribute.' -ForegroundColor Gray
    Write-Host '  Keep the license notice when redistributing the script.' -ForegroundColor DarkGray
    Write-Host ''

    Write-TuiColorBlocks
    Write-Host ''
}

# ----------------------------------------------------------------------------
# HELP
# Keys and command examples live here, not in .info.
# ----------------------------------------------------------------------------
function Show-TuiHelp {
    Write-Host ''
    Write-Host 'MICROSCRIPT / MIRA-TUI HELP' -ForegroundColor Magenta
    Write-Host '===========================' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'KEYS' -ForegroundColor Cyan
    Write-Host '  Enter          accept the whole buffer' -ForegroundColor Gray
    Write-Host '  Ctrl+J         insert newline' -ForegroundColor Gray
    Write-Host '  Ctrl+Enter     insert newline' -ForegroundColor Gray
    Write-Host '  Left / Right   move one character' -ForegroundColor Gray
    Write-Host '  Home / End     start / end of current line' -ForegroundColor Gray
    Write-Host '  Ctrl+B / F     move one character left / right' -ForegroundColor Gray
    Write-Host '  Ctrl+A / E     start / end of current line' -ForegroundColor Gray
    Write-Host '  Alt+B / F      move one word backward / forward' -ForegroundColor Gray
    Write-Host '  Backspace      delete previous character' -ForegroundColor Gray
    Write-Host '  Ctrl+H         Emacs backward-delete-character' -ForegroundColor Gray
    Write-Host '  Delete         delete next character' -ForegroundColor Gray
    Write-Host '  Ctrl+D         Emacs delete-forward-character; never exits' -ForegroundColor Gray
    Write-Host '  Ctrl+K         delete to end of current line' -ForegroundColor Gray
    Write-Host '  Ctrl+U         delete to start of current line' -ForegroundColor Gray
    Write-Host '  Ctrl+W         delete previous word' -ForegroundColor Gray
    Write-Host '  Up / Down      history; with text, prefix-search history' -ForegroundColor Gray
    Write-Host '  Ctrl+P         previous history item matching current prefix' -ForegroundColor Gray
    Write-Host '  Tab            command / filesystem completion' -ForegroundColor Gray
    Write-Host '  Ctrl+C         clear current buffer' -ForegroundColor Gray
    Write-Host ''

    Write-Host 'COMMANDS' -ForegroundColor Cyan
    Write-Host '  .help  .info  .clear  .file  .text  .diff' -ForegroundColor Gray
    Write-Host '  .save  .savesession  .loadsession  .shot' -ForegroundColor Gray
    Write-Host '  .request  .mira-update  .exit  .q  :q  :wq' -ForegroundColor Gray
    Write-Host ''

    Write-Host 'CLI ARGUMENTS / TEMPLATE' -ForegroundColor Cyan
    Write-Host '  -m, --model <name>   select model' -ForegroundColor Gray
    Write-Host '  -e, --execute        execute-mode flag' -ForegroundColor Gray
    Write-Host '  -h, --help           show help and exit' -ForegroundColor Gray
    Write-Host '  -d, --dry-run        print the request template and exit' -ForegroundColor Gray
    Write-Host '  --                   stop option parsing; the rest is literal text' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  mira-tui.ps1                 interactive TUI' -ForegroundColor DarkGray
    Write-Host '  mira-tui.ps1 "hi babe"       one-shot text' -ForegroundColor DarkGray
    Write-Host '  mira-tui.ps1 -m model "hi"   option + one-shot text' -ForegroundColor DarkGray
    Write-Host '  mira-tui.ps1 -- -e hi        literal one-shot text "-e hi"' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'LOCAL POWERSHELL' -ForegroundColor Cyan
    Write-Host '  !<command>     execute one local PowerShell command' -ForegroundColor Gray
    Write-Host '  Launch         zero-argument interactive start; Console/RawUI key fallback' -ForegroundColor DarkGray
    Write-Host '    !Get-Date' -ForegroundColor DarkGray
    Write-Host '    !Get-Process | Select-Object -First 5' -ForegroundColor DarkGray
    Write-Host '    !ls | clip' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host 'EXIT' -ForegroundColor Cyan
    Write-Host '  .exit / .q     exit immediately; no automatic session write' -ForegroundColor Gray
    Write-Host '  :q / :wq       Vim-style exit; no automatic session write' -ForegroundColor Gray
    Write-Host '  exit / quit    same immediate exit' -ForegroundColor Gray
    Write-Host ''
}

# ----------------------------------------------------------------------------
# FILE COMPLETION
# Bash-like filesystem completion for .file / .text / .diff / .savesession /
# .loadsession.
#
# Cheap model:
#   Tab #1  -> insert longest unambiguous prefix.
#   Tab #2  -> show ambiguous candidates in a temporary completion pane.
#   Any non-Tab key -> the pane is cleared/redrawn before normal editing.
#
# The completion pane is not part of normal transcript output.
# ----------------------------------------------------------------------------
function Get-TuiPathCandidates {
    param([string]$Typed)

    $raw = if ($null -eq $Typed) { '' } else { [string]$Typed }

    if ($raw.StartsWith('"') -or $raw.StartsWith("'")) {
        $raw = $raw.Substring(1)
    }

    if ($raw.StartsWith('~')) {
        $raw = $env:USERPROFILE + $raw.Substring(1)
    }

    if ([string]::IsNullOrEmpty($raw)) {
        $directory = (Get-Location).Path
        $leaf = ''
    }
    else {
        try {
            $directory = [IO.Path]::GetDirectoryName($raw)
            $leaf = [IO.Path]::GetFileName($raw)
        }
        catch {
            return @()
        }

        if ([string]::IsNullOrEmpty($directory)) {
            $directory = (Get-Location).Path
        }
    }

    try {
        return @(
            Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase) } |
                Sort-Object Name
        )
    }
    catch {
        return @()
    }
}

function Get-TuiLongestCommonPrefix {
    param([string[]]$Values)

    if ($null -eq $Values -or $Values.Count -eq 0) { return '' }
    if ($Values.Count -eq 1) { return [string]$Values[0] }

    $prefix = [string]$Values[0]
    for ($i = 1; $i -lt $Values.Count -and $prefix.Length -gt 0; ++$i) {
        $candidate = [string]$Values[$i]
        $max = [Math]::Min($prefix.Length, $candidate.Length)
        $j = 0
        while ($j -lt $max -and
               [Char]::ToLowerInvariant($prefix[$j]) -eq [Char]::ToLowerInvariant($candidate[$j])) {
            ++$j
        }
        $prefix = $prefix.Substring(0, $j)
    }

    return $prefix
}

function Clear-TuiCompletionMenu {
    if ($script:TuiCompletionMenuVisible) {
        $top = [int]$script:TuiCompletionMenuTop
        $rows = [int]$script:TuiCompletionMenuRows
        $width = Get-TuiWindowWidth
        if ($width -lt 20) { $width = 20 }

        for ($r = 0; $r -lt $rows; ++$r) {
            if (-not (Set-TuiCursorPosition -X 0 -Y ($top + $r))) { continue }
            [Console]::Write((' ' * [Math]::Max(1, $width - 1)))
        }
    }

    # Completion is a one-shot UI state. Do not let any stale completion
    # payload survive after the menu has been dismissed.
    $script:TuiCompletionMenuVisible = $false
    $script:TuiCompletionMenuTop = 0
    $script:TuiCompletionMenuRows = 0
    $script:TuiCompletionBuffer = $null
    $script:TuiCompletionCursor = $null
    $script:TuiCompletionRow = $null
}

function Show-TuiCompletionMenu {
    param(
        [object[]]$Items,
        [int]$PromptRow,
        [string]$Buffer,
        [int]$Cursor
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return }

    Clear-TuiCompletionMenu

    $names = @($Items | ForEach-Object {
        if ($_.PSIsContainer) { $_.Name + '\' } else { $_.Name }
    })

    if ($names.Count -eq 0) { return }

    $width = Get-TuiWindowWidth
    if ($width -lt 40) { $width = 40 }

    # Compact Bash-like columns. Never create a huge single transcript line.
    $maxName = 1
    foreach ($name in $names) {
        if ($name.Length -gt $maxName) { $maxName = $name.Length }
    }

    $columnWidth = $maxName + 2
    $columns = [Math]::Max(1, [int][Math]::Floor($width / $columnWidth))
    if ($columns -gt $names.Count) { $columns = $names.Count }

    # Keep completion cheap in classic CMD/ConHost. Large directories can
    # otherwise require hundreds of SetCursorPosition + Write operations just
    # to erase the menu when the user types the next character.
    $maxMenuRows = 10
    $maxVisibleItems = $columns * $maxMenuRows
    $truncated = ($names.Count -gt $maxVisibleItems)
    $visibleNames = if ($truncated) {
        @($names | Select-Object -First $maxVisibleItems)
    }
    else {
        @($names)
    }

    $rows = [int][Math]::Ceiling($visibleNames.Count / [double]$columns)
    $footerRows = if ($truncated) { 1 } else { 0 }

    $menuTop = $PromptRow + 1
    $script:TuiCompletionMenuTop = $menuTop
    $script:TuiCompletionMenuRows = $rows + $footerRows
    $script:TuiCompletionMenuVisible = $true

    for ($r = 0; $r -lt $rows; ++$r) {
        $parts = New-Object System.Collections.Generic.List[string]
        for ($c = 0; $c -lt $columns; ++$c) {
            $idx = $r + ($c * $rows)
            if ($idx -ge $visibleNames.Count) { break }
            $name = $visibleNames[$idx]
            $cell = if ($c -eq ($columns - 1) -or $idx + $rows -ge $visibleNames.Count) {
                $name
            }
            else {
                $name.PadRight($columnWidth)
            }
            [void]$parts.Add($cell)
        }

        if (Set-TuiCursorPosition -X 0 -Y ($menuTop + $r)) {
            [Console]::Write((' ' * [Math]::Max(1, $width - 1)))
            [void](Set-TuiCursorPosition -X 0 -Y ($menuTop + $r))
            Write-Host ($parts -join '') -NoNewline -ForegroundColor DarkGray
        }
    }

    if ($truncated) {
        $remaining = $names.Count - $visibleNames.Count
        if (Set-TuiCursorPosition -X 0 -Y ($menuTop + $rows)) {
            [Console]::Write((' ' * [Math]::Max(1, $width - 1)))
            [void](Set-TuiCursorPosition -X 0 -Y ($menuTop + $rows))
            Write-Host ('[+' + $remaining + ' more — type more characters to narrow]') -NoNewline -ForegroundColor DarkGray
        }
    }

    [void](Set-TuiCursorPosition -X 0 -Y $PromptRow)
    Redraw-TuiLine -Buffer $Buffer -Cursor $Cursor -Row $PromptRow
}

function Complete-TuiPathArgument {
    param(
        [string]$Buffer,
        [int]$Cursor,
        [string]$CommandName,
        [int]$Row
    )

    if ($Cursor -ne $Buffer.Length) { return $false }

    $space = $Buffer.IndexOf(' ')
    if ($space -lt 0) { return $false }

    $argPrefix = $Buffer.Substring(0, $space + 1)
    $typed = $Buffer.Substring($space + 1)

    # .diff completes the final filesystem argument, preserving earlier args.
    if ($CommandName -eq '.diff' -and $typed.Contains(' ')) {
        $lastSpace = $typed.LastIndexOf(' ')
        $argPrefix = $Buffer.Substring(0, $space + 1 + $lastSpace + 1)
        $typed = $typed.Substring($lastSpace + 1)
    }

    try {
        $items = @(Get-TuiPathCandidates $typed)
    }
    catch {
        try { [Console]::Beep(700, 50) } catch {}
        return $true
    }

    if ($items.Count -eq 0) {
        try { [Console]::Beep(700, 50) } catch {}
        return $true
    }

    $rawTyped = $typed
    $quote = ''
    if ($rawTyped.StartsWith('"') -or $rawTyped.StartsWith("'")) {
        $quote = $rawTyped.Substring(0,1)
    }

    $typedForPrefix = $rawTyped
    if ($quote) { $typedForPrefix = $typedForPrefix.Substring(1) }
    if ($typedForPrefix.StartsWith('~')) {
        # Completion text itself stays in the user's spelling; only the lookup
        # path is expanded inside Get-TuiPathCandidates.
    }

    $names = @($items | ForEach-Object { [string]$_.Name })
    $common = Get-TuiLongestCommonPrefix -Values $names
    $leafTyped = $typedForPrefix

    # Keep only the basename portion for comparison. The displayed prefix may
    # include .\foo\ or another directory path.
    $leafStart = $leafTyped.LastIndexOfAny([char[]]@('\','/'))
    if ($leafStart -ge 0) {
        $leafTyped = $leafTyped.Substring($leafStart + 1)
    }

    if ($items.Count -eq 1) {
        $completionLeaf = $names[0]
    }
    else {
        $completionLeaf = $common
    }

    # Do not pretend a common directory prefix is a completed filename when the
    # user has already supplied more text than the common prefix.
    if ($completionLeaf.Length -lt $leafTyped.Length) {
        $completionLeaf = $leafTyped
    }

    $typedDir = $typedForPrefix
    $dirEnd = $typedDir.LastIndexOfAny([char[]]@('\','/'))
    $dirPrefix = if ($dirEnd -ge 0) { $typedDir.Substring(0, $dirEnd + 1) } else { '' }
    $newTyped = $dirPrefix + $completionLeaf
    if ($quote) { $newTyped = $quote + $newTyped }

    # A sole match is complete; directories receive a trailing slash.
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        $newTyped = $newTyped.TrimEnd('\','/') + '\'
    }

    $newBuffer = $argPrefix + $newTyped
    $progress = ($newBuffer -ne $Buffer)

    $script:TuiCompletionBuffer = $newBuffer
    $script:TuiCompletionCursor = $newBuffer.Length

    if ($items.Count -gt 1 -and -not $progress) {
        Show-TuiCompletionMenu -Items $items -PromptRow $Row -Buffer $newBuffer -Cursor $newBuffer.Length
    }
    elseif ($items.Count -gt 1 -and $script:TuiCompletionMenuVisible) {
        Clear-TuiCompletionMenu
    }

    return $true
}

# ----------------------------------------------------------------------------
# GENERIC COMMAND COMPLETION
# ----------------------------------------------------------------------------
function Get-TuiCommandMatches {
    param([string]$Prefix)

    @($script:TuiCommands | Where-Object {
        $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

# ----------------------------------------------------------------------------
# FILE HELPERS
# ----------------------------------------------------------------------------
function Get-TuiPathArgument {
    param([string]$Text)

    $x = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($x)) { return '' }

    if ($x.StartsWith('"')) {
        $end = $x.IndexOf('"', 1)
        if ($end -gt 0) { return $x.Substring(1, $end - 1) }
    }

    if ($x.StartsWith("'")) {
        $end = $x.IndexOf("'", 1)
        if ($end -gt 0) { return $x.Substring(1, $end - 1) }
    }

    $space = $x.IndexOf(' ')
    if ($space -gt 0) { return $x.Substring(0, $space) }
    return $x
}

function Save-TuiCodeBlocks {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Host '[No output to save]' -ForegroundColor Yellow
        return
    }

    $lines = $Text -split "`r?`n", -1
    $inCode = $false
    $language = ''
    $codeLines = New-Object System.Collections.Generic.List[string]
    $saved = 0

    foreach ($line in $lines) {
        $trim = $line.Trim()

        if ($trim -like '```*') {
            if (-not $inCode) {
                $inCode = $true
                $language = $trim.Substring(3).Trim().ToLower()
                $codeLines.Clear()
            }
            else {
                $inCode = $false

                switch ($language) {
                    'powershell' { $ext = 'ps1' }
                    'ps1'        { $ext = 'ps1' }
                    'pwsh'       { $ext = 'ps1' }
                    'bash'       { $ext = 'bash' }
                    'sh'         { $ext = 'bash' }
                    'xml'        { $ext = 'xml' }
                    'html'       { $ext = 'html' }
                    'json'       { $ext = 'json' }
                    'python'     { $ext = 'py' }
                    'py'          { $ext = 'py' }
                    'javascript' { $ext = 'js' }
                    'js'         { $ext = 'js' }
                    default      { $ext = if ($language) { $language } else { 'text' } }
                }

                $fileName = Get-TuiUniqueFileName -BaseName ('mira_' + $ext) -Extension ('.' + $ext)
                [IO.File]::WriteAllText(
                    (Join-Path (Get-Location) $fileName),
                    ([string]::Join("`r`n", $codeLines)),
                    [Text.UTF8Encoding]::new($false)
                )

                Write-Host ('[Saved: ' + $fileName + ']') -ForegroundColor Green
                ++$saved
            }
            continue
        }

        if ($inCode) {
            [void]$codeLines.Add($line)
        }
    }

    if ($saved -eq 0) {
        $fileName = Get-TuiUniqueFileName -BaseName 'mira_text' -Extension '.txt'
        [IO.File]::WriteAllText(
            (Join-Path (Get-Location) $fileName),
            $Text,
            [Text.UTF8Encoding]::new($false)
        )
        Write-Host ('[Saved: ' + $fileName + ']') -ForegroundColor Green
    }
}

function Invoke-TuiFileInfo {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Multiselect = $false
            $dialog.Title = 'Select a file for MIRA-TUI'
            if ($dialog.ShowDialog() -eq $true) {
                $Path = $dialog.FileName
            }
            else {
                Write-Host '[File selection cancelled]' -ForegroundColor Yellow
                return
            }
        }
        catch {
            Write-Host '[File dialog unavailable]' -ForegroundColor Yellow
            return
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host ('[File not found -> ' + $Path + ']') -ForegroundColor Red
        return
    }

    $item = Get-Item -LiteralPath $Path -Force

    if ($item.PSIsContainer) {
        Write-Host ('[Directory: ' + $item.FullName + ']') -ForegroundColor DarkYellow
        return
    }

    $ext = [IO.Path]::GetExtension($item.Name).ToLower()
    switch ($ext) {
        '.ps1'  { $type = 'PowerShell' }
        '.xml'  { $type = 'XML' }
        '.json' { $type = 'JSON' }
        '.txt'  { $type = 'Text' }
        default { $type = 'File' }
    }

    Write-Host ('[File: ' + $item.FullName + ']') -ForegroundColor DarkYellow
    Write-Host ('[Size: ' + $item.Length + ' bytes | Type: ' + $type + ']') -ForegroundColor Gray
}

function Invoke-TuiDiff {
    param([string]$ArgumentText)

    $parts = $ArgumentText.Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2) {
        Write-Host '[Usage: .diff "left" "right"]' -ForegroundColor Yellow
        return
    }

    $left = $parts[0].Trim('"', "'")
    $right = $parts[1].Trim('"', "'")

    if (-not (Test-Path -LiteralPath $left)) {
        Write-Host ('[File not found -> ' + $left + ']') -ForegroundColor Red
        return
    }

    if (-not (Test-Path -LiteralPath $right)) {
        Write-Host ('[File not found -> ' + $right + ']') -ForegroundColor Red
        return
    }

    try {
        $leftLines = @(Get-Content -LiteralPath $left -Encoding UTF8)
        $rightLines = @(Get-Content -LiteralPath $right -Encoding UTF8)
        $cmp = @(Compare-Object $leftLines $rightLines)

        $out = New-Object System.Collections.Generic.List[string]
        [void]$out.Add('DIFF: ' + $left + ' <-> ' + $right)

        foreach ($x in $cmp) {
            if ($x.SideIndicator -eq '<=') {
                [void]$out.Add('- ' + [string]$x.InputObject)
            }
            else {
                [void]$out.Add('+ ' + [string]$x.InputObject)
            }
        }

        if ($out.Count -eq 1) {
            [void]$out.Add('Files are identical.')
        }

        $script:TuiLastText = [string]::Join("`n", $out)
        Write-TuiText $script:TuiLastText
    }
    catch {
        Write-Host ('[Diff failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------------
# ONE-SHOT TEMPLATE
#
# The template has no AI backend. This path only proves the generic CLI shape:
# arguments/options -> text -> output, then process exit.
# ----------------------------------------------------------------------------
function Invoke-TuiOneShot {
    param(
        [string[]]$Text,
        [string]$Model,
        [bool]$Execute,
        [bool]$DryRun
    )

    $prompt = [string]::Join(' ', @($Text))

    if ([string]::IsNullOrWhiteSpace($prompt)) {
        Write-Host '[ONE-SHOT] No text supplied; starting interactive TUI.' -ForegroundColor Yellow
        return $false
    }

    if ($DryRun) {
        $request = [ordered]@{
            template = $true
            model    = $Model
            execute  = $Execute
            text     = $prompt
        }
        Write-Host ($request | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray
        return $true
    }

    Write-Host '[ONE-SHOT / TEMPLATE]' -ForegroundColor Cyan
    if ($Model) {
        Write-Host ('model: ' + $Model) -ForegroundColor DarkGray
    }
    if ($Execute) {
        Write-Host 'mode : execute' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-TuiText $prompt
    return $true
}

# ----------------------------------------------------------------------------
# SESSION SAVE
# ----------------------------------------------------------------------------
function Save-TuiSession {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'mira_session_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json'
    }
    elseif (-not $Name.EndsWith('.json')) {
        $Name += '.json'
    }

    # Never overwrite an existing session.
    $Name = Split-Path -Leaf (Get-TuiUniqueFileName -BaseName ([IO.Path]::GetFileNameWithoutExtension($Name)) -Extension '.json')

    try {
        $data = [ordered]@{
            SessionName = 'Mira-TUI'
            Created     = [DateTimeOffset]::Now.ToString('o')
            History     = @($script:TuiHistory)
        }

        $json = $data | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText((Join-Path (Get-Location) $Name), $json, [Text.UTF8Encoding]::new($false))
        Write-Host ('[Session saved: ' + $Name + ']') -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ('[Session save failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
        return $false
    }
}

# ----------------------------------------------------------------------------
# COMMAND EXECUTION
# ----------------------------------------------------------------------------
function Invoke-TuiCommand {
    param([string]$InputLine)

    $trimmed = $InputLine.Trim()

    if ($trimmed -eq 'exit' -or $trimmed -eq 'quit' -or
        $trimmed -eq '.exit' -or $trimmed -eq '.q' -or
        $trimmed -eq ':q' -or $trimmed -eq ':wq') {
        # Exit only. Session/history persistence is explicit via .savesession.
        $script:TuiRunning = $false
        return
    }

    if ($trimmed -eq '.help') {
        Show-TuiHelp
        return
    }

    if ($trimmed -eq '.info') {
        Show-TuiInfo
        return
    }

    if ($trimmed -eq 'clear' -or $trimmed -eq '.clear') {
        $script:TuiHistory.Clear()
        $script:TuiLastText = ''
        $script:TuiLastRequestJson = ''
        Write-TuiHeader
        return
    }

    if ($trimmed.StartsWith('!')) {
        $commandToRun = $trimmed.Substring(1).Trim()
        if ([string]::IsNullOrWhiteSpace($commandToRun)) {
            Show-TuiHelp
            return
        }

        Write-Host "`n[Executing local command: $commandToRun]" -ForegroundColor DarkYellow

        try {
            $cmdOutput = Invoke-Expression $commandToRun 2>&1 | Out-String -Width 4096
            $script:TuiLastText = $cmdOutput.TrimEnd()
            Write-TuiText $script:TuiLastText

            # Template stand-in for a future real API raw request.
            # In Mira this variable will contain the exact serialized payload.
            $requestObject = [ordered]@{
                test_request = $true
                timestamp = [DateTimeOffset]::Now.ToString('o')
                command = $commandToRun
                output = $script:TuiLastText
            }
            $script:TuiLastRequestJson = $requestObject | ConvertTo-Json -Depth 10
        }
        catch {
            $script:TuiLastText = '[Error] ' + $_.Exception.Message
            Write-TuiText $script:TuiLastText
        }
        return
    }

    if ($trimmed -eq '.request') {
        if ([string]::IsNullOrWhiteSpace($script:TuiLastRequestJson)) {
            Write-Host '[No raw request exists yet. Run a ! command first.]' -ForegroundColor Yellow
            return
        }

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $fileName = Get-TuiUniqueFileName -BaseName ('mira_request_' + $stamp) -Extension '.json'
        [IO.File]::WriteAllText(
            (Join-Path (Get-Location) $fileName),
            $script:TuiLastRequestJson,
            [Text.UTF8Encoding]::new($false)
        )
        Write-Host ('[Raw request saved: ' + $fileName + ']') -ForegroundColor Green
        return
    }

    if ($trimmed -eq '.save') {
        Save-TuiCodeBlocks -Text $script:TuiLastText
        return
    }

    if ($trimmed.StartsWith('.savesession')) {
        $name = $trimmed.Substring(12).Trim()
        Save-TuiSession -Name $name
        return
    }

    if ($trimmed.StartsWith('.loadsession')) {
        $name = $trimmed.Substring(12).Trim()
        if (-not $name) {
            Write-Host '[Usage: .loadsession <file>]' -ForegroundColor Yellow
            return
        }

        if (-not $name.EndsWith('.json')) { $name += '.json' }

        if (-not (Test-Path -LiteralPath $name)) {
            Write-Host ('[Session not found -> ' + $name + ']') -ForegroundColor Red
            return
        }

        try {
            $data = Get-Content -LiteralPath $name -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:TuiHistory.Clear()
            foreach ($item in @($data.History)) {
                [void]$script:TuiHistory.Add([string]$item)
            }
            Write-Host ('[Session loaded: ' + $name + ']') -ForegroundColor Green
        }
        catch {
            Write-Host ('[Session load failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
        }
        return
    }

    if ($trimmed -eq '.file' -or $trimmed.StartsWith('.file ')) {
        $arg = if ($trimmed.Length -gt 5) { $trimmed.Substring(5).Trim() } else { '' }
        Invoke-TuiFileInfo -Path (Get-TuiPathArgument $arg)
        return
    }

    if ($trimmed -eq '.text' -or $trimmed.StartsWith('.text ')) {
        $arg = if ($trimmed.Length -gt 5) { $trimmed.Substring(5).Trim() } else { '' }
        $path = Get-TuiPathArgument $arg

        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-Host '[Usage: .text <path>]' -ForegroundColor Yellow
            return
        }

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host ('[File not found -> ' + $path + ']') -ForegroundColor Red
            return
        }

        try {
            $script:TuiLastText = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            Write-TuiText $script:TuiLastText
        }
        catch {
            Write-Host ('[Text load failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
        }
        return
    }

    if ($trimmed -eq '.diff' -or $trimmed.StartsWith('.diff ')) {
        $arg = if ($trimmed.Length -gt 5) { $trimmed.Substring(5).Trim() } else { '' }
        Invoke-TuiDiff -ArgumentText $arg
        return
    }

    if ($trimmed -eq '.shot' -or $trimmed.StartsWith('.shot ')) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $img = [System.Windows.Forms.Clipboard]::GetImage()

            if ($null -eq $img) {
                Write-Host '[No image found on clipboard]' -ForegroundColor Red
                return
            }

            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $fileName = Get-TuiUniqueFileName -BaseName ('mira_shot_' + $stamp) -Extension '.png'
            $img.Save((Join-Path (Get-Location) $fileName), [System.Drawing.Imaging.ImageFormat]::Png)
            $img.Dispose()
            Write-Host ('[Screenshot saved: ' + $fileName + ']') -ForegroundColor Green
        }
        catch {
            Write-Host ('[Screenshot failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
        }
        return
    }

    if ($trimmed -eq '.mira-update') {
        Write-Host '[Persona data intentionally absent from the universal template.]' -ForegroundColor Yellow
        return
    }

    # Normal text: display it as data. Never execute it.
    $script:TuiLastText = $InputLine
    Write-TuiText $script:TuiLastText
}

# ----------------------------------------------------------------------------
# INPUT EDITOR
# ----------------------------------------------------------------------------
function Read-TuiLine {
    $oldTreatControlCAsInput = $false
    $hadOriginal = $false

    try {
        $oldTreatControlCAsInput = [Console]::TreatControlCAsInput
        $hadOriginal = $true
        [Console]::TreatControlCAsInput = $true
    }
    catch {}

    try {
        $buffer = ''
        $cursor = 0
        $row = Get-TuiCursorTop

        [Console]::Write('You: ')

        while ($true) {
            $key = $null
            $completionDismissedThisKey = $false

            try {
                $key = Read-TuiKey
            }
            catch {
                Write-Host ('[TUI input failed: ' + $_.Exception.Message + ']') -ForegroundColor Red
                Write-Host '[TUI remains active; key input backend is unavailable.]' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 250
                continue
            }

            # Ctrl+Enter / Ctrl+J must be recognized BEFORE completion-menu
            # cleanup.  Some ConHost/RawUI combinations report Ctrl+J as LF
            # (KeyChar=10), while others report J with Control.  Ctrl+Enter is
            # reported as Enter+Control.  Keep this path independent from the
            # completion UI so Tab/menu state can never break multiline input.
            $isCtrlEnter = ($key.Key -eq [ConsoleKey]::Enter -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0))
            $isCtrlJ = (($key.Key -eq [ConsoleKey]::J -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) -or
                ([int][char]$key.KeyChar -eq 10))

            if ($isCtrlEnter -or $isCtrlJ) {
                if ($script:TuiCompletionMenuVisible) {
                    try { Clear-TuiCompletionMenu } catch {}
                }
                $buffer = $buffer.Insert($cursor, "`n")
                ++$cursor
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            # Completion menu is temporary UI. Any key except Tab dismisses it
            # before the normal editor handler runs. The completion state is
            # cleared atomically so the next printable key cannot inherit stale
            # completion data from the previous menu.
            if ($script:TuiCompletionMenuVisible -and $key.Key -ne [ConsoleKey]::Tab) {
                try { Clear-TuiCompletionMenu } catch {
                    # Even if console cleanup fails, force the logical state off.
                    $script:TuiCompletionMenuVisible = $false
                    $script:TuiCompletionMenuTop = 0
                    $script:TuiCompletionMenuRows = 0
                    $script:TuiCompletionBuffer = $null
                    $script:TuiCompletionCursor = $null
                    $script:TuiCompletionRow = $null
                }
                $completionDismissedThisKey = $true
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
            }

            # ------------------------------------------------------------------
            # Small Emacs-style movement/editing layer.
            # Ctrl+B/F = char left/right
            # Ctrl+A/E = start/end of current line
            # Alt+B/F  = previous/next word
            # Ctrl+K   = kill to end of current line
            # Ctrl+U   = kill to start of current line
            # Ctrl+W   = delete previous word
            # ------------------------------------------------------------------
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0) {
                switch ($key.Key) {
                    ([ConsoleKey]::B) {
                        if ($cursor -gt 0) { --$cursor; Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row }
                        continue
                    }
                    ([ConsoleKey]::F) {
                        if ($cursor -lt $buffer.Length) { ++$cursor; Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row }
                        continue
                    }
                    ([ConsoleKey]::A) {
                        $before = $buffer.Substring(0, $cursor)
                        $nl = $before.LastIndexOf("`n")
                        $cursor = if ($nl -lt 0) { 0 } else { $nl + 1 }
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        continue
                    }
                    ([ConsoleKey]::E) {
                        $nl = $buffer.IndexOf("`n", $cursor)
                        $cursor = if ($nl -lt 0) { $buffer.Length } else { $nl }
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        continue
                    }
                    ([ConsoleKey]::K) {
                        $nl = $buffer.IndexOf("`n", $cursor)
                        if ($nl -lt 0) { $buffer = $buffer.Substring(0, $cursor) }
                        else { $buffer = $buffer.Remove($cursor, $nl - $cursor) }
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        continue
                    }
                    ([ConsoleKey]::U) {
                        $before = $buffer.Substring(0, $cursor)
                        $nl = $before.LastIndexOf("`n")
                        $start = if ($nl -lt 0) { 0 } else { $nl + 1 }
                        $buffer = $buffer.Remove($start, $cursor - $start)
                        $cursor = $start
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        continue
                    }
                    ([ConsoleKey]::W) {
                        if ($cursor -gt 0) {
                            $i = $cursor
                            while ($i -gt 0 -and [Char]::IsWhiteSpace($buffer[$i-1])) { --$i }
                            while ($i -gt 0 -and -not [Char]::IsWhiteSpace($buffer[$i-1])) { --$i }
                            $buffer = $buffer.Remove($i, $cursor - $i)
                            $cursor = $i
                            Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        }
                        continue
                    }
                }
            }

            # Alt+B / Alt+F = move by words.
            if (($key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0) {
                if ($key.Key -eq [ConsoleKey]::B) {
                    $i = $cursor
                    while ($i -gt 0 -and [Char]::IsWhiteSpace($buffer[$i-1])) { --$i }
                    while ($i -gt 0 -and -not [Char]::IsWhiteSpace($buffer[$i-1])) { --$i }
                    $cursor = $i
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    continue
                }
                if ($key.Key -eq [ConsoleKey]::F) {
                    $i = $cursor
                    while ($i -lt $buffer.Length -and -not [Char]::IsWhiteSpace($buffer[$i])) { ++$i }
                    while ($i -lt $buffer.Length -and [Char]::IsWhiteSpace($buffer[$i])) { ++$i }
                    $cursor = $i
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    continue
                }
            }

            # Ctrl+H = Emacs backward-delete-character.
            if ($key.Key -eq [ConsoleKey]::H -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                if ($cursor -gt 0) {
                    $buffer = $buffer.Remove($cursor - 1, 1)
                    --$cursor
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                else {
                    try { [Console]::Beep(700, 50) } catch {}
                }
                continue
            }

            # Ctrl+D = Emacs delete-forward. Never exit the application.
            if ($key.Key -eq [ConsoleKey]::D -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                if ($cursor -lt $buffer.Length) {
                    $buffer = $buffer.Remove($cursor, 1)
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                else {
                    try { [Console]::Beep(700, 50) } catch {}
                }
                continue
            }

            # Ctrl+C = clear current line, do not terminate the application.
            if ($key.Key -eq [ConsoleKey]::C -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                $buffer = ''
                $cursor = 0
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Enter) {
                [Console]::Write("`r`n")
                return $buffer
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($cursor -gt 0) {
                    $buffer = $buffer.Remove($cursor - 1, 1)
                    --$cursor
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Delete) {
                if ($cursor -lt $buffer.Length) {
                    $buffer = $buffer.Remove($cursor, 1)
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::LeftArrow) {
                if ($cursor -gt 0) {
                    --$cursor
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::RightArrow) {
                if ($cursor -lt $buffer.Length) {
                    ++$cursor
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Home) {
                $cursor = 0
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            if ($key.Key -eq [ConsoleKey]::End) {
                $cursor = $buffer.Length
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            $historyPrevious = ($key.Key -eq [ConsoleKey]::UpArrow -or
                ($key.Key -eq [ConsoleKey]::P -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)))
            $historyNext = ($key.Key -eq [ConsoleKey]::DownArrow)

            if (($script:TuiHistorySearchActive) -and -not ($historyPrevious -or $historyNext)) {
                Reset-TuiHistorySearch
            }

            if ($historyPrevious) {
                if ($script:TuiHistory.Count -eq 0) {
                    try { [Console]::Beep(700, 50) } catch {}
                    continue
                }

                # Non-empty input starts prefix history search. Empty input keeps
                # the traditional whole-history navigation behavior.
                if (-not $script:TuiHistorySearchActive -and
                    -not [string]::IsNullOrEmpty($buffer)) {
                    $script:TuiHistorySearchActive = $true
                    $script:TuiHistorySearchPrefix = $buffer
                    $script:TuiHistorySearchIndex = $script:TuiHistory.Count
                    $script:TuiHistoryDraft = $buffer
                }

                if ($script:TuiHistorySearchActive) {
                    $found = $false
                    $start = $script:TuiHistorySearchIndex - 1

                    for ($i = $start; $i -ge 0; --$i) {
                        if ($script:TuiHistory[$i].StartsWith(
                            $script:TuiHistorySearchPrefix,
                            [StringComparison]::OrdinalIgnoreCase)) {
                            $script:TuiHistorySearchIndex = $i
                            $buffer = $script:TuiHistory[$i]
                            $cursor = $buffer.Length
                            $found = $true
                            break
                        }
                    }

                    if (-not $found) {
                        try { [Console]::Beep(700, 50) } catch {}
                    }
                }
                else {
                    if ($script:TuiHistoryIndex -eq -1) {
                        $script:TuiHistoryDraft = $buffer
                        $script:TuiHistoryIndex = $script:TuiHistory.Count - 1
                    }
                    elseif ($script:TuiHistoryIndex -gt 0) {
                        --$script:TuiHistoryIndex
                    }

                    $buffer = $script:TuiHistory[$script:TuiHistoryIndex]
                    $cursor = $buffer.Length
                }

                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            if ($historyNext) {
                if ($script:TuiHistorySearchActive) {
                    $found = $false
                    $start = $script:TuiHistorySearchIndex + 1

                    for ($i = $start; $i -lt $script:TuiHistory.Count; ++$i) {
                        if ($script:TuiHistory[$i].StartsWith(
                            $script:TuiHistorySearchPrefix,
                            [StringComparison]::OrdinalIgnoreCase)) {
                            $script:TuiHistorySearchIndex = $i
                            $buffer = $script:TuiHistory[$i]
                            $cursor = $buffer.Length
                            $found = $true
                            break
                        }
                    }

                    if (-not $found) {
                        $buffer = $script:TuiHistoryDraft
                        $cursor = $buffer.Length
                        Reset-TuiHistorySearch
                    }

                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    continue
                }

                if ($script:TuiHistoryIndex -eq -1) {
                    try { [Console]::Beep(700, 50) } catch {}
                    continue
                }

                if ($script:TuiHistoryIndex -lt ($script:TuiHistory.Count - 1)) {
                    ++$script:TuiHistoryIndex
                    $buffer = $script:TuiHistory[$script:TuiHistoryIndex]
                }
                else {
                    $buffer = $script:TuiHistoryDraft
                    $script:TuiHistoryIndex = -1
                }

                $cursor = $buffer.Length
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Tab) {
                if ($cursor -ne $buffer.Length) {
                    continue
                }

                # Repeated Tab starts a fresh completion request from the
                # current buffer. Clear only the previous temporary menu/state.
                if ($script:TuiCompletionMenuVisible) {
                    Clear-TuiCompletionMenu
                    [void](Set-TuiCursorPosition -X 0 -Y $row)
                    Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                }

                # Empty prompt: show the available TUI commands directly.
                # This is the cheap aichat-like discovery path for a bare Tab.
                if ($buffer.Length -eq 0) {
                    $menuItems = @($script:TuiCommands | ForEach-Object {
                        [pscustomobject]@{ Name = $_; PSIsContainer = $false }
                    })
                    Show-TuiCompletionMenu -Items $menuItems -PromptRow $row -Buffer $buffer -Cursor $cursor
                    continue
                }

                if ($buffer -match '^\.[^\s]*$') {
                    $matches = @(Get-TuiCommandMatches -Prefix $buffer)
                    if ($matches.Count -eq 1) {
                        $buffer = $matches[0]
                        $cursor = $buffer.Length

                        # Path-taking TUI commands enter argument mode after
                        # completion of the command name. This makes `.file<Tab>`
                        # immediately behave like `.file <Tab>`.
                        if ($matches[0] -in @('.file','.text','.diff','.savesession','.loadsession')) {
                            $buffer += ' '
                            ++$cursor
                        }

                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    }
                    elseif ($matches.Count -gt 1) {
                        $names = @($matches)
                        $common = Get-TuiLongestCommonPrefix -Values $names
                        if ($common.Length -gt $buffer.Length) {
                            $buffer = $common
                            $cursor = $buffer.Length
                            Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        }
                        else {
                            # Small command menu uses the same temporary pane.
                            $menuItems = @($matches | ForEach-Object {
                                [pscustomobject]@{ Name = $_; PSIsContainer = $false }
                            })
                            Show-TuiCompletionMenu -Items $menuItems -PromptRow $row -Buffer $buffer -Cursor $cursor
                        }
                    }
                    else {
                        try { [Console]::Beep(700, 50) } catch {}
                    }
                    continue
                }

                if ($buffer -match '^!(.*)$') {
                    $prefix = $Matches[1]
                    $commands = @(Get-Command -CommandType Cmdlet,Function,Alias,Filter,ExternalScript,Application `
                        -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
                        Sort-Object Name -Unique |
                        Select-Object -ExpandProperty Name)

                    if ($commands.Count -eq 1) {
                        $buffer = '!' + $commands[0]
                        $cursor = $buffer.Length
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    }
                    elseif ($commands.Count -gt 1) {
                        $common = Get-TuiLongestCommonPrefix -Values @($commands)
                        $candidate = '!' + $common
                        if ($candidate.Length -gt $buffer.Length) {
                            $buffer = $candidate
                            $cursor = $buffer.Length
                            Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                        }
                        else {
                            $menuItems = @($commands | ForEach-Object {
                                [pscustomobject]@{ Name = $_; PSIsContainer = $false }
                            })
                            Show-TuiCompletionMenu -Items $menuItems -PromptRow $row -Buffer $buffer -Cursor $cursor
                        }
                    }
                    else {
                        try { [Console]::Beep(700, 50) } catch {}
                    }
                    continue
                }

                if ($buffer -match '^\.(file|text|diff|savesession|loadsession)(?:\s|$)') {
                    $commandName = '.' + $Matches[1]

                    # Completion must never be able to terminate the TUI.
                    try {
                        $script:TuiCompletionBuffer = $null
                        $script:TuiCompletionCursor = $null
                        $script:TuiCompletionRow = $null
                        [void](Complete-TuiPathArgument -Buffer $buffer -Cursor $cursor -CommandName $commandName -Row $row)
                    }
                    catch {
                        try { Clear-TuiCompletionMenu } catch {}
                        try { [Console]::Beep(700, 50) } catch {}
                    }

                    if ($script:TuiCompletionBuffer) {
                        $buffer = $script:TuiCompletionBuffer
                        $cursor = $script:TuiCompletionCursor
                        Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
                    }
                    # Keep menu visibility independent from the one-shot result;
                    # only the temporary payload itself is consumed here.
                    $script:TuiCompletionBuffer = $null
                    $script:TuiCompletionCursor = $null
                    $script:TuiCompletionRow = $null
                    continue
                }

                try { [Console]::Beep(700, 50) } catch {}
                continue
            }

            if (-not [Char]::IsControl($key.KeyChar)) {
                if ($cursor -eq $buffer.Length) {
                    $buffer += $key.KeyChar
                }
                else {
                    $buffer = $buffer.Insert($cursor, [string]$key.KeyChar)
                }

                ++$cursor

                # Consume already queued printable events as a paste burst.
                # We keep every printable character inside our own buffer.
                # After dismissing a completion menu, do not consume another
                # queued event in the same key-cycle; that event may be a stale
                # terminal completion key and must be handled independently.
                if (-not $completionDismissedThisKey) {
                while ($true) {
                    $available = $false
                    try { $available = Test-TuiKeyAvailable } catch { break }
                    if (-not $available) { break }

                    $pasteKey = Read-TuiKey

                    if ($pasteKey.Key -eq [ConsoleKey]::C -and
                        (($pasteKey.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                        $buffer = ''
                        $cursor = 0
                        break
                    }

                    if ($pasteKey.Key -eq [ConsoleKey]::D -and
                        (($pasteKey.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                        if ($cursor -lt $buffer.Length) {
                            $buffer = $buffer.Remove($cursor, 1)
                        }
                        continue
                    }

                    # Enter events that arrive while printable input is queued
                    # are part of a multiline paste burst. Keep them inside our
                    # own buffer instead of submitting after the first line.
                    if ($pasteKey.Key -eq [ConsoleKey]::Enter) {
                        $buffer = $buffer.Insert($cursor, "`n")
                        ++$cursor
                        continue
                    }

                    if (-not [Char]::IsControl($pasteKey.KeyChar)) {
                        if ($cursor -eq $buffer.Length) {
                            $buffer += $pasteKey.KeyChar
                        }
                        else {
                            $buffer = $buffer.Insert($cursor, [string]$pasteKey.KeyChar)
                        }
                        ++$cursor
                    }
                }

                }
                Redraw-TuiLine -Buffer $buffer -Cursor $cursor -Row $row
            }
        }
    }
    finally {
        if ($hadOriginal) {
            try { [Console]::TreatControlCAsInput = $oldTreatControlCAsInput } catch {}
        }
    }
}

# ----------------------------------------------------------------------------
# INPUT REDRAW
# ----------------------------------------------------------------------------
function Redraw-TuiLine {
    param(
        [string]$Buffer,
        [int]$Cursor,
        [int]$Row
    )

    $promptWidth = 5
    $width = Get-TuiWindowWidth
    $available = [Math]::Max(10, $width - $promptWidth - 1)

    $parts = $Buffer -split "`n", -1
    $beforeCursor = if ($Cursor -gt 0) { $Buffer.Substring(0, $Cursor) } else { '' }
    $beforeLines = $beforeCursor -split "`n", -1
    $cursorLine = $beforeLines.Count - 1
    $cursorColumnInLine = $beforeLines[-1].Length

    # Clear every visual row currently owned by the editor.
    $clearRows = [Math]::Max($parts.Count, 1)
    for ($r = 0; $r -lt $clearRows; ++$r) {
        if (Set-TuiCursorPosition -X $promptWidth -Y ($Row + $r)) {
            [Console]::Write((' ' * $available))
        }
    }

    for ($r = 0; $r -lt $parts.Count; ++$r) {
        $line = $parts[$r]
        $start = 0

        if ($r -eq $cursorLine -and $line.Length -gt $available) {
            $start = [Math]::Max(0, $cursorColumnInLine - $available + 1)
        }
        elseif ($line.Length -gt $available) {
            $start = [Math]::Max(0, $line.Length - $available)
        }

        $shown = if ($start -lt $line.Length) {
            $line.Substring($start, [Math]::Min($available, $line.Length - $start))
        }
        else { '' }

        if (Set-TuiCursorPosition -X $promptWidth -Y ($Row + $r)) {
            [Console]::Write($shown)
        }
    }

    $displayColumn = $cursorColumnInLine
    $displayStart = 0
    if ($cursorColumnInLine -ge $available) {
        $displayStart = $cursorColumnInLine - $available + 1
    }
    $displayColumn -= $displayStart
    if ($displayColumn -lt 0) { $displayColumn = 0 }
    if ($displayColumn -gt $available) { $displayColumn = $available }

    $cursorX = $promptWidth + $displayColumn
    if ($cursorX -ge $width) { $cursorX = $width - 1 }
    [void](Set-TuiCursorPosition -X $cursorX -Y ($Row + $cursorLine))
}

# ----------------------------------------------------------------------------
# DEMO
# ----------------------------------------------------------------------------
function Show-TuiDemo {
    $demo = @'
Ось звичайний текст.

**FFN (Feed-Forward Networks) та активація:** це акцентований фрагмент.

Тут є XML-like штуки: <P1_FOUNDATION> <USER_CONTEXT mode="test"> </USER_CONTEXT>.

```powershell
# Code mode: Markdown/XML are not parsed here.
if ($x -match "'") {
    Write-Host "**not bold** <not-a-tag>"
}
```

Після code block renderer знову працює: **акцент** і <RETURN_TO_NORMAL>.
'@

    $script:TuiLastText = $demo
    Write-TuiText $demo
}

# ----------------------------------------------------------------------------
# START
# ----------------------------------------------------------------------------
$cliMode = $false
$oneShotDone = $false

if ($args.Count -gt 0) {
    try {
        $parsed = Parse-TuiArguments -Arguments $args
        $script:TuiCli.Model = $parsed.Model
        $script:TuiCli.Execute = [bool]$parsed.Execute
        $script:TuiCli.Help = [bool]$parsed.Help
        $script:TuiCli.DryRun = [bool]$parsed.DryRun
        $script:TuiCli.Text = @($parsed.Text)
        $cliMode = $true
    }
    catch {
        Write-Host ('MIRA-TUI: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Use -h/--help for CLI usage.' -ForegroundColor Yellow
        exit 2
    }
}

if ($cliMode -and $script:TuiCli.Help) {
    Show-TuiHelp
    exit 0
}

if ($cliMode -and $script:TuiCli.Text.Count -gt 0) {
    $oneShotDone = Invoke-TuiOneShot -Text $script:TuiCli.Text -Model $script:TuiCli.Model -Execute $script:TuiCli.Execute -DryRun $script:TuiCli.DryRun
    if ($oneShotDone) {
        exit 0
    }
}

Write-TuiHeader

try {
    while ($script:TuiRunning) {
        $script:TuiHistoryIndex = -1
        $script:TuiHistoryDraft = ''

        $line = Read-TuiLine

        if ($null -eq $line) {
            Write-Host 'MIRA-TUI: input ended; exit' -ForegroundColor Yellow
            break
        }

        if ([string]::IsNullOrEmpty($line)) {
            continue
        }

        Add-TuiHistory $line

        Write-Host ''
        Invoke-TuiCommand -InputLine $line
        Write-Host ''
    }
}
catch {
    Write-Host ('MIRA-TUI fatal error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
