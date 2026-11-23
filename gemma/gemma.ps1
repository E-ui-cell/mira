[CmdletBinding()]
param(
    [Alias('p')][string]$Prompt,
    [Alias('e')][string]$ExplainCommand,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

# Explorer's legacy "Run with PowerShell" association can append an
# execution-policy wrapper after -File. Capture and remove only that exact
# suffix before Gemma processes any remaining CLI arguments.
function Get-GemmaCliArgs {
    param([object[]]$RawArgs)

    $a = @($RawArgs | ForEach-Object { [string]$_ })
    if ($a.Count -ge 2 -and $a[0] -ieq '-Command') {
        $cmd = ([string]$a[1]).Replace(' ', '').Replace([string][char]9, '').Replace([string][char]13, '').Replace([string][char]10, '')
        $expected = 'if((Get-ExecutionPolicy)-neAllSigned){Set-ExecutionPolicy-ScopeProcessBypass}'
        if ($cmd -ieq $expected) {
            return @($a | Select-Object -Skip 2)
        }
    }

    return $a
}

. (Join-Path $PSScriptRoot 'config\Defaults.ps1')

. (Join-Path $PSScriptRoot 'providers\GeminiApi.ps1')
. (Join-Path $PSScriptRoot 'providers\Antigravity.ps1')
. (Join-Path $PSScriptRoot 'ui\ModelPicker.ps1')
. (Join-Path $PSScriptRoot 'agent\Execution.ps1')
. (Join-Path $PSScriptRoot 'agent\Skills.ps1')
. (Join-Path $PSScriptRoot 'windows\Native.ps1')

. (Join-Path $PSScriptRoot 'agent\Settings.ps1')
. (Join-Path $PSScriptRoot 'agent\Conversation.ps1')
. (Join-Path $PSScriptRoot 'ui\Output.ps1')

$Contents = [System.Collections.ArrayList]::new()

# MIRA INPUT HISTORY STATE - history-patch.ps1
$script:MiraInputHistory = [System.Collections.Generic.List[string]]::new()
$script:MiraHistoryIndex = -1
$script:MiraHistoryDraft = ''
$script:MiraHistoryMax = $MIRA_MAX_HISTORY
# ==============================================================================
# TAB COMPLETION
# ==============================================================================


$script:GemCommands = @('.clear','.diff','.file','.text','.save','.exportsession','.loadsession','.shot','.model','.provider','.effort','.verbose','.auth','.grounding','.ask','.autopilot')

. (Join-Path $PSScriptRoot 'ui\LineEditor.ps1')

# ==============================================================================
# HELPER: EXTRACT AND SAVE CODE BLOCKS (.save)
# ==============================================================================
. (Join-Path $PSScriptRoot 'agent\ChatLoop.ps1')
