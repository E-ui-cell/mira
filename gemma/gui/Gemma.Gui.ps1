#requires -Version 5.1
[CmdletBinding()]
param()

# GEMMA native desktop UI: Windows PowerShell 5.1 + WinForms.
# No terminal readline, browser shell, external module, or persistent chat context.

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $fileArgument = [char]34 + $PSCommandPath + [char]34
    Start-Process -FilePath $powerShellExe -ArgumentList @(
        '-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$fileArgument
    ) -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:GemmaGuiRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:GemmaGuiConfigPath = Join-Path (Join-Path $HOME '.gemma') 'gemma-gui.json'

$script:GemmaGuiThemes = [ordered]@{
    'Gruvbox Dark' = @{
        Background='#282828'; Surface='#3C3836'; Input='#32302F'; Foreground='#EBDBB2'
        Muted='#A89984'; Accent='#FABD2F'; User='#83A598'; Assistant='#B8BB26'; Error='#FB4934'; Border='#504945'
    }
    'Solarized Dark' = @{
        Background='#002B36'; Surface='#073642'; Input='#002B36'; Foreground='#839496'
        Muted='#586E75'; Accent='#B58900'; User='#268BD2'; Assistant='#859900'; Error='#DC322F'; Border='#586E75'
    }
    'Solarized Light' = @{
        Background='#FDF6E3'; Surface='#EEE8D5'; Input='#FDF6E3'; Foreground='#586E75'
        Muted='#93A1A1'; Accent='#B58900'; User='#268BD2'; Assistant='#859900'; Error='#DC322F'; Border='#D3CBB7'
    }
    'Dracula' = @{
        Background='#282A36'; Surface='#343746'; Input='#21222C'; Foreground='#F8F8F2'
        Muted='#9A9BA7'; Accent='#BD93F9'; User='#8BE9FD'; Assistant='#50FA7B'; Error='#FF5555'; Border='#44475A'
    }
    'Nord' = @{
        Background='#2E3440'; Surface='#3B4252'; Input='#2E3440'; Foreground='#D8DEE9'
        Muted='#A3BE8C'; Accent='#88C0D0'; User='#81A1C1'; Assistant='#A3BE8C'; Error='#BF616A'; Border='#4C566A'
    }
    'One Dark' = @{
        Background='#282C34'; Surface='#21252B'; Input='#1E2227'; Foreground='#ABB2BF'
        Muted='#5C6370'; Accent='#61AFEF'; User='#56B6C2'; Assistant='#98C379'; Error='#E06C75'; Border='#3E4451'
    }
}

function Get-GemmaGuiDefaultConfig {
    return @{
        Provider = 'antigravity'
        Model = 'gemini-3.1-flash-lite'
        Effort = 'high'
        Theme = 'Gruvbox Dark'
        FontFamily = 'Consolas'
        FontSize = 10.5
        WindowWidth = 1120
        WindowHeight = 780
        WindowX = -1
        WindowY = -1
        SystemPromptFile = ''
        CustomThemes = @{}
    }
}

function Import-GemmaGuiConfig {
    $defaults = Get-GemmaGuiDefaultConfig
    $directory = Split-Path -Parent $script:GemmaGuiConfigPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $script:GemmaGuiConfigPath -PathType Leaf)) {
        $example = Join-Path $PSScriptRoot 'config.example.json'
        if (Test-Path -LiteralPath $example -PathType Leaf) {
            Copy-Item -LiteralPath $example -Destination $script:GemmaGuiConfigPath
        } else {
            $defaults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:GemmaGuiConfigPath -Encoding UTF8
        }
    }

    try {
        $loaded = Get-Content -LiteralPath $script:GemmaGuiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $loaded.PSObject.Properties) {
            if ($defaults.ContainsKey($property.Name) -and $null -ne $property.Value) {
                $defaults[$property.Name] = $property.Value
            }
        }
    } catch {
        $nl = [Environment]::NewLine
        $message = 'The external configuration could not be read. Defaults will be used.' + $nl + $nl + $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'GEMMA configuration',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    if ($defaults.Provider -notin @('antigravity','gemini')) { $defaults.Provider = 'antigravity' }
    if ($defaults.Effort -notin @('low','medium','high')) { $defaults.Effort = 'high' }
    # User-defined themes in config.json override or extend the built-in presets.
    if ($null -ne $defaults.CustomThemes) {
        foreach ($custom in $defaults.CustomThemes.PSObject.Properties) {
            if ($null -eq $custom.Value) { continue }
            $theme = @{}
            foreach ($key in @('Background','Surface','Input','Foreground','Muted','Accent','User','Assistant','Error','Border')) {
                $value = $custom.Value.PSObject.Properties[$key]
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) {
                    $theme[$key] = [string]$value.Value
                }
            }
            if ($theme.Count -eq 10) { $script:GemmaGuiThemes[$custom.Name] = $theme }
        }
    }

    if (-not $script:GemmaGuiThemes.Contains($defaults.Theme)) { $defaults.Theme = 'Gruvbox Dark' }
    return $defaults
}

function Save-GemmaGuiConfig {
    if ($null -eq $script:GemmaGui) { return }
    $config = $script:GemmaGui.Config
    if ($null -ne $script:GemmaGui.Form -and $script:GemmaGui.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $config.WindowWidth = $script:GemmaGui.Form.Width
        $config.WindowHeight = $script:GemmaGui.Form.Height
        $config.WindowX = $script:GemmaGui.Form.Left
        $config.WindowY = $script:GemmaGui.Form.Top
    }

    $saved = [ordered]@{
        Provider = [string]$config.Provider
        Model = [string]$config.Model
        Effort = [string]$config.Effort
        Theme = [string]$config.Theme
        FontFamily = [string]$config.FontFamily
        FontSize = [double]$config.FontSize
        WindowWidth = [int]$config.WindowWidth
        WindowHeight = [int]$config.WindowHeight
        WindowX = [int]$config.WindowX
        WindowY = [int]$config.WindowY
        SystemPromptFile = [string]$config.SystemPromptFile
        CustomThemes = $config.CustomThemes
    }

    try {
        $directory = Split-Path -Parent $script:GemmaGuiConfigPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $saved | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:GemmaGuiConfigPath -Encoding UTF8
    } catch {
        Set-GemmaGuiStatus ("Could not save config: " + $_.Exception.Message)
    }
}

function ConvertTo-GemmaGuiColor {
    param([string]$Value)
    return [System.Drawing.ColorTranslator]::FromHtml($Value)
}

function Set-GemmaGuiStatus {
    param([string]$Text)
    if ($null -ne $script:GemmaGui -and $null -ne $script:GemmaGui.StatusLabel) {
        $script:GemmaGui.StatusLabel.Text = $Text
    }
}

function Set-GemmaGuiMenuColors {
    param([System.Windows.Forms.ToolStripItemCollection]$Items,[hashtable]$Theme)
    foreach ($item in $Items) {
        $item.BackColor = ConvertTo-GemmaGuiColor $Theme.Surface
        $item.ForeColor = ConvertTo-GemmaGuiColor $Theme.Foreground
        if ($item -is [System.Windows.Forms.ToolStripMenuItem] -and $item.DropDownItems.Count -gt 0) {
            Set-GemmaGuiMenuColors -Items $item.DropDownItems -Theme $Theme
        }
    }
}

function Apply-GemmaGuiTheme {
    $g = $script:GemmaGui
    $theme = $script:GemmaGuiThemes[[string]$g.Config.Theme]
    if ($null -eq $theme) { return }

    $background = ConvertTo-GemmaGuiColor $theme.Background
    $surface = ConvertTo-GemmaGuiColor $theme.Surface
    $inputColor = ConvertTo-GemmaGuiColor $theme.Input
    $foreground = ConvertTo-GemmaGuiColor $theme.Foreground
    $muted = ConvertTo-GemmaGuiColor $theme.Muted
    $accent = ConvertTo-GemmaGuiColor $theme.Accent
    $border = ConvertTo-GemmaGuiColor $theme.Border

    $g.Form.BackColor = $background
    $g.Form.ForeColor = $foreground
    $g.Toolbar.BackColor = $surface
    $g.BottomPanel.BackColor = $surface
    $g.Transcript.BackColor = $background
    $g.Transcript.ForeColor = $foreground
    $g.Prompt.BackColor = $inputColor
    $g.Prompt.ForeColor = $foreground
    $g.StatusPanel.BackColor = $surface
    $g.StatusLabel.ForeColor = $muted
    $g.ProviderLabel.ForeColor = $muted
    $g.ModelLabel.ForeColor = $muted
    $g.EffortLabel.ForeColor = $muted
    $g.OneShotLabel.ForeColor = $accent

    foreach ($button in @($g.SendButton,$g.StopButton,$g.SpeakButton,$g.ReplayButton)) {
        $button.BackColor = $surface
        $button.ForeColor = $accent
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderColor = $border
    }
    foreach ($control in @($g.ProviderCombo,$g.ModelBox,$g.EffortCombo)) {
        $control.BackColor = $inputColor
        $control.ForeColor = $foreground
    }
    $g.Menu.BackColor = $surface
    $g.Menu.ForeColor = $foreground
    Set-GemmaGuiMenuColors -Items $g.Menu.Items -Theme $theme
}

function Set-GemmaGuiTheme {
    param([string]$Name)
    if (-not $script:GemmaGuiThemes.Contains($Name)) { return }
    $script:GemmaGui.Config.Theme = $Name
    Apply-GemmaGuiTheme
    Save-GemmaGuiConfig
    Set-GemmaGuiStatus ("Theme: " + $Name + "  |  One-shot mode")
}

function Set-GemmaGuiFont {
    param([string]$Family,[double]$Size)
    if ([string]::IsNullOrWhiteSpace($Family)) { return }
    $Size = [Math]::Max(8,[Math]::Min(24,$Size))
    try {
        $font = [System.Drawing.Font]::new($Family,[single]$Size,[System.Drawing.FontStyle]::Regular)
    } catch {
        $font = [System.Drawing.Font]::new('Consolas',[single]$Size,[System.Drawing.FontStyle]::Regular)
        $Family = 'Consolas'
    }
    $script:GemmaGui.EditorFont = $font
    $script:GemmaGui.Config.FontFamily = $Family
    $script:GemmaGui.Config.FontSize = $Size
    $script:GemmaGui.Transcript.Font = $font
    $script:GemmaGui.Prompt.Font = $font
    Save-GemmaGuiConfig
}

function Append-GemmaGuiMessage {
    param(
        [ValidateSet('user','assistant','error','system')][string]$Role,
        [string]$Text
    )
    $g = $script:GemmaGui
    $theme = $script:GemmaGuiThemes[[string]$g.Config.Theme]
    $colorHex = switch ($Role) {
        'user' { $theme.User }
        'assistant' { $theme.Assistant }
        'error' { $theme.Error }
        default { $theme.Muted }
    }

    $box = $g.Transcript
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $headingFont = [System.Drawing.Font]::new($g.EditorFont,[System.Drawing.FontStyle]::Bold)
    $box.SelectionFont = $headingFont
    $box.SelectionColor = ConvertTo-GemmaGuiColor $colorHex
    $heading = switch ($Role) {
        'user' { 'YOU' }
        'assistant' { 'GEMMA' }
        'error' { 'ERROR' }
        default { 'INFO' }
    }
    $box.AppendText($heading + [Environment]::NewLine)
    $box.SelectionFont = $g.EditorFont
    $box.SelectionColor = ConvertTo-GemmaGuiColor $theme.Foreground
    $box.AppendText($Text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine)
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Set-GemmaGuiBusy {
    param([bool]$Busy)
    $g = $script:GemmaGui
    $g.SendButton.Enabled = -not $Busy
    $g.StopButton.Enabled = $Busy
    $g.SpeakButton.Enabled = (-not $Busy -and -not [string]::IsNullOrWhiteSpace($g.LastReply))
    $g.ReplayButton.Enabled = (-not $Busy -and -not [string]::IsNullOrWhiteSpace($g.LastReply))
    $g.ProviderCombo.Enabled = -not $Busy
    $g.ModelBox.Enabled = -not $Busy
    $g.EffortCombo.Enabled = -not $Busy
}

function Start-GemmaGuiWorker {
    param(
        [ValidateSet('chat','speak','replay')][string]$Kind,
        [string]$Prompt = ''
    )

    $g = $script:GemmaGui
    if ($null -ne $g.WorkerPowerShell) { return }
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace

    if ($Kind -eq 'chat') {
        $workerPath = Join-Path $g.RootPath 'gui\Backend.ps1'
        $scriptText = 'param($workerPath,$rootPath,$provider,$model,$effort,$prompt,$systemPromptPath); & $workerPath -RootPath $rootPath -Provider $provider -Model $model -Effort $effort -Prompt $prompt -SystemPromptPath $systemPromptPath'
        [void]$ps.AddScript($scriptText)
        [void]$ps.AddArgument($workerPath)
        [void]$ps.AddArgument($g.RootPath)
        [void]$ps.AddArgument([string]$g.Config.Provider)
        [void]$ps.AddArgument([string]$g.Config.Model)
        [void]$ps.AddArgument([string]$g.Config.Effort)
        [void]$ps.AddArgument($Prompt)
        [void]$ps.AddArgument([string]$g.Config.SystemPromptFile)
    } else {
        $workerPath = Join-Path $g.RootPath 'gui\TtsWorker.ps1'
        $scriptText = 'param($workerPath,$rootPath,$userText,$assistantText,$replayOnly); if ($replayOnly) { & $workerPath -RootPath $rootPath -UserText $userText -AssistantText $assistantText -ReplayOnly } else { & $workerPath -RootPath $rootPath -UserText $userText -AssistantText $assistantText }'
        [void]$ps.AddScript($scriptText)
        [void]$ps.AddArgument($workerPath)
        [void]$ps.AddArgument($g.RootPath)
        [void]$ps.AddArgument([string]$g.LastPrompt)
        [void]$ps.AddArgument([string]$g.LastReply)
        [void]$ps.AddArgument([bool]($Kind -eq 'replay'))
    }

    $g.WorkerKind = $Kind
    $g.WorkerPowerShell = $ps
    $g.WorkerRunspace = $runspace
    $g.WorkerAsync = $ps.BeginInvoke()
    Set-GemmaGuiBusy -Busy $true
    if ($Kind -eq 'chat') {
        Set-GemmaGuiStatus 'Working... the window remains responsive. Each request is independent.'
    } elseif ($Kind -eq 'speak') {
        Set-GemmaGuiStatus 'Generating or playing speech...'
    } else {
        Set-GemmaGuiStatus 'Replaying cached WAV...'
    }
    $g.Timer.Start()
}

function Complete-GemmaGuiWorker {
    $g = $script:GemmaGui
    $kind = $g.WorkerKind
    $ps = $g.WorkerPowerShell
    $async = $g.WorkerAsync
    $results = @()

    $g.Timer.Stop()
    try {
        $results = @($ps.EndInvoke($async))
        if ($kind -eq 'chat') {
            if ($results.Count -eq 0) {
                $errorText = 'The background request returned no result.'
                if ($ps.Streams.Error.Count -gt 0) { $errorText = [string]$ps.Streams.Error[0] }
                Append-GemmaGuiMessage -Role error -Text $errorText
                Set-GemmaGuiStatus 'Request failed.'
            } else {
                $result = $results[$results.Count - 1]
                if ($result.Success) {
                    $g.LastReply = [string]$result.Reply
                    Append-GemmaGuiMessage -Role assistant -Text $g.LastReply
                    $stats = 'Done in {0}s  |  ↑ {1}  ↓ {2}  |  {3}:{4}' -f $result.ElapsedSeconds,$result.PromptTokens,$result.CompletionTokens,$result.Provider,$result.Model
                    Set-GemmaGuiStatus ($stats + '  |  One-shot')
                } else {
                    Append-GemmaGuiMessage -Role error -Text ([string]$result.Error)
                    Set-GemmaGuiStatus 'Request failed. See details above.'
                }
            }
        } elseif ($kind -eq 'speak') {
            $ttsMessage = if ($results.Count -gt 0) { [string]$results[$results.Count - 1] } else { 'Speech task finished.' }
            if ($ttsMessage -match 'TTS error:') { Append-GemmaGuiMessage -Role error -Text $ttsMessage }
            Set-GemmaGuiStatus 'Ready  |  Speech task finished.'
        } else {
            Set-GemmaGuiStatus 'Ready  |  Cached playback finished (no API request).'
        }
    } catch {
        if ($kind -eq 'chat') { Append-GemmaGuiMessage -Role error -Text $_.Exception.Message }
        else { Set-GemmaGuiStatus ("Background task failed: " + $_.Exception.Message) }
    } finally {
        try { $ps.Dispose() } catch {}
        try { $g.WorkerRunspace.Dispose() } catch {}
        $g.WorkerPowerShell = $null
        $g.WorkerRunspace = $null
        $g.WorkerAsync = $null
        $g.WorkerKind = ''
        Set-GemmaGuiBusy -Busy $false
    }
}

function Start-GemmaGuiSend {
    $g = $script:GemmaGui
    if ($null -ne $g.WorkerPowerShell) { return }
    $text = $g.Prompt.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    $g.Config.Provider = [string]$g.ProviderCombo.SelectedItem
    $g.Config.Model = $g.ModelBox.Text.Trim()
    $g.Config.Effort = [string]$g.EffortCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($g.Config.Model)) {
        Set-GemmaGuiStatus 'Enter a model name first.'
        return
    }
    Save-GemmaGuiConfig
    $g.Prompt.Clear()
    $g.LastPrompt = $text
    $g.LastReply = ''
    Append-GemmaGuiMessage -Role user -Text $text
    Start-GemmaGuiWorker -Kind chat -Prompt $text
}

function Stop-GemmaGuiWorker {
    $g = $script:GemmaGui
    if ($null -eq $g.WorkerPowerShell) { return }
    $g.Timer.Stop()
    try { $g.WorkerPowerShell.Stop() } catch {}
    try { $g.WorkerPowerShell.Dispose() } catch {}
    try { $g.WorkerRunspace.Dispose() } catch {}
    $g.WorkerPowerShell = $null
    $g.WorkerRunspace = $null
    $g.WorkerAsync = $null
    $g.WorkerKind = ''
    Set-GemmaGuiBusy -Busy $false
    Set-GemmaGuiStatus 'Stopped.'
}

function Open-GemmaGuiPromptFile {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Insert a text file into the prompt'
    $dialog.Filter = 'Text and code files|*.txt;*.md;*.ps1;*.py;*.js;*.json;*.xml;*.yaml;*.yml;*.log;*.csv|All files|*.*'
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($script:GemmaGui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $item = Get-Item -LiteralPath $dialog.FileName -ErrorAction Stop
    if ($item.Length -gt 2097152) {
        [System.Windows.Forms.MessageBox]::Show('Text files are limited to 2 MB in this first GUI build.','GEMMA',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $content = Get-Content -LiteralPath $dialog.FileName -Raw -Encoding UTF8
    $prefix = '[File: ' + $dialog.FileName + ']' + [Environment]::NewLine
    if ($script:GemmaGui.Prompt.Text) { $script:GemmaGui.Prompt.AppendText([Environment]::NewLine) }
    $script:GemmaGui.Prompt.AppendText($prefix + $content)
    $script:GemmaGui.Prompt.Focus()
}

function Save-GemmaGuiTranscript {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Save transcript'
    $dialog.Filter = 'Text files|*.txt|Markdown files|*.md|All files|*.*'
    $dialog.FileName = 'gemma-transcript.txt'
    if ($dialog.ShowDialog($script:GemmaGui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    [IO.File]::WriteAllText($dialog.FileName,$script:GemmaGui.Transcript.Text,[Text.UTF8Encoding]::new($true))
    Set-GemmaGuiStatus ('Saved: ' + $dialog.FileName)
}

function Clear-GemmaGuiTranscript {
    $script:GemmaGui.Transcript.Clear()
    $script:GemmaGui.LastPrompt = ''
    $script:GemmaGui.LastReply = ''
    Set-GemmaGuiBusy -Busy ($null -ne $script:GemmaGui.WorkerPowerShell)
    Set-GemmaGuiStatus 'Cleared. One-shot mode: no previous messages are sent to the model.'
}

function Show-GemmaGuiModelDialog {
    $g = $script:GemmaGui
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Select model'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = [System.Drawing.Size]::new(510,112)
    $dialog.BackColor = $g.Form.BackColor
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Model ID'
    $label.Location = [System.Drawing.Point]::new(12,14)
    $label.AutoSize = $true
    $label.ForeColor = $g.Form.ForeColor
    $modelTextBox = New-Object System.Windows.Forms.TextBox
    $modelTextBox.Location = [System.Drawing.Point]::new(12,38)
    $modelTextBox.Size = [System.Drawing.Size]::new(486,24)
    $modelTextBox.Text = $g.ModelBox.Text
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = [System.Drawing.Point]::new(332,74)
    $ok.Size = [System.Drawing.Size]::new(78,27)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = [System.Drawing.Point]::new(420,74)
    $cancel.Size = [System.Drawing.Size]::new(78,27)
    $dialog.Controls.AddRange(@($label,$modelTextBox,$ok,$cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    if ($dialog.ShowDialog($g.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $g.ModelBox.Text = $modelTextBox.Text.Trim()
        $g.Config.Model = $g.ModelBox.Text
        Save-GemmaGuiConfig
        Set-GemmaGuiStatus ('Model: ' + $g.Config.Model)
    }
    $dialog.Dispose()
}

function Select-GemmaGuiFont {
    $g = $script:GemmaGui
    $dialog = New-Object System.Windows.Forms.FontDialog
    $dialog.Font = $g.EditorFont
    $dialog.ShowColor = $false
    $dialog.ShowEffects = $false
    $dialog.MinSize = 8
    $dialog.MaxSize = 24
    if ($dialog.ShowDialog($g.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-GemmaGuiFont -Family $dialog.Font.FontFamily.Name -Size $dialog.Font.Size
    }
    $dialog.Dispose()
}

function Start-GemmaGui {
    $config = Import-GemmaGuiConfig

    # If Antigravity has not been authenticated but a Gemini Developer API key
    # is present, prefer the provider that can be used immediately.
    $antigravityToken = Join-Path (Join-Path $HOME '.gemini\antigravity-cli') 'antigravity-oauth-token'
    $geminiKey = $env:GEMINI_API
    if ([string]::IsNullOrWhiteSpace($geminiKey)) { $geminiKey = $env:GEMINI_API_KEY }
    if ($config.Provider -eq 'antigravity' -and -not (Test-Path -LiteralPath $antigravityToken) -and -not [string]::IsNullOrWhiteSpace($geminiKey)) {
        $config.Provider = 'gemini'
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'GEMMA'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MinimumSize = [System.Drawing.Size]::new(760,560)
    $form.Size = [System.Drawing.Size]::new([int]$config.WindowWidth,[int]$config.WindowHeight)
    if ([int]$config.WindowX -ge 0 -and [int]$config.WindowY -ge 0) {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = [System.Drawing.Point]::new([int]$config.WindowX,[int]$config.WindowY)
    }

    $menu = New-Object System.Windows.Forms.MenuStrip
    $menu.Dock = [System.Windows.Forms.DockStyle]::Top
    $fileMenu = [System.Windows.Forms.ToolStripMenuItem]::new('File')
    $editMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Edit')
    $viewMenu = [System.Windows.Forms.ToolStripMenuItem]::new('View')
    $settingsMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Settings')
    $helpMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Help')

    $newItem = [System.Windows.Forms.ToolStripMenuItem]::new('New / Clear')
    $newItem.ShortcutKeys = ([System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::N)
    $openItem = [System.Windows.Forms.ToolStripMenuItem]::new('Insert text file into prompt...')
    $saveItem = [System.Windows.Forms.ToolStripMenuItem]::new('Save transcript...')
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
    [void]$fileMenu.DropDownItems.Add($newItem)
    [void]$fileMenu.DropDownItems.Add($openItem)
    [void]$fileMenu.DropDownItems.Add($saveItem)
    [void]$fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$fileMenu.DropDownItems.Add($exitItem)

    $copyItem = [System.Windows.Forms.ToolStripMenuItem]::new('Copy transcript')
    $copyItem.ShortcutKeys = ([System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::Shift -bor [System.Windows.Forms.Keys]::C)
    $pasteItem = [System.Windows.Forms.ToolStripMenuItem]::new('Paste into prompt')
    $pasteItem.ShortcutKeys = ([System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::V)
    $clearPromptItem = [System.Windows.Forms.ToolStripMenuItem]::new('Clear prompt')
    [void]$editMenu.DropDownItems.Add($copyItem)
    [void]$editMenu.DropDownItems.Add($pasteItem)
    [void]$editMenu.DropDownItems.Add($clearPromptItem)

    $themeMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Theme')
    foreach ($themeName in @($script:GemmaGuiThemes.Keys)) {
        $themeItem = [System.Windows.Forms.ToolStripMenuItem]::new([string]$themeName)
        $themeItem.Tag = [string]$themeName
        $selectedThemeName = [string]$themeName
        $themeHandler = { Set-GemmaGuiTheme -Name $selectedThemeName }.GetNewClosure()
        $themeItem.Add_Click($themeHandler)
        [void]$themeMenu.DropDownItems.Add($themeItem)
    }
    $fontItem = [System.Windows.Forms.ToolStripMenuItem]::new('Choose font...')
    $largerFontItem = [System.Windows.Forms.ToolStripMenuItem]::new('Increase font')
    $smallerFontItem = [System.Windows.Forms.ToolStripMenuItem]::new('Decrease font')
    [void]$viewMenu.DropDownItems.Add($themeMenu)
    [void]$viewMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$viewMenu.DropDownItems.Add($fontItem)
    [void]$viewMenu.DropDownItems.Add($largerFontItem)
    [void]$viewMenu.DropDownItems.Add($smallerFontItem)

    $modelItem = [System.Windows.Forms.ToolStripMenuItem]::new('Model ID...')
    $systemPromptItem = [System.Windows.Forms.ToolStripMenuItem]::new('Choose system prompt file...')
    $resetPromptItem = [System.Windows.Forms.ToolStripMenuItem]::new('Use default system prompt')
    $saveConfigItem = [System.Windows.Forms.ToolStripMenuItem]::new('Save external config now')
    [void]$settingsMenu.DropDownItems.Add($modelItem)
    [void]$settingsMenu.DropDownItems.Add($systemPromptItem)
    [void]$settingsMenu.DropDownItems.Add($resetPromptItem)
    [void]$settingsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$settingsMenu.DropDownItems.Add($saveConfigItem)

    $aboutItem = [System.Windows.Forms.ToolStripMenuItem]::new('About GEMMA')
    $helpItem = [System.Windows.Forms.ToolStripMenuItem]::new('Provider and API-key setup')
    [void]$helpMenu.DropDownItems.Add($aboutItem)
    [void]$helpMenu.DropDownItems.Add($helpItem)

    [void]$menu.Items.Add($fileMenu)
    [void]$menu.Items.Add($editMenu)
    [void]$menu.Items.Add($viewMenu)
    [void]$menu.Items.Add($settingsMenu)
    [void]$menu.Items.Add($helpMenu)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    $layout.Padding = [System.Windows.Forms.Padding]::new(8)
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,42))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,174))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,24))

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $toolbar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $toolbar.WrapContents = $false
    $toolbar.Padding = [System.Windows.Forms.Padding]::new(2,5,2,2)
    $providerLabel = New-Object System.Windows.Forms.Label
    $providerLabel.Text = 'Provider'
    $providerLabel.AutoSize = $true
    $providerLabel.Margin = [System.Windows.Forms.Padding]::new(4,6,2,0)
    $providerCombo = New-Object System.Windows.Forms.ComboBox
    $providerCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $providerCombo.Width = 132
    [void]$providerCombo.Items.AddRange([object[]]@('antigravity','gemini'))
    $providerCombo.SelectedItem = [string]$config.Provider

    $modelLabel = New-Object System.Windows.Forms.Label
    $modelLabel.Text = 'Model'
    $modelLabel.AutoSize = $true
    $modelLabel.Margin = [System.Windows.Forms.Padding]::new(12,6,2,0)
    $modelBox = New-Object System.Windows.Forms.TextBox
    $modelBox.Width = 285
    $modelBox.Text = [string]$config.Model

    $effortLabel = New-Object System.Windows.Forms.Label
    $effortLabel.Text = 'Effort'
    $effortLabel.AutoSize = $true
    $effortLabel.Margin = [System.Windows.Forms.Padding]::new(12,6,2,0)
    $effortCombo = New-Object System.Windows.Forms.ComboBox
    $effortCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $effortCombo.Width = 88
    [void]$effortCombo.Items.AddRange([object[]]@('low','medium','high'))
    $effortCombo.SelectedItem = [string]$config.Effort

    $oneShotLabel = New-Object System.Windows.Forms.Label
    $oneShotLabel.Text = 'ONE-SHOT'
    $oneShotLabel.AutoSize = $true
    $oneShotLabel.Margin = [System.Windows.Forms.Padding]::new(14,6,2,0)

    [void]$toolbar.Controls.AddRange(@($providerLabel,$providerCombo,$modelLabel,$modelBox,$effortLabel,$effortCombo,$oneShotLabel))

    $transcript = New-Object System.Windows.Forms.RichTextBox
    $transcript.Dock = [System.Windows.Forms.DockStyle]::Fill
    $transcript.ReadOnly = $true
    $transcript.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $transcript.DetectUrls = $true
    $transcript.WordWrap = $true
    $transcript.MaxLength = 4194304
    $transcript.HideSelection = $false
    $transcript.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical

    $bottomPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bottomPanel.ColumnCount = 1
    $bottomPanel.RowCount = 2
    [void]$bottomPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
    [void]$bottomPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,34))

    $prompt = New-Object System.Windows.Forms.RichTextBox
    $prompt.Dock = [System.Windows.Forms.DockStyle]::Fill
    $prompt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $prompt.AcceptsTab = $true
    $prompt.WordWrap = $true
    $prompt.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $prompt.MaxLength = 262144

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttons.WrapContents = $false
    $buttons.Padding = [System.Windows.Forms.Padding]::new(0,3,0,0)
    $sendButton = New-Object System.Windows.Forms.Button
    $sendButton.Text = 'Send'
    $sendButton.Width = 86
    $sendButton.Height = 28
    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = 'Stop'
    $stopButton.Width = 72
    $stopButton.Height = 28
    $stopButton.Enabled = $false
    $speakButton = New-Object System.Windows.Forms.Button
    $speakButton.Text = 'Speak'
    $speakButton.Width = 76
    $speakButton.Height = 28
    $speakButton.Enabled = $false
    $replayButton = New-Object System.Windows.Forms.Button
    $replayButton.Text = 'Replay'
    $replayButton.Width = 76
    $replayButton.Height = 28
    $replayButton.Enabled = $false
    [void]$buttons.Controls.AddRange(@($sendButton,$stopButton,$speakButton,$replayButton))
    [void]$bottomPanel.Controls.Add($prompt,0,0)
    [void]$bottomPanel.Controls.Add($buttons,0,1)

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.AutoEllipsis = $true
    $statusLabel.Text = 'Ready  |  One-shot: previous messages are not sent to the model.'
    [void]$statusPanel.Controls.Add($statusLabel)

    [void]$layout.Controls.Add($toolbar,0,0)
    [void]$layout.Controls.Add($transcript,0,1)
    [void]$layout.Controls.Add($bottomPanel,0,2)
    [void]$layout.Controls.Add($statusPanel,0,3)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150

    $script:GemmaGui = @{
        RootPath = $script:GemmaGuiRoot
        Config = $config
        Form = $form
        Menu = $menu
        Toolbar = $toolbar
        BottomPanel = $bottomPanel
        StatusPanel = $statusPanel
        StatusLabel = $statusLabel
        ProviderLabel = $providerLabel
        ModelLabel = $modelLabel
        EffortLabel = $effortLabel
        OneShotLabel = $oneShotLabel
        ProviderCombo = $providerCombo
        ModelBox = $modelBox
        EffortCombo = $effortCombo
        Transcript = $transcript
        Prompt = $prompt
        SendButton = $sendButton
        StopButton = $stopButton
        SpeakButton = $speakButton
        ReplayButton = $replayButton
        Timer = $timer
        WorkerPowerShell = $null
        WorkerRunspace = $null
        WorkerAsync = $null
        WorkerKind = ''
        LastPrompt = ''
        LastReply = ''
        EditorFont = [System.Drawing.Font]::new([string]$config.FontFamily,[single]$config.FontSize,[System.Drawing.FontStyle]::Regular)
    }

    $uiFont = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    $form.Font = $uiFont
    $providerLabel.Font = $uiFont
    $modelLabel.Font = $uiFont
    $effortLabel.Font = $uiFont
    $oneShotLabel.Font = $uiFont
    $providerCombo.Font = $uiFont
    $modelBox.Font = $uiFont
    $effortCombo.Font = $uiFont
    $sendButton.Font = $uiFont
    $stopButton.Font = $uiFont
    $speakButton.Font = $uiFont
    $replayButton.Font = $uiFont
    $statusLabel.Font = $uiFont
    $transcript.Font = $script:GemmaGui.EditorFont
    $prompt.Font = $script:GemmaGui.EditorFont

    $newItem.Add_Click({ Clear-GemmaGuiTranscript })
    $openItem.Add_Click({ Open-GemmaGuiPromptFile })
    $saveItem.Add_Click({ Save-GemmaGuiTranscript })
    $exitItem.Add_Click({ $script:GemmaGui.Form.Close() })
    $copyItem.Add_Click({
        if ($script:GemmaGui.Transcript.Text) {
            [System.Windows.Forms.Clipboard]::SetText($script:GemmaGui.Transcript.Text)
            Set-GemmaGuiStatus 'Transcript copied.'
        }
    })
    $pasteItem.Add_Click({
        try {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ($clip) { $script:GemmaGui.Prompt.AppendText($clip) }
            $script:GemmaGui.Prompt.Focus()
        } catch { Set-GemmaGuiStatus ('Clipboard unavailable: ' + $_.Exception.Message) }
    })
    $clearPromptItem.Add_Click({ $script:GemmaGui.Prompt.Clear() })
    $fontItem.Add_Click({ Select-GemmaGuiFont })
    $largerFontItem.Add_Click({
        $c = $script:GemmaGui.Config
        Set-GemmaGuiFont -Family ([string]$c.FontFamily) -Size ([double]$c.FontSize + 1)
    })
    $smallerFontItem.Add_Click({
        $c = $script:GemmaGui.Config
        Set-GemmaGuiFont -Family ([string]$c.FontFamily) -Size ([double]$c.FontSize - 1)
    })
    $modelItem.Add_Click({ Show-GemmaGuiModelDialog })
    $systemPromptItem.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Choose system prompt Markdown file'
        $dialog.Filter = 'Markdown and text|*.md;*.txt|All files|*.*'
        if ($dialog.ShowDialog($script:GemmaGui.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:GemmaGui.Config.SystemPromptFile = $dialog.FileName
            Save-GemmaGuiConfig
            Set-GemmaGuiStatus ('System prompt: ' + [IO.Path]::GetFileName($dialog.FileName))
        }
    })
    $resetPromptItem.Add_Click({
        $script:GemmaGui.Config.SystemPromptFile = ''
        Save-GemmaGuiConfig
        Set-GemmaGuiStatus 'Using the built-in default system prompt.'
    })
    $saveConfigItem.Add_Click({
        Save-GemmaGuiConfig
        Set-GemmaGuiStatus ('Config saved: ' + $script:GemmaGuiConfigPath)
    })
    $aboutItem.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            'GEMMA desktop edition' + [Environment]::NewLine +
            'Native WinForms UI for Windows PowerShell 5.1.' + [Environment]::NewLine +
            'One-shot requests; the visible transcript stays local.' + [Environment]::NewLine +
            'Configuration: ' + $script:GemmaGuiConfigPath,
            'About GEMMA',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })
    $helpItem.Add_Click({
        $nl = [Environment]::NewLine
        [System.Windows.Forms.MessageBox]::Show(
            ('Gemini provider: set GEMINI_API or GEMINI_API_KEY.' + $nl +
            'Antigravity provider: authenticate once using the existing CLI command .auth login.' + $nl +
            'API credentials are read from environment variables or the existing Antigravity token store. They are not saved in the GUI config.'),
            'Provider setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })

    $providerCombo.Add_SelectedIndexChanged({
        if ($null -eq $script:GemmaGui) { return }
        $script:GemmaGui.Config.Provider = [string]$script:GemmaGui.ProviderCombo.SelectedItem
        Save-GemmaGuiConfig
        Set-GemmaGuiStatus ('Provider: ' + $script:GemmaGui.Config.Provider)
    })
    $effortCombo.Add_SelectedIndexChanged({
        if ($null -eq $script:GemmaGui) { return }
        $script:GemmaGui.Config.Effort = [string]$script:GemmaGui.EffortCombo.SelectedItem
        Save-GemmaGuiConfig
    })
    $modelBox.Add_Leave({
        if ($null -ne $script:GemmaGui) {
            $script:GemmaGui.Config.Model = $script:GemmaGui.ModelBox.Text.Trim()
            Save-GemmaGuiConfig
        }
    })
    $modelBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            $script:GemmaGui.Config.Model = $script:GemmaGui.ModelBox.Text.Trim()
            Save-GemmaGuiConfig
            Set-GemmaGuiStatus ('Model: ' + $script:GemmaGui.Config.Model)
        }
    })

    $sendButton.Add_Click({ Start-GemmaGuiSend })
    $stopButton.Add_Click({ Stop-GemmaGuiWorker })
    $speakButton.Add_Click({
        if ($script:GemmaGui.LastReply) { Start-GemmaGuiWorker -Kind speak }
    })
    $replayButton.Add_Click({
        if ($script:GemmaGui.LastReply) { Start-GemmaGuiWorker -Kind replay }
    })
    $prompt.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            Start-GemmaGuiSend
        }
    })
    $timer.Add_Tick({
        if ($null -ne $script:GemmaGui.WorkerAsync -and $script:GemmaGui.WorkerAsync.IsCompleted) {
            Complete-GemmaGuiWorker
        }
    })
    $form.Add_FormClosing({
        Save-GemmaGuiConfig
        if ($null -ne $script:GemmaGui.WorkerPowerShell) {
            try { $script:GemmaGui.WorkerPowerShell.Stop() } catch {}
            try { $script:GemmaGui.WorkerPowerShell.Dispose() } catch {}
            try { $script:GemmaGui.WorkerRunspace.Dispose() } catch {}
        }
        try { $script:GemmaGui.Timer.Dispose() } catch {}
    })

    Apply-GemmaGuiTheme
    Set-GemmaGuiFont -Family ([string]$config.FontFamily) -Size ([double]$config.FontSize)
    Save-GemmaGuiConfig

    if ($config.Provider -eq 'antigravity' -and -not (Test-Path -LiteralPath $antigravityToken)) {
        Set-GemmaGuiStatus 'Antigravity token not found. Select Gemini with a configured API key or authenticate with the CLI.'
    } elseif ($config.Provider -eq 'gemini' -and [string]::IsNullOrWhiteSpace($geminiKey)) {
        Set-GemmaGuiStatus 'Set GEMINI_API or GEMINI_API_KEY before sending.'
    }

    $form.AcceptButton = $sendButton
    $form.Add_Shown({ $script:GemmaGui.Prompt.Focus() })
    [void]$form.Controls.Add($layout)
    [void]$form.Controls.Add($menu)
    [void]$form.ShowDialog()
    $form.Dispose()
}

Start-GemmaGui
