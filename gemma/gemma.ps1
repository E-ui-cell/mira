[CmdletBinding()]
param(
    [Alias('p')][string]$Prompt,
    [Alias('e')][string]$ExplainCommand,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

# Explorer's legacy "Run with PowerShell" association can append an
# execution-policy wrapper after -File. Capture and remove only that exact
# suffix before Gemma processes any remaining CLI arguments.
. (Join-Path $PSScriptRoot 'config\Cli.ps1')
$Prompt = Initialize-GemmaCliMode -Prompt $Prompt -ExplainCommand $ExplainCommand -RemainingArgs $RemainingArgs
. (Join-Path $PSScriptRoot 'config\Defaults.ps1')

. (Join-Path $PSScriptRoot 'providers\GeminiApi.ps1')
. (Join-Path $PSScriptRoot 'providers\Antigravity.ps1')
. (Join-Path $PSScriptRoot 'ui\ModelPicker.ps1')
. (Join-Path $PSScriptRoot 'agent\Execution.ps1')
. (Join-Path $PSScriptRoot 'agent\Skills.ps1')
. (Join-Path $PSScriptRoot 'agent\Tools.ps1')
. (Join-Path $PSScriptRoot 'windows\Native.ps1')

. (Join-Path $PSScriptRoot 'agent\Settings.ps1')
. (Join-Path $PSScriptRoot 'agent\Conversation.ps1')
. (Join-Path $PSScriptRoot 'ui\Output.ps1')

$Contents = [System.Collections.ArrayList]::new()

# Interactive input state
$script:MiraInputHistory = [System.Collections.Generic.List[string]]::new()
$script:MiraHistoryIndex = -1
$script:MiraHistoryDraft = ''
$script:MiraHistoryMax = $MIRA_MAX_HISTORY
$script:GemCommands = @('.q','.clear','.diff','.file','.text','.save','.exportsession','.loadsession','.shot','.model','.provider','.effort','.verbose','.auth','.grounding','.ask','.autopilot','.skills','.skill')

. (Join-Path $PSScriptRoot 'ui\LineEditor.ps1')

. (Join-Path $PSScriptRoot 'agent\ChatLoop.ps1')
Start-GemmaChatLoop
