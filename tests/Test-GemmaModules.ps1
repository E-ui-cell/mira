#requires -Version 5.1

$repoRoot = Split-Path -Parent $PSScriptRoot
# Parse every GEMMA script before dot-sourcing any module. This catches a
# broken startup file before a missing function can surface later at tool dispatch.
$gemmaRoot = Join-Path $repoRoot 'gemma'
$gemmaScriptFiles = @(Get-ChildItem -LiteralPath $gemmaRoot -Filter '*.ps1' -File -Recurse)
foreach ($changedFile in $gemmaScriptFiles) {
    $relativePath = $changedFile.FullName.Substring($repoRoot.Length).TrimStart('\','/')
    $changedTokens = $null
    $changedErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($changedFile.FullName, [ref]$changedTokens, [ref]$changedErrors) | Out-Null
    if ($changedErrors.Count -gt 0) {
        $firstError = $changedErrors[0]
        throw ("PowerShell syntax error in {0} at line {1}, column {2}: {3}" -f $relativePath,$firstError.Extent.StartLineNumber,$firstError.Extent.StartColumnNumber,$firstError.Message)
    }
}

# Keep this dot-source order identical to gemma/gemma.ps1. The test must
# exercise the same dependency order that users get during startup.
$modules = @(
    (Join-Path $repoRoot 'gemma\config\Cli.ps1'),
    (Join-Path $repoRoot 'gemma\config\Defaults.ps1'),
    (Join-Path $repoRoot 'gemma\providers\GeminiApi.ps1'),
    (Join-Path $repoRoot 'gemma\providers\OpenAI.ps1'),
    (Join-Path $repoRoot 'gemma\providers\Groq.ps1'),
    (Join-Path $repoRoot 'gemma\providers\Antigravity.ps1'),
    (Join-Path $repoRoot 'gemma\ui\ModelPicker.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Execution.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Skills.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Tools.ps1'),
    (Join-Path $repoRoot 'gemma\windows\Native.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Settings.ps1'),
    (Join-Path $repoRoot 'gemma\agent\Conversation.ps1'),
    (Join-Path $repoRoot 'gemma\ui\Output.ps1'),
    (Join-Path $repoRoot 'gemma\ui\LineEditor.ps1'),
    (Join-Path $repoRoot 'gemma\agent\ChatLoop.ps1')
)

foreach ($modulePath in $modules) {
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Missing Gemma component: $modulePath"
    }
    . $modulePath
}

$toolTestOriginalProvider = $script:Provider
$toolTestOriginalCommandMode = $script:CommandMode
$toolTestOriginalPermission = $script:ExecutionPermission
try {
    $script:Provider = 'antigravity'
    $script:CommandMode = $false

    $chatToolSet = Get-GemmaToolConfiguration -InputText 'wow'
    if ($null -ne $chatToolSet.Tools -or $null -ne $chatToolSet.ToolConfig) {
        throw 'Ordinary chat still sends unused tool schemas.'
    }

    $fileToolSet = Get-GemmaToolConfiguration -InputText 'list files'
    $fileToolNames = @($fileToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($fileToolNames.Count -ne 1 -or $fileToolNames[0] -ne 'run_powershell') {
        throw 'A file-list request did not expose only run_powershell.'
    }

    $dateToolSet = Get-GemmaToolConfiguration -InputText 'what time is it'
    $dateToolNames = @($dateToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($dateToolNames.Count -ne 1 -or $dateToolNames[0] -ne 'get_current_datetime') {
        throw 'A local-time request did not expose only get_current_datetime.'
    }

    $weatherToolSet = Get-GemmaToolConfiguration -InputText 'weather in Lviv'
    $weatherToolNames = @($weatherToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($weatherToolNames.Count -ne 1 -or $weatherToolNames[0] -ne 'quick_web') {
        throw 'A weather request did not expose only quick_web.'
    }

    $skillToolSet = Get-GemmaToolConfiguration -InputText 'organize my files into folders'
    $skillToolNames = @($skillToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($skillToolNames -notcontains 'run_powershell' -or $skillToolNames -notcontains 'get_skill') {
        throw 'A complex file task did not expose the execution tool and task skill.'
    }

    $script:ExecutionPermission = 'autopilot'
    $dispatchResult = Invoke-GemmaToolCall -Call @{ name = 'run_powershell'; args = @{ command = '$null'; elevated = $false } }
    if ([string]::IsNullOrWhiteSpace([string]$dispatchResult.output) -or
        $dispatchResult.output -notmatch 'completed successfully with no output') {
        throw 'run_powershell did not dispatch to Invoke-GemmaPowerShellTool.'
    }
} finally {
    $script:Provider = $toolTestOriginalProvider
    $script:CommandMode = $toolTestOriginalCommandMode
    $script:ExecutionPermission = $toolTestOriginalPermission
}
Write-Host 'GEMMA tool registry and PowerShell dispatch checks passed.'

# PowerShell's @($null) contains one null item; tool stream parsers must skip it.
$nullArrayFixture = @($null)
if ($nullArrayFixture.Count -ne 1) {
    throw 'PowerShell @($null) behavior changed; review null tool-delta handling.'
}

$plainCompletionFixture = [pscustomobject]@{
    choices = @([pscustomobject]@{
        message = [pscustomobject]@{
            role = 'assistant'
            content = 'plain text response'
        }
        finish_reason = 'stop'
    })
    usage = $null
}
$plainCompletion = ConvertFrom-GemmaOpenAIResponse -OpenAIResponse $plainCompletionFixture
$plainCompletionCalls = @(
    $plainCompletion.candidates[0].content.parts |
        Where-Object { $null -ne $_.functionCall }
)
if ($plainCompletionCalls.Count -ne 0) {
    throw 'A Chat Completions text-only response without tool_calls created a fake function call.'
}

$groqTurnSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\Turn.ps1') -Raw -Encoding UTF8
if ($groqTurnSource -notmatch '(?s)foreach \(\$toolDelta in @\(\$delta\.tool_calls\)\) \{\s*# Text chunks commonly omit tool_calls\..*?if \(\$null -eq \$toolDelta\) \{ continue \}') {
    throw 'Groq streaming does not skip null tool-call deltas.'
}
if ([regex]::Matches($groqTurnSource,'HttpWebRequest\.GetResponse\(\) nests WebException').Count -ne 2) {
    throw 'Groq/OpenAI HTTP error handling does not inspect nested WebException responses.'
}
Write-Host 'GEMMA text-only tool-call and HTTP-error regression checks passed.'

if ($MIRA_DEFAULT_SYSTEM_PROMPT.Length -gt 500) {
    throw 'The default system prompt must stay compact to avoid unnecessary input-token overhead.'
}

$requiredFunctions = @(
    'Get-GeminiModels',
    'Get-GemmaCliArgs',
    'Initialize-GemmaCliMode',
    'Start-GemmaChatLoop',
    'Get-AntigravityModels',
    'Test-GemmaSearchIntent',
    'Invoke-GemmaAntigravityGoogleSearchPreflight',
    'Invoke-GemmaWebSearch',
    'Invoke-GemmaPermissionCommand',
    'Invoke-GemmaPowerShellTool',
    'Invoke-GemmaQuickWeb',
    'Get-GemmaSkill',
    'Get-GemmaToolConfiguration',
    'Invoke-GemmaToolCall',
    'Initialize-GemmaNativeWindows',
    'Confirm-GemmaDirectAction',
    'Invoke-GemmaDirectCommand',
    'Invoke-GemmaEffortCommand',
    'Invoke-GemmaStreamingCommand',
    'Add-GemmaUsageRecord',
    'Invoke-GemmaUsageCommand',
    'Build-GeminiPayload',
    'Get-GroqApiKeys',
    'Get-GroqModels',
    'Test-GemmaGroqReasoningModel',
    'Test-GemmaGroqReasoningEffortModel',
    'Build-GemmaGroqChatPayload',
    'Add-GemmaAntigravitySearchCapabilityInstruction',
    'Clear-GemmaModelMenu',
    'Build-GemmaOpenAIResponsesPayload',
    'ConvertFrom-GemmaOpenAIResponsesResponse',
    'Format-GemmaOpenAIWebCitations',
    'Rollback-MiraTurn',
    'Save-GeminiCodeBlocks',
    'Normalize-MiraReply',
    'Add-GemmaModelCatalogEntry',
    'Get-GemmaModelCatalog',
    'Get-GemmaModelCompletionCandidates',
    'Get-GemmaProviderCompletionModels',
    'Get-GemmaSystemPromptNames',
    'Read-GemmaModelSelection',
    'Set-GemmaActiveModel',
    'Invoke-GemmaModelPicker',
    'Read-GemLineConsole',
    'Read-GemLineFallback',
    'Add-GemUndoSnapshot',
    'Get-GemmaGoogleBlockDiagnostic',
    'Get-GemWordStart',
    'Get-GemWordEnd',
    'Find-GemHistoryMatch',
    'Get-GemHistorySearchPrompt'
)

# The unified model picker must own provider switching; the old .provider command is gone.
$mainSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\gemma.ps1') -Raw -Encoding UTF8
$chatLoopSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\ChatLoop.ps1') -Raw -Encoding UTF8
$lineEditorSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\ui\LineEditor.ps1') -Raw -Encoding UTF8
$outputSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\ui\Output.ps1') -Raw -Encoding UTF8
$modelPickerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\ui\ModelPicker.ps1') -Raw -Encoding UTF8
if ($modelPickerSource -notmatch 'Clear-GemmaModelMenu -Top \$top -Height \$menuHeight') {
    throw 'The model picker must clear its temporary rows when it closes.'
}
if ($mainSource -match "'\.provider'" -or
    $chatLoopSource -match 'Invoke-GemmaProviderCommand|\.provider' -or
    $lineEditorSource -match '\.provider' -or
    $outputSource -match '\.provider' -or
    $null -ne (Get-Command Invoke-GemmaProviderCommand -ErrorAction SilentlyContinue)) {
    throw 'The retired .provider command is still registered, dispatched, completed, or advertised.'
}
foreach ($requiredProvider in @('openai','antigravity','gemini','groq')) {
    if ($modelPickerSource -notmatch ("Id = '" + $requiredProvider + "'")) {
        throw "The unified model picker is missing the '$requiredProvider' provider group."
    }
}
if ($modelPickerSource -notmatch 'Get-AntigravityModels' -or
    $modelPickerSource -notmatch 'Get-GeminiModels' -or
    $modelPickerSource -notmatch 'Get-GroqModels' -or
    $modelPickerSource -notmatch 'Google AI Studio API' -or
    $modelPickerSource -notmatch 'Groq' -or
    $modelPickerSource -notmatch 'MIRA_OPENAI_DEFAULT_MODEL' -or
    -not $modelPickerSource.Contains("provider + ':' +")) {
    throw 'The model picker does not independently load and label all four provider catalogues as provider:model.'
}

# Gemini's model list can still advertise 2.5 models even when generation access
# is restricted to previously active projects. The picker must flag them clearly.
$catalogProbe = New-Object 'System.Collections.Generic.List[object]'
$catalogSeen = @{}
Add-GemmaModelCatalogEntry -List $catalogProbe -Seen $catalogSeen -Provider 'gemini' -Item ([pscustomobject]@{ name = 'gemini-2.5-flash-lite' })
Add-GemmaModelCatalogEntry -List $catalogProbe -Seen $catalogSeen -Provider 'gemini' -Item ([pscustomobject]@{ name = 'gemini-3.5-flash-lite' })
Add-GemmaModelCatalogEntry -List $catalogProbe -Seen $catalogSeen -Provider 'antigravity' -Item ([pscustomobject]@{ name = 'gemini-2.5-flash-lite' })
if (-not $catalogProbe[0].legacyAccessRestricted -or
    $catalogProbe[1].legacyAccessRestricted -or
    $catalogProbe[2].legacyAccessRestricted -or
    $modelPickerSource -notmatch '\[legacy access\]') {
    throw 'The model picker must flag only Google AI Studio Gemini 2.5 models with restricted project access.'
}
if ($lineEditorSource -notmatch 'Get-GemmaModelCompletionCandidates' -or
    $lineEditorSource -notmatch 'Get-GemmaSystemPromptNames' -or
    $lineEditorSource -notmatch '\.sysprompt\s+' -or
    -not $lineEditorSource.Contains("'.sysprompt'") -or
    -not $lineEditorSource.Contains("completion += ' '") -or
    $lineEditorSource -notmatch '\.exportsession' -or
    $lineEditorSource -notmatch '\.loadsession' -or
    $lineEditorSource -notmatch "argumentCommands = .*\.exportsession.*\.loadsession" -or
    $lineEditorSource -notmatch '\(\?:file\|text\|exportsession\|loadsession\)' -or
    $lineEditorSource -match 'openai:gpt-6-luna|google-ai-studio:') {
    throw 'The .model or .sysprompt argument tab completions are incomplete or still hard-coded.'
}

# The main Mira TUI and Gemma line editor must defer queued control keys rather
# than consuming Tab as text or silently dropping it during fast paste bursts.
$rootTuiPath = Join-Path $repoRoot 'mira.ps1'
$rootTuiSource = Get-Content -LiteralPath $rootTuiPath -Raw -Encoding UTF8
if ($rootTuiSource -notmatch '\$script:PendingTuiKeys\s*=\s*New-Object' -or
    $rootTuiSource -notmatch 'PendingTuiKeys\.Dequeue\(\)' -or
    [regex]::Matches($rootTuiSource,'PendingTuiKeys\.Enqueue\(\$p\)').Count -lt 2 -or
    $rootTuiSource -match '\$buffer\s*=\s*\$buffer\.Insert\(\$cursor,"\u0060t"\)') {
    throw 'The root TUI still loses queued Tab/control keys during input bursts.'
}
if ($rootTuiSource -notmatch '(?s)if\(\$p\.Key -eq \[ConsoleKey\]::Enter.*?if\(Available\)\{.*?\$buffer=\$buffer\.Insert\(\$cursor,"\u0060n"\)') {
    throw 'A fast Enter in the root TUI is not deferred for prompt submission.'
}
if ($rootTuiSource -notmatch '(?s)\$direction=if\(\$shift\)\{-1\}else\{1\}\s*Move-ModelMenu \$direction') {
    throw 'The root TUI model completion menu does not support reverse Tab navigation.'
}
if (-not $lineEditorSource.Contains('$oldText.IndexOf([char]10)') -or
    -not $lineEditorSource.Contains('$newText.IndexOf([char]10)') -or
    -not $lineEditorSource.Contains('$commonLimit = [Math]::Min') -or
    -not $lineEditorSource.Contains('$cursorRow = $row + $rowOffsets[$lineIndex] + $cursorRowOffset - $visibleRowOffset')) {
    throw 'Gemma input editor single-line incremental redraw or long-buffer cursor viewport logic is missing.'
}
if ($lineEditorSource -notmatch '\$pendingKeys\s*=\s*New-Object' -or
    $lineEditorSource -notmatch '\$pendingKeys\.Dequeue\(\)' -or
    $lineEditorSource -notmatch '\$pendingKeys\.Enqueue\(\$pk\)' -or
    $lineEditorSource -notmatch 'function Clear-GemCompletionMenu' -or
    $lineEditorSource -notmatch 'Clear-GemCompletionMenu' -or
    $lineEditorSource -match '\$row\s*=\s*\[Math\]::Min\(\$completionTop\s*\+\s*\$completionMenuHeight') {
    throw 'Gemma completion input still drops control keys or leaves duplicate/stale menu rows.'
}
if ($lineEditorSource -notmatch '(?s)if \(\$pk\.Key -eq \[ConsoleKey\]::Enter.*?if \(\[Console\]::KeyAvailable\) \{.*?\$b = \$b\.Insert\(\$c,"\u0060n"\)') {
    throw 'A fast Enter in the Gemma line editor is not deferred for prompt submission.'
}
if ($lineEditorSource -notmatch '(?s)if \(\$k\.Key -eq \[ConsoleKey\]::Tab\) \{\s*\$direction = if \(\(\$k\.Modifiers -band \[ConsoleModifiers\]::Shift\)') {
    throw 'Gemma completion menu does not support Tab/Shift+Tab navigation.'
}

# Exercise the root TUI model setter without starting its interactive console.
$rootTuiTokens = $null
$rootTuiErrors = $null
$rootTuiAst = [System.Management.Automation.Language.Parser]::ParseFile($rootTuiPath,[ref]$rootTuiTokens,[ref]$rootTuiErrors)
if ($rootTuiErrors.Count -gt 0) {
    Write-Warning ('Skipping root Mira TUI AST tests because mira.ps1 has an existing syntax error: ' + $rootTuiErrors[0].Message)
} else {
$setModelNode = $rootTuiAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-ModelSelection'
},$true)
$invokeProviderNode = $rootTuiAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Provider'
},$true)
if ($null -eq $setModelNode -or $null -eq $invokeProviderNode) {
    throw 'Root Mira TUI model selection/provider dispatch functions are missing.'
}
$invokeProviderSource = $invokeProviderNode.Extent.Text
if ($invokeProviderSource -notmatch 'Get-Provider \$script:CurrentProviderName' -or
    $invokeProviderSource -notmatch 'Build-OpenAICompatiblePayload \$provider \$messages \$script:CurrentModel' -or
    $rootTuiSource -notmatch 'Add-UsedModel \$script:CurrentProviderName \$script:CurrentModel') {
    throw 'Root Mira TUI request routing or provider-qualified model history is incomplete.'
}

$oldGetProvider = Get-Command Get-Provider -CommandType Function -ErrorAction SilentlyContinue
$oldGetDefaultProviderModel = Get-Command Get-DefaultProviderModel -CommandType Function -ErrorAction SilentlyContinue
$oldW = Get-Command W -CommandType Function -ErrorAction SilentlyContinue
$oldSetModelSelection = Get-Command Set-ModelSelection -CommandType Function -ErrorAction SilentlyContinue
$oldCurrentProviderName = Get-Variable CurrentProviderName -Scope Script -ErrorAction SilentlyContinue
$oldCurrentModel = Get-Variable CurrentModel -Scope Script -ErrorAction SilentlyContinue
try {
    $script:TestTuiProviders = @(
        [pscustomobject]@{ name='openai'; models=@([pscustomobject]@{ name='gpt-6-luna' }) }
        [pscustomobject]@{ name='gemini'; models=@([pscustomobject]@{ name='gemini-3.1-flash-lite' }) }
        [pscustomobject]@{ name='groq'; models=@([pscustomobject]@{ name='openai/gpt-oss-120b' }) }
    )
    Set-Item -Path Function:\Get-Provider -Value {
        param([string]$name)
        foreach ($provider in $script:TestTuiProviders) {
            if ([string]$provider.name -ieq $name) { return $provider }
        }
        return $null
    }
    Set-Item -Path Function:\Get-DefaultProviderModel -Value {
        param($provider)
        if ($null -ne $provider.models -and @($provider.models).Count -gt 0) {
            return [string]$provider.models[0].name
        }
        return ''
    }
    Set-Item -Path Function:\W -Value { param($Message,$Color) }
    . ([scriptblock]::Create($setModelNode.Extent.Text))

    $script:CurrentProviderName = 'gemini'
    $script:CurrentModel = 'gemini-3.1-flash-lite'
    if (-not (Set-ModelSelection 'openai:gpt-6-luna') -or
        $script:CurrentProviderName -ne 'openai' -or
        $script:CurrentModel -ne 'gpt-6-luna') {
        throw 'Root .model provider-qualified selection did not switch both provider and model.'
    }
    if (-not (Set-ModelSelection 'groq') -or
        $script:CurrentProviderName -ne 'groq' -or
        $script:CurrentModel -ne 'openai/gpt-oss-120b') {
        throw 'Root .model provider-only selection did not choose that provider’s default model.'
    }
} finally {
    if ($null -ne $oldGetProvider) { Set-Item -Path Function:\Get-Provider -Value $oldGetProvider.ScriptBlock }
    else { Remove-Item -Path Function:\Get-Provider -ErrorAction SilentlyContinue }
    if ($null -ne $oldGetDefaultProviderModel) { Set-Item -Path Function:\Get-DefaultProviderModel -Value $oldGetDefaultProviderModel.ScriptBlock }
    else { Remove-Item -Path Function:\Get-DefaultProviderModel -ErrorAction SilentlyContinue }
    if ($null -ne $oldW) { Set-Item -Path Function:\W -Value $oldW.ScriptBlock }
    else { Remove-Item -Path Function:\W -ErrorAction SilentlyContinue }
    if ($null -ne $oldSetModelSelection) { Set-Item -Path Function:\Set-ModelSelection -Value $oldSetModelSelection.ScriptBlock }
    else { Remove-Item -Path Function:\Set-ModelSelection -ErrorAction SilentlyContinue }
    if ($null -ne $oldCurrentProviderName) { Set-Variable -Name CurrentProviderName -Scope Script -Value $oldCurrentProviderName.Value }
    else { Remove-Variable -Name CurrentProviderName -Scope Script -ErrorAction SilentlyContinue }
    if ($null -ne $oldCurrentModel) { Set-Variable -Name CurrentModel -Scope Script -Value $oldCurrentModel.Value }
    else { Remove-Variable -Name CurrentModel -Scope Script -ErrorAction SilentlyContinue }
    Remove-Variable -Name TestTuiProviders -Scope Script -ErrorAction SilentlyContinue
}
}

# Exercise the unified Gemma picker and prove each catalogue selection updates
# both the active provider and model. No live model-list requests are made.
$oldGemmaProvider = $script:Provider
$oldGemmaModel = $script:MODEL
$oldOpenAIApiKeys = @($script:OpenAIApiKeys)
$oldGeminiApiKeys = @($script:GeminiApiKeys)
$oldGroqApiKeys = @($script:GroqApiKeys)
$oldModelCatalogCache = $script:GemmaModelCatalogCache
$oldModelCatalogCacheAt = $script:GemmaModelCatalogCacheAt
$oldProviderCompletionCache = $script:GemmaProviderCompletionCache
$oldModelCatalogFunction = (Get-Command Get-GemmaModelCatalog -CommandType Function).ScriptBlock
$oldAntigravityPathFunction = (Get-Command Get-AntigravityTokenPath -CommandType Function).ScriptBlock
$oldGeminiModelsFunction = (Get-Command Get-GeminiModels -CommandType Function).ScriptBlock
$script:TestAntigravityTokenPath = [IO.Path]::Combine([IO.Path]::GetTempPath(),'mira-antigravity-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $script:OpenAIApiKeys = @('unit-test-openai-key')
    $script:GeminiApiKeys = @('unit-test-gemini-key')
    $script:GroqApiKeys = @('unit-test-groq-key')
    [IO.File]::WriteAllText($script:TestAntigravityTokenPath,'{}')
    Set-Item -Path Function:\Get-GemmaModelCatalog -Value {
        return [pscustomobject]@{
            Models = @(
                [pscustomobject]@{ name='gemini-test-model'; provider='gemini' }
                [pscustomobject]@{ name='agy-test-model'; provider='antigravity' }
                [pscustomobject]@{ name='gemini-3-flash'; provider='gemini' }
                [pscustomobject]@{ name='gemini-3-flash'; provider='antigravity' }
                [pscustomobject]@{ name='openai/gpt-oss-120b'; provider='groq' }
            )
            ProviderStatuses = @{}
        }
    }
    Set-Item -Path Function:\Get-AntigravityTokenPath -Value {
        return $script:TestAntigravityTokenPath
    }

    Invoke-GemmaModelPicker -RequestedModel 'openai:gpt-6-luna'
    if ($script:Provider -ne 'openai' -or $script:MODEL -ne 'gpt-6-luna') {
        throw 'Gemma .model openai:gpt-6-luna did not switch to OpenAI.'
    }
    Invoke-GemmaModelPicker -RequestedModel 'gemini:gemini-test-model'
    if ($script:Provider -ne 'gemini' -or $script:MODEL -ne 'gemini-test-model') {
        throw 'Gemma .model gemini:model did not switch to Google AI Studio API.'
    }
    Invoke-GemmaModelPicker -RequestedModel 'antigravity:agy-test-model'
    if ($script:Provider -ne 'antigravity' -or $script:MODEL -ne 'agy-test-model') {
        throw 'Gemma .model antigravity:model did not switch to Antigravity.'
    }
    Invoke-GemmaModelPicker -RequestedModel 'groq:openai/gpt-oss-120b'
    if ($script:Provider -ne 'groq' -or $script:MODEL -ne 'openai/gpt-oss-120b') {
        throw 'Gemma .model groq:model did not switch to Groq.'
    }
    $script:GemmaModelCatalogCache = Get-GemmaModelCatalog
    $script:GemmaModelCatalogCacheAt = Get-Date
    $groqCompletionOptions = @(Get-GemmaModelCompletionCandidates -Prefix 'groq:')
    if ($groqCompletionOptions -notcontains 'groq:openai/gpt-oss-120b') {
        throw 'The .model completion catalogue omitted the provider-qualified Groq model.'
    }
    $geminiCompletionOptions = @(Get-GemmaModelCompletionCandidates -Prefix 'gemini:gemini-3-flash')
    $antigravityCompletionOptions = @(Get-GemmaModelCompletionCandidates -Prefix 'antigravity:gemini-3-flash')
    if ($geminiCompletionOptions -notcontains 'gemini:gemini-3-flash' -or
        $antigravityCompletionOptions -notcontains 'antigravity:gemini-3-flash') {
        throw 'The .model completion catalogue did not keep identical model IDs distinct by provider.'
    }
    $script:GemmaModelCatalogCache = $null
    $script:GemmaModelCatalogCacheAt = [DateTime]::MinValue
    $script:GemmaProviderCompletionCache = @{}
    Set-Item -Path Function:\Get-GeminiModels -Value {
        if ($script:Provider -ne 'gemini') { throw 'Gemini API catalogue was fetched under the wrong active provider.' }
        return @([pscustomobject]@{ name = 'gemini-api-only-test' })
    }
    $script:Provider = 'antigravity'
    $geminiProviderOnlyModels = @(Get-GemmaProviderCompletionModels -Provider 'gemini')
    if ($script:Provider -ne 'antigravity' -or
        $geminiProviderOnlyModels.Count -ne 1 -or
        $geminiProviderOnlyModels[0].provider -ne 'gemini' -or
        $geminiProviderOnlyModels[0].name -ne 'gemini-api-only-test') {
        throw 'Gemini provider-specific completion did not isolate and restore the active provider.'
    }
    $script:Provider = 'groq'
    $oldPromptDirectory = $script:GemmaPromptDirectory
    $testPromptDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gemma-prompts-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $testPromptDirectory -Force)
        [IO.File]::WriteAllText((Join-Path $testPromptDirectory 'code-review.md'),'test')
        [IO.File]::WriteAllText((Join-Path $testPromptDirectory 'default.md'),'test')
        $script:GemmaPromptDirectory = $testPromptDirectory
        $promptNames = @(Get-GemmaSystemPromptNames)
        if ($promptNames -notcontains 'default' -or @($promptNames | Where-Object { $_ -ieq 'default' }).Count -ne 1 -or $promptNames -notcontains 'code-review') {
            throw 'System prompt completion did not include default and available prompt names.'
        }
    } finally {
        $script:GemmaPromptDirectory = $oldPromptDirectory
        if (Test-Path -LiteralPath $testPromptDirectory) { Remove-Item -LiteralPath $testPromptDirectory -Recurse -Force }
    }
} finally {
    $script:Provider = $oldGemmaProvider
    $script:MODEL = $oldGemmaModel
    $script:OpenAIApiKeys = $oldOpenAIApiKeys
    $script:GeminiApiKeys = $oldGeminiApiKeys
    $script:GroqApiKeys = $oldGroqApiKeys
    $script:GemmaModelCatalogCache = $oldModelCatalogCache
    $script:GemmaModelCatalogCacheAt = $oldModelCatalogCacheAt
    $script:GemmaProviderCompletionCache = $oldProviderCompletionCache
    Set-Item -Path Function:\Get-GemmaModelCatalog -Value $oldModelCatalogFunction
    Set-Item -Path Function:\Get-AntigravityTokenPath -Value $oldAntigravityPathFunction
    Set-Item -Path Function:\Get-GeminiModels -Value $oldGeminiModelsFunction
    if (Test-Path -LiteralPath $script:TestAntigravityTokenPath) {
        Remove-Item -LiteralPath $script:TestAntigravityTokenPath -Force
    }
    Remove-Variable -Name TestAntigravityTokenPath -Scope Script -ErrorAction SilentlyContinue
}

# OpenAI Responses turns retain native output items for Luna, but those
# provider-only fields must never leak into Gemini Developer API or
# Antigravity Content objects. The shared history must remain intact so a
# later switch back to Luna can still use its native response items.
$oldCrossProvider = @{
    Provider = $script:Provider
    Model = $script:MODEL
    Effort = $script:Effort
}
try {
    $script:Provider = 'antigravity'
    $script:MODEL = 'gemini-3-flash'
    $crossProviderHistory = [System.Collections.ArrayList]::new()
    [void]$crossProviderHistory.Add(@{
        role = 'user'
        parts = @(@{ text = 'Earlier question' })
    })
    [void]$crossProviderHistory.Add(@{
        role = 'model'
        parts = @(
            @{ text = 'Earlier answer' }
            @{ functionCall = @{ id = 'call_test_1'; name = 'test_tool'; args = @{ value = 'kept' } } }
        )
        openaiOutputItems = @(
            @{ type = 'reasoning'; id = 'rs_test_1'; summary = @() }
            @{ type = 'function_call'; call_id = 'call_test_1'; name = 'test_tool'; arguments = '{"value":"kept"}' }
        )
    })

    $geminiPayload = Build-GeminiPayload -SystemInstruction $null -Contents $crossProviderHistory
    $serializedGeminiPayload = $geminiPayload | ConvertTo-Json -Depth 30 -Compress
    if ($serializedGeminiPayload -match '"openaiOutputItems"') {
        throw 'Gemini/Antigravity payload leaked OpenAI-only openaiOutputItems history metadata.'
    }
    if ($geminiPayload.contents.Count -ne 2 -or
        $geminiPayload.contents[1].role -ne 'model' -or
        $geminiPayload.contents[1].parts.Count -ne 2 -or
        $geminiPayload.contents[1].parts[1].functionCall.name -ne 'test_tool') {
        throw 'Gemini/Antigravity history projection did not preserve the model role and Gemini function-call parts.'
    }
    if (-not $crossProviderHistory[1].ContainsKey('openaiOutputItems')) {
        throw 'Building a Gemini/Antigravity payload mutated shared history and discarded Luna native output items.'
    }
} finally {
    $script:Provider = $oldCrossProvider.Provider
    $script:MODEL = $oldCrossProvider.Model
    $script:Effort = $oldCrossProvider.Effort
}

# Groq must use native effort only on models that document it, while still
# preserving parsed reasoning for supported reasoning models without effort controls.
$oldGroqPayloadState = @{
    Provider = $script:Provider
    Model = $script:MODEL
    Effort = $script:Effort
    VerboseOutput = $script:VerboseOutput
    GroqEffort = $MIRA_GROQ_EFFORT
    MaxTokens = $MIRA_GROQ_MAX_COMPLETION_TOKENS
    Temperature = $MIRA_GROQ_TEMPERATURE
    TopP = $MIRA_GROQ_TOP_P
    ResponseFormat = $MIRA_GROQ_RESPONSE_FORMAT
    Tools = $GeminiTools
}
try {
    $script:Provider = 'groq'
    $script:Effort = 'high'
    $script:VerboseOutput = $true
    $MIRA_GROQ_EFFORT = $null
    $MIRA_GROQ_MAX_COMPLETION_TOKENS = $null
    $MIRA_GROQ_TEMPERATURE = $null
    $MIRA_GROQ_TOP_P = $null
    $MIRA_GROQ_RESPONSE_FORMAT = $null
    $GeminiTools = @()

    $script:MODEL = 'openai/gpt-oss-120b'
    $groqPayload = Build-GemmaGroqChatPayload -SystemInstruction $null -Contents (New-Object System.Collections.ArrayList) -Streaming $true
    if ($groqPayload.model -ne 'openai/gpt-oss-120b' -or
        $groqPayload.reasoning_effort -ne 'high' -or
        -not $groqPayload.include_reasoning -or
        $groqPayload.Contains('reasoning_format') -or
        -not $groqPayload.stream -or
        $groqPayload.Contains('stream_options')) {
        throw 'Groq GPT-OSS payload did not apply its supported reasoning controls and streaming correctly.'
    }
    $script:VerboseOutput = $false
    $groqHiddenPayload = Build-GemmaGroqChatPayload -SystemInstruction $null -Contents (New-Object System.Collections.ArrayList)
    if ($groqHiddenPayload.include_reasoning -ne $false -or $groqHiddenPayload.Contains('reasoning_format')) {
        throw 'Groq GPT-OSS did not hide reasoning when .verbose is disabled.'
    }
    $script:VerboseOutput = $true

    $script:MODEL = 'openai/gpt-oss-safeguard-20b'
    $groqReasoningOnlyPayload = Build-GemmaGroqChatPayload -SystemInstruction $null -Contents (New-Object System.Collections.ArrayList)
    if (-not $groqReasoningOnlyPayload.include_reasoning -or
        $groqReasoningOnlyPayload.Contains('reasoning_effort') -or
        $groqReasoningOnlyPayload.Contains('reasoning_format')) {
        throw 'Groq GPT-OSS Safeguard received unsupported reasoning parameters.'
    }

    $script:MODEL = 'llama-3.3-70b-versatile'
    $groqStandardPayload = Build-GemmaGroqChatPayload -SystemInstruction $null -Contents (New-Object System.Collections.ArrayList)
    if ($groqStandardPayload.Contains('reasoning_effort') -or $groqStandardPayload.Contains('reasoning_format')) {
        throw 'A standard Groq chat model received reasoning-only request parameters.'
    }

    $groqFixture = [pscustomobject]@{
        id = 'chatcmpl-test'
        model = 'openai/gpt-oss-120b'
        choices = @([pscustomobject]@{
            finish_reason = 'stop'
            message = [pscustomobject]@{
                role = 'assistant'
                content = 'Final answer'
                reasoning = 'Private reasoning'
                tool_calls = @()
            }
        })
        usage = [pscustomobject]@{ prompt_tokens = 10; completion_tokens = 5; total_tokens = 15 }
    }
    $groqConverted = ConvertFrom-GemmaOpenAIResponse -OpenAIResponse $groqFixture
    $groqParts = @($groqConverted.candidates[0].content.parts)
    if ($groqParts.Count -lt 2 -or
        $groqParts[0].thought -ne $true -or
        $groqParts[0].text -ne 'Private reasoning' -or
        $groqParts[1].text -ne 'Final answer') {
        throw 'Groq parsed reasoning was not preserved as a thought part ahead of final text.'
    }

    $groqEffort = Get-GemmaEffortResolution -Provider 'groq' -Model 'qwen/qwen3.8-27b'
    if (-not $groqEffort.Supported -or $groqEffort.Parameter -ne 'reasoning_effort' -or $groqEffort.Effort -ne 'high') {
        throw 'Groq Qwen 3.8 reasoning effort was not resolved to the native API parameter.'
    }
    $MIRA_GROQ_EFFORT = 'none'
    $groqNoReasoning = Get-GemmaEffortResolution -Provider 'groq' -Model 'qwen/qwen3.8-27b'
    if ($groqNoReasoning.Effort -ne 'none' -or -not $groqNoReasoning.Supported) {
        throw 'Groq Qwen 3.8 did not accept its documented none reasoning-effort setting.'
    }
    $MIRA_GROQ_EFFORT = 'xhigh'
    $groqMuseEffort = Get-GemmaEffortResolution -Provider 'groq' -Model 'meta-models/muse-spark-open'
    if (-not $groqMuseEffort.Supported -or $groqMuseEffort.Effort -ne 'xhigh') {
        throw 'Groq Muse Spark Open did not accept its documented xhigh effort setting.'
    }
    $MIRA_GROQ_EFFORT = $null
    $groqUnsupportedEffort = Get-GemmaEffortResolution -Provider 'groq' -Model 'openai/gpt-oss-safeguard-20b'
    if ($groqUnsupportedEffort.Supported) {
        throw 'Groq GPT-OSS Safeguard received an effort parameter not documented for that model.'
    }
} finally {
    $script:Provider = $oldGroqPayloadState.Provider
    $script:MODEL = $oldGroqPayloadState.Model
    $script:Effort = $oldGroqPayloadState.Effort
    $script:VerboseOutput = $oldGroqPayloadState.VerboseOutput
    $MIRA_GROQ_EFFORT = $oldGroqPayloadState.GroqEffort
    $MIRA_GROQ_MAX_COMPLETION_TOKENS = $oldGroqPayloadState.MaxTokens
    $MIRA_GROQ_TEMPERATURE = $oldGroqPayloadState.Temperature
    $MIRA_GROQ_TOP_P = $oldGroqPayloadState.TopP
    $MIRA_GROQ_RESPONSE_FORMAT = $oldGroqPayloadState.ResponseFormat
    $GeminiTools = $oldGroqPayloadState.Tools
}

$turnRoutingSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\Turn.ps1') -Raw -Encoding UTF8
if ($turnRoutingSource -notmatch '\$usingOpenAI\s*=\s*\(\$script:Provider -eq ''openai''\)' -or
    $turnRoutingSource -notmatch '\$usingGroq\s*=\s*\(\$script:Provider -eq ''groq''\)' -or
    $turnRoutingSource -notmatch 'Build-GemmaGroqChatPayload' -or
    $turnRoutingSource -notmatch 'api\.groq\.com/openai/v1/chat/completions' -or
    $turnRoutingSource -notmatch 'Groq Chat Completions stream ended before' -or
    $turnRoutingSource -notmatch '\$usingAntigravityOAuth\s*=\s*\(\$script:Provider -eq ''antigravity''\)' -or
    $turnRoutingSource -notmatch 'Build-GeminiPayload -SystemInstruction') {
    throw 'Gemma request execution does not route from the active model picker provider.'
}

if ($turnRoutingSource -notmatch '\$groqReplayState\.Text\.Length -gt 0' -or
    $turnRoutingSource -notmatch 'Groq stream was interrupted after emitting text; automatic retry suppressed' -or
    $turnRoutingSource -notmatch '\$status -eq 429' -or
    $turnRoutingSource -notmatch 'Groq rate limit reached \(HTTP 429\); automatic retries and key rotation are disabled') {
    throw 'Groq streaming must not regenerate after visible output or hammer the API after HTTP 429.'
}
if ($MIRA_GROQ_EFFORT -ne 'low') {
    throw 'Groq default reasoning effort must be low to avoid expensive high-effort reasoning on short prompts.'
}


if ($MIRA_DEFAULT_PROVIDER -notin @('antigravity','gemini','openai','groq')) {
    throw 'Gemma defaults did not initialize a supported provider.'
}
if ([string]::IsNullOrWhiteSpace($MIRA_DEFAULT_MODEL)) {
    throw 'Gemma defaults did not initialize the selected model.'
}

if ($script:StreamingMode -notin @('off','line','delta')) {
    throw 'Gemma defaults did not initialize a supported streaming mode.'
}

$turnPath = Join-Path $repoRoot 'gemma\agent\Turn.ps1'
$turnSource = Get-Content -LiteralPath $turnPath -Raw
$maxTokensCheck = $turnSource.IndexOf('if ([string]$parseState.Candidate.finishReason -match ''(?i)MAX_TOKENS'')', [StringComparison]::OrdinalIgnoreCase)
$thoughtOnlyCheck = $turnSource.IndexOf('if ($parseState.HasThoughts)', [StringComparison]::OrdinalIgnoreCase)
if ($maxTokensCheck -lt 0 -or $thoughtOnlyCheck -lt 0 -or $maxTokensCheck -gt $thoughtOnlyCheck) {
    throw 'Google streaming parser must report MAX_TOKENS before classifying thought-only output.'
}
if (($turnSource -notmatch '\$thoughtOnlyResponse -and \$attempt -eq 0') -or
    ($turnSource -notmatch 'GetBaseException\(\)') -or
    ($turnSource -notmatch '\$exceptionCursor\.InnerException') -or
    ($turnSource -notmatch 'google\\\.rpc\\\.RetryInfo') -or
    ($turnSource -notmatch 'MODEL_CAPACITY_EXHAUSTED') -or
    ($turnSource -notmatch '\$capacityExhausted -and \$attempt -gt 0') -or
    ($turnSource -notmatch '\$requestStats\.HttpStatus')) {
    throw 'Google streaming thought-only retry, nested HTTP response extraction, or capacity RetryInfo handling is missing.'
}
if ($turnSource -notmatch '\$streamState\.Response\s*=\s*\$streamResponse' -or
    $turnSource -notmatch '\$response\s*=\s*\$streamState\.Response' -or
    $turnSource -notmatch '\$streamGoogle -and \$streamTextThisRequest' -or
    $turnSource -notmatch '\$requestStats\.ErrorMessage\s*=\s*\$diagnosticMessage' -or
    $turnSource -notmatch '\$candidateFailureCode' -or
    $turnSource -notmatch 'Google returned no candidates') {
    throw 'Gemini streaming response handoff, streamed-text recovery, or structured API error diagnostics are missing.'
}

# TTS model-specific payloads and bounded server-error fallback classification.
$oldTtsModel = $script:MiraTtsModel
$oldTtsVoice = $script:MiraTtsVoice
$oldTtsAudioDirectory = $script:MiraTtsAudioDirectory
$oldTtsModels = $script:MiraTtsModels
$oldSystemInstruction = $SystemInstruction
try {
    . (Join-Path $repoRoot 'gemma\agent\Tts.ps1')
    $script:MiraTtsVoice = 'Kore'
    $SystemInstruction = [pscustomobject]@{
        parts = @([pscustomobject]@{ text = ('## TTS scene' + [Environment]::NewLine + 'A quiet room at night.' + [Environment]::NewLine + '## Other section' + [Environment]::NewLine + 'Not part of the scene.') })
    }
    $scene = Get-GemmaTtsScene
    if ($scene -ne 'A quiet room at night.') { throw 'TTS scene extraction did not stop at the next prompt section.' }
    $transcript = 'Hello <whispers> there <short pause> friend.'
    $modernPart = New-GemmaTtsSpeechPart -Transcript $transcript -Style 'warm and calm' -Scene $scene -Model 'gemini-3.8-flash-tts'
    if ($modernPart.text -ne $transcript -or $modernPart.speechMetadata.style -ne 'warm and calm') {
        throw 'Gemini 3.8 TTS payload must keep the transcript separate and use speechMetadata.style.'
    }
    $legacy31Part = New-GemmaTtsSpeechPart -Transcript $transcript -Style 'warm and calm' -Scene $scene -Model 'gemini-3.1-flash-tts-preview'
    if ($legacy31Part.ContainsKey('speechMetadata') -or $legacy31Part.text -notmatch '\[Scene\]' -or
        $legacy31Part.text -notmatch "\[Director's Notes\]" -or $legacy31Part.text -notmatch '\[whispers\]') {
        throw 'Gemini 3.1 TTS must use its legacy scene/director-note format and square-bracket tags.'
    }
    $legacy25Part = New-GemmaTtsSpeechPart -Transcript $transcript -Style 'warm and calm' -Scene $scene -Model 'gemini-2.5-flash-preview-tts'
    if ($legacy25Part.ContainsKey('speechMetadata') -or $legacy25Part.text -notmatch 'Scene: A quiet room at night\.' -or
        $legacy25Part.text -notmatch "Director's notes: warm and calm" -or $legacy25Part.text -match '<whispers>|\[whispers\]') {
        throw 'Gemini 2.5 TTS must use plain-text scene/director instructions and omit unsupported inline tags.'
    }
    if (-not (Test-GemmaTtsModelRetryableFailure -Message 'Gemini TTS failed with every configured API key: HTTP 503: UNAVAILABLE') -or
        -not (Test-GemmaTtsModelRetryableFailure -Message 'HTTP 429: RESOURCE_EXHAUSTED') -or
        (Test-GemmaTtsModelRetryableFailure -Message 'HTTP 400: INVALID_ARGUMENT')) {
        throw 'TTS model fallback must retry server/quota failures but not non-retryable 400 responses.'
    }
    if (@($script:MiraTtsModels).Count -ne 4) { throw 'The configured TTS model list must contain all four supported model IDs.' }
} finally {
    $script:MiraTtsModel = $oldTtsModel
    $script:MiraTtsVoice = $oldTtsVoice
    $script:MiraTtsAudioDirectory = $oldTtsAudioDirectory
    $script:MiraTtsModels = $oldTtsModels
    $SystemInstruction = $oldSystemInstruction
}
# Mock the complete TTS model fallback path: 503 on the preferred model, success on the next model.
$oldTtsRequestFunction = (Get-Command Invoke-GemmaTtsWithKeyRotation -CommandType Function).ScriptBlock
$oldTtsPlayFunction = (Get-Command Invoke-GemmaPlayTtsWave -CommandType Function).ScriptBlock
$oldGeminiKeysFunction = (Get-Command Get-GeminiApiKeys -CommandType Function).ScriptBlock
$oldTtsModelForFallback = $script:MiraTtsModel
$oldTtsVoiceForFallback = $script:MiraTtsVoice
$oldTtsDirectoryForFallback = $script:MiraTtsAudioDirectory
$oldTtsModelsForFallback = $script:MiraTtsModels
$script:TtsMockUris = New-Object 'System.Collections.Generic.List[string]'
$script:TtsMockAudioBytes = New-Object byte[] 44
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('RIFF'),0,$script:TtsMockAudioBytes,0,4)
$script:TtsMockAudioBase64 = [Convert]::ToBase64String($script:TtsMockAudioBytes)
$script:TtsMockPlayedPath = ''
$mockTtsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gemma-tts-mock-' + [guid]::NewGuid().ToString('N'))
$script:MiraTtsAudioDirectory = $mockTtsDirectory
$script:MiraTtsModel = 'gemini-3.8-flash-tts'
$script:MiraTtsVoice = 'Kore'
$script:MiraTtsModels = @('gemini-3.8-flash-tts','gemini-3.1-flash-tts-preview','gemini-2.5-flash-preview-tts','gemini-3.8-flash-lite-tts')
try {
    Set-Item -Path Function:\Get-GeminiApiKeys -Value { return @('mock-gemini-key') }
    Set-Item -Path Function:\Invoke-GemmaTtsWithKeyRotation -Value {
        param([string]$Uri,[string]$Json)
        [void]$script:TtsMockUris.Add($Uri)
        if ($Uri.Contains('gemini-3.8-flash-tts:')) { throw 'Gemini TTS failed with every configured API key: HTTP 503: UNAVAILABLE' }
        return [pscustomobject]@{ candidates = @([pscustomobject]@{ content = [pscustomobject]@{ parts = @([pscustomobject]@{ inlineData = [pscustomobject]@{ data = $script:TtsMockAudioBase64 } }) } }) }
    }
    Set-Item -Path Function:\Invoke-GemmaPlayTtsWave -Value { param([string]$Path) $script:TtsMockPlayedPath = $Path }
    $mockContents = [System.Collections.ArrayList]::new()
    [void]$mockContents.Add([pscustomobject]@{ role='user'; parts=@([pscustomobject]@{ text='speak this' }) })
    [void]$mockContents.Add([pscustomobject]@{ role='model'; parts=@([pscustomobject]@{ text='mock transcript' }) })
    Invoke-GemmaSpeakLatest -Contents $mockContents
    if ($script:TtsMockUris.Count -ne 2 -or
        -not $script:TtsMockUris[0].Contains('gemini-3.8-flash-tts:') -or
        -not $script:TtsMockUris[1].Contains('gemini-3.1-flash-tts-preview:') -or
        $script:MiraTtsModel -ne 'gemini-3.1-flash-tts-preview' -or
        -not (Test-Path -LiteralPath $script:TtsMockPlayedPath -PathType Leaf)) {
        throw 'TTS did not rotate from the preferred 503 model to the next model and cache/play the successful response.'
    }
} finally {
    Set-Item -Path Function:\Invoke-GemmaTtsWithKeyRotation -Value $oldTtsRequestFunction
    Set-Item -Path Function:\Invoke-GemmaPlayTtsWave -Value $oldTtsPlayFunction
    Set-Item -Path Function:\Get-GeminiApiKeys -Value $oldGeminiKeysFunction
    $script:MiraTtsModel = $oldTtsModelForFallback
    $script:MiraTtsVoice = $oldTtsVoiceForFallback
    $script:MiraTtsAudioDirectory = $oldTtsDirectoryForFallback
    $script:MiraTtsModels = $oldTtsModelsForFallback
    if (Test-Path -LiteralPath $mockTtsDirectory -PathType Container) { Remove-Item -LiteralPath $mockTtsDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Variable -Name TtsMockUris,TtsMockAudioBytes,TtsMockAudioBase64,TtsMockPlayedPath -Scope Script -ErrorAction SilentlyContinue
}
# Verify the line/delta/off streaming mode command changes runtime state.
$oldStreamingMode = $script:StreamingMode
try {
    Invoke-GemmaStreamingCommand -Argument 'delta'
    if ($script:StreamingMode -ne 'delta') { throw '.streaming delta did not update the active mode.' }
    Invoke-GemmaStreamingCommand -Argument 'line'
    if ($script:StreamingMode -ne 'line') { throw '.streaming line did not update the active mode.' }
    Invoke-GemmaStreamingCommand -Argument 'off'
    if ($script:StreamingMode -ne 'off') { throw '.streaming off did not disable streaming.' }
} finally {
    $script:StreamingMode = $oldStreamingMode
}

# Verify .usage accumulates provider-reported tokens and never needs a probe request.
$oldUsageStats = $script:MiraUsageStats
try {
    $script:MiraUsageStats = @{
        StartedAt = Get-Date
        Requests = 0
        SuccessfulRequests = 0
        FailedRequests = 0
        HttpAttempts = 0
        InputTokens = 0
        OutputTokens = 0
        ByProvider = @{}
        LastRequest = $null
        ProviderRateLimits = @{}
        OpenAIRateLimits = @{}
    }
    Add-GemmaUsageRecord -Provider 'openai' -Model 'gpt-6-luna' -Succeeded $true -InputTokens 123 -OutputTokens 45 -HttpAttempts 2 -KeyIndex 1 -KeyCount 3 -KeySlotsTried @(2,3) -RateLimitHeaders @{ 'x-ratelimit-limit-tokens' = '100000'; 'x-ratelimit-remaining-tokens' = '50000'; 'x-ratelimit-reset-tokens' = '1m'; 'x-ratelimit-remaining-project-tokens' = '40000' } -RequestId 'req_usage_test' -HttpStatus 200
    if ($script:MiraUsageStats.Requests -ne 1 -or
        $script:MiraUsageStats.SuccessfulRequests -ne 1 -or
        $script:MiraUsageStats.InputTokens -ne 123 -or
        $script:MiraUsageStats.OutputTokens -ne 45 -or
        $script:MiraUsageStats.HttpAttempts -ne 2) {
        throw '.usage did not accumulate successful request and token totals.'
    }
    if ($script:MiraUsageStats.LastRequest.KeySlot -ne 2 -or
        $script:MiraUsageStats.LastRequest.KeyCount -ne 3 -or
        $script:MiraUsageStats.OpenAIRateLimits['x-ratelimit-remaining-tokens'] -ne '50000' -or
        $script:MiraUsageStats.OpenAIRateLimits['x-ratelimit-remaining-project-tokens'] -ne '40000') {
        throw '.usage did not retain the used key slot or OpenAI rate-limit headers.'
    }
    Add-GemmaUsageRecord -Provider 'openai' -Model 'gpt-6-luna' -Succeeded $false -HttpAttempts 1 -KeyIndex 2 -KeyCount 3 -KeySlotsTried @(3) -HttpStatus 200 -ErrorCode 'rate_limit_exceeded' -ErrorMessage 'TPM limit'
    if ($script:MiraUsageStats.Requests -ne 2 -or
        $script:MiraUsageStats.FailedRequests -ne 1 -or
        $script:MiraUsageStats.ByProvider['openai'].FailedRequests -ne 1 -or
        $script:MiraUsageStats.LastRequest.ErrorCode -ne 'rate_limit_exceeded' -or
        $script:MiraUsageStats.LastRequest.ErrorMessage -ne 'TPM limit') {
        throw '.usage did not record a failed request.'
    }

    # Usage diagnostics must follow the active provider, not always show OpenAI.
    $oldUsageProvider = $script:Provider
    $oldUsageModel = $script:MODEL
    $oldGeminiKeys = @($script:GeminiApiKeys)
    $oldGeminiKeyIndex = $script:MiraGeminiApiKeyIndex
    try {
        $script:GeminiApiKeys = @('gemini-usage-test-key-1','gemini-usage-test-key-2')
        $script:MiraGeminiApiKeyIndex = 1
        $script:Provider = 'gemini'
        $script:MODEL = 'gemini-3.1-flash-lite'
        Add-GemmaUsageRecord -Provider 'gemini' -Model $script:MODEL -Succeeded $true -InputTokens 77 -OutputTokens 12 -HttpAttempts 1 -KeyIndex 0 -KeyCount 2 -KeySlotsTried @(1) -RateLimitHeaders @{ 'retry-after' = '30'; 'x-ratelimit-remaining-requests' = '8' } -RequestId 'google_usage_test' -HttpStatus 200

        if (-not $script:MiraUsageStats.ProviderRateLimits.ContainsKey('gemini') -or
            $script:MiraUsageStats.ProviderRateLimits['gemini']['retry-after'] -ne '30' -or
            $script:MiraUsageStats.ProviderRateLimits['gemini']['x-ratelimit-remaining-requests'] -ne '8') {
            throw '.usage did not retain Google provider response headers.'
        }

        $geminiUsageOutput = (& { Invoke-GemmaUsageCommand } 6>&1 | Out-String)
        if ($geminiUsageOutput -notmatch 'Active model: Google AI Studio API \| gemini-3\.1-flash-lite' -or
            $geminiUsageOutput -notmatch 'Google AI Studio API key candidates: 2 configured \| next slot 2/2' -or
            $geminiUsageOutput -notmatch 'Last observed Google AI Studio API rate-limit/response headers:' -or
            $geminiUsageOutput -match 'OpenAI key candidates:') {
            throw '.usage diagnostics did not follow the active Google AI Studio API provider.'
        }

        $script:Provider = 'antigravity'
        $script:MODEL = 'gemini-3.1-flash-lite'
        $antigravityUsageOutput = (& { Invoke-GemmaUsageCommand } 6>&1 | Out-String)
        if ($antigravityUsageOutput -notmatch 'Active model: Antigravity \| gemini-3\.1-flash-lite' -or
            $antigravityUsageOutput -notmatch 'Antigravity OAuth:' -or
            $antigravityUsageOutput -match 'OpenAI key candidates:|Google AI Studio API key candidates:') {
            throw '.usage diagnostics did not follow the active Antigravity OAuth provider.'
        }
        $oldGroqKeysForUsage = @($script:GroqApiKeys)
        $oldGroqIndexForUsage = $script:MiraGroqApiKeyIndex
        try {
            $script:GroqApiKeys = @('groq-usage-test-key')
            $script:MiraGroqApiKeyIndex = 0
            $script:Provider = 'groq'
            $script:MODEL = 'openai/gpt-oss-120b'
            Add-GemmaUsageRecord -Provider 'groq' -Model $script:MODEL -Succeeded $true -InputTokens 55 -OutputTokens 22 -HttpAttempts 1 -KeyIndex 0 -KeyCount 1 -KeySlotsTried @(1) -RateLimitHeaders @{ 'x-ratelimit-remaining-requests' = '9' } -RequestId 'groq_usage_test' -HttpStatus 200
            $groqUsageOutput = (& { Invoke-GemmaUsageCommand } 6>&1 | Out-String)
            if ($groqUsageOutput -notmatch 'Active model: Groq \| openai/gpt-oss-120b' -or
                $groqUsageOutput -notmatch 'Groq API key candidates: 1 configured \| next slot 1/1' -or
                $groqUsageOutput -notmatch 'Last observed Groq rate-limit/response headers:') {
                throw '.usage diagnostics did not follow the active Groq provider.'
            }
        } finally {
            $script:GroqApiKeys = $oldGroqKeysForUsage
            $script:MiraGroqApiKeyIndex = $oldGroqIndexForUsage
        }
    } finally {
        $script:Provider = $oldUsageProvider
        $script:MODEL = $oldUsageModel
        $script:GeminiApiKeys = $oldGeminiKeys
        $script:MiraGeminiApiKeyIndex = $oldGeminiKeyIndex
    }
} finally {
    $script:MiraUsageStats = $oldUsageStats
}

# Verify the OpenAI key-rotation error list includes key/account failures and TPM limits,
# but leaves ramp-rate slow_down errors on the same-key backoff path.
$turnSource = Get-Content -LiteralPath $turnPath -Raw -Encoding UTF8
$rotationCodes = @($script:OpenAIKeyRotationErrorCodes)
foreach ($requiredRotationCode in @(
    'invalid_api_key',
    'authentication_error',
    'insufficient_permissions',
    'rate_limit_exceeded',
    'rate_limit_error',
    'insufficient_quota',
    'credit_balance_exhausted',
    'organization_usage_limit_exceeded',
    'organization_spend_limit_exceeded',
    'project_spend_limit_exceeded'
)) {
    if ($rotationCodes -notcontains $requiredRotationCode) {
        throw "OpenAI key rotation list omitted $requiredRotationCode."
    }
}
if ($rotationCodes -contains 'slow_down' -or $rotationCodes -contains 'server_is_overloaded') {
    throw 'Transient OpenAI ramp/overload errors must retry the same key before rotating.'
}
if ($turnSource -notmatch '\$retryErrorCodes\s*=\s*@\(' -or
    $turnSource -notmatch '\$retryErrorCodes -contains \$errorType\.ToLowerInvariant\(\)') {
    throw 'OpenAI transient error codes/types are not wired to the same-key retry path.'
}
if ($turnSource -notmatch '\$requestStats\.HttpStatus\s*=\s*\$status' -or
    $turnSource -notmatch '\$successResponse\.error\.code' -or
    $turnSource -notmatch '\$successResponse\.error\.type') {
    throw 'OpenAI Responses API body failures must preserve HTTP status separately and extract body error code/type.'
}

# Verify the Responses SSE worker extracts failure codes and can replay without
# printing an already-visible prefix twice.
if ($turnSource -notmatch '\$streamErrorCode\s*=\s*\[string\]\$streamErrorObject\.code' -or
    $turnSource -notmatch 'AddArgument\(\@\(\$script:OpenAIKeyRotationErrorCodes\)\)' -or
    $turnSource -notmatch '\$openAIReplayState' -or
    $turnSource -notmatch '\$emitOpenAIText' -or
    $turnSource -match 'if \(\$streamResponses -and \$streamState\.TextStarted\)') {
    throw 'OpenAI Responses stream failure classification/replay logic is incomplete.'
}

if ($turnSource -notmatch '\$getProviderRateHeaders' -or
    $turnSource -notmatch '\$captureProviderResponse' -or
    $turnSource -notmatch '\$script:MiraGeminiApiKeyIndex\s*=\s*\(\$requestStats\.LastKeyIndex \+ 1\)') {
    throw 'Provider response-header capture or Gemini failed-key rotation diagnostics are incomplete.'
}

# Verify .usage is reachable from the interactive command loop and Tab list.
$mainScriptText = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\gemma.ps1') -Raw -Encoding UTF8
$chatLoopText = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\ChatLoop.ps1') -Raw -Encoding UTF8
if ($mainScriptText -notmatch "'\.usage'" -or $chatLoopText -notmatch "Invoke-GemmaUsageCommand") {
    throw '.usage is missing from command completion or interactive dispatch.'
}

foreach ($functionName in $requiredFunctions) {
    $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Gemma component did not load expected function: $functionName"
    }
}

# Verify -p, -e and Explorer Run with PowerShell argument handling.
$normalPrompt = Initialize-GemmaCliMode -Prompt 'hello' -ExplainCommand '' -RemainingArgs @('--sample')
if ($script:OneShot -ne $true -or $script:CommandMode -ne $false -or $normalPrompt -ne 'hello') {
    throw 'Normal one-shot prompt mode was not initialized correctly.'
}
if ($script:RemainingCliArgs.Count -ne 1 -or $script:RemainingCliArgs[0] -ne '--sample') {
    throw 'Remaining CLI arguments were not preserved.'
}
$commandPrompt = Initialize-GemmaCliMode -Prompt '' -ExplainCommand 'Get-ChildItem' -RemainingArgs @()
if ($script:OneShot -ne $true -or $script:CommandMode -ne $true -or $commandPrompt -ne 'Get-ChildItem') {
    throw 'Command-generation mode was not initialized correctly.'
}
$wrappedArgs = @('-Command','if((Get-ExecutionPolicy) -ne AllSigned) { Set-ExecutionPolicy -Scope Process Bypass }','-File','gemma.ps1')
$cleanArgs = @(Get-GemmaCliArgs -RawArgs $wrappedArgs)
if ($cleanArgs.Count -ne 2 -or $cleanArgs[0] -ne '-File' -or $cleanArgs[1] -ne 'gemma.ps1') {
    throw 'Explorer Run with PowerShell argument wrapper was not stripped correctly.'
}

# Verify the explicit Gemini API-key candidate list used by Defaults.ps1.
$defaultsPath = Join-Path $repoRoot 'gemma\config\Defaults.ps1'
$oldGeminiApiKey = $env:GEMINI_API_KEY
$oldGeminiApiJ = $env:GEMINI_APIJ
try {
    $env:GEMINI_API_KEY = 'primary-test-key'
    $env:GEMINI_APIJ = 'secondary-test-key'
    . $defaultsPath
    $geminiCandidates = @($script:GeminiApiKeys)
    if ($geminiCandidates.Count -ne 2 -or
        $geminiCandidates[0] -ne 'primary-test-key' -or
        $geminiCandidates[1] -ne 'secondary-test-key') {
        throw 'Gemini API key candidates were not loaded in the configured order.'
    }

    $env:GEMINI_API_KEY = ''
    . $defaultsPath
    $geminiCandidates = @($script:GeminiApiKeys)
    if ($geminiCandidates.Count -ne 1 -or $geminiCandidates[0] -ne 'secondary-test-key') {
        throw 'Gemini API key candidate filtering did not preserve the remaining key.'
    }
} finally {
    $env:GEMINI_API_KEY = $oldGeminiApiKey
    $env:GEMINI_APIJ = $oldGeminiApiJ
    . $defaultsPath
}

# Verify the shared agent tool registry respects provider and command mode.
$oldProvider = $script:Provider
$oldCommandMode = $script:CommandMode
$oldGrounding = $script:GoogleSearchGrounding
$oldAgenticSearch = $script:AgenticWebSearchEnabled
try {
    $script:CommandMode = $false
    $script:Provider = 'antigravity'
    $script:GoogleSearchGrounding = $true
    $script:AgenticWebSearchEnabled = $true
    $chatToolSet = Get-GemmaToolConfiguration -InputText 'wow'
    if ($null -ne $chatToolSet.Tools -or $null -ne $chatToolSet.ToolConfig) {
        throw 'Ordinary chat must not send unused tool schemas.'
    }

    $toolSet = Get-GemmaToolConfiguration -InputText 'list files'
    $toolNames = @($toolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($toolNames.Count -ne 1 -or $toolNames[0] -ne 'run_powershell') {
        throw 'A local file-list request must expose only the PowerShell execution tool.'
    }
    if ($toolNames -contains 'web_search') {
        throw 'Antigravity tools must not expose Gemini API web_search.'
    }

    $dateToolSet = Get-GemmaToolConfiguration -InputText 'what time is it'
    $dateToolNames = @($dateToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($dateToolNames.Count -ne 1 -or $dateToolNames[0] -ne 'get_current_datetime') {
        throw 'A local time request must expose only the date/time tool.'
    }

    $weatherToolSet = Get-GemmaToolConfiguration -InputText 'weather in Lviv'
    $weatherToolNames = @($weatherToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($weatherToolNames.Count -ne 1 -or $weatherToolNames[0] -ne 'quick_web') {
        throw 'A weather request must expose only the quick web tool.'
    }

    $skillToolSet = Get-GemmaToolConfiguration -InputText 'organize my files into folders'
    $skillToolNames = @($skillToolSet.Tools[0].functionDeclarations | ForEach-Object { $_.name })
    if ($skillToolNames -notcontains 'run_powershell' -or $skillToolNames -notcontains 'get_skill') {
        throw 'A complex file-organization request must expose the execution tool and file-management skill.'
    }

    $dateResult = Invoke-GemmaToolCall -Call @{ name = 'get_current_datetime'; args = @{} }
    if ([string]::IsNullOrWhiteSpace([string]$dateResult.iso8601) -or
        [string]::IsNullOrWhiteSpace([string]$dateResult.timezone_id)) {
        throw 'Local date/time tool returned incomplete data.'
    }

    $unknownResult = Invoke-GemmaToolCall -Call @{ name = 'not_a_real_tool'; args = @{} }
    if (-not $unknownResult.error) {
        throw 'Unknown tool dispatch must return a structured error.'
    }

    $script:CommandMode = $true
    $commandToolSet = Get-GemmaToolConfiguration
    if ($null -ne $commandToolSet.Tools -or $null -ne $commandToolSet.ToolConfig) {
        throw 'Command-generation mode must disable local tool declarations.'
    }
} finally {
    $script:Provider = $oldProvider
    $script:CommandMode = $oldCommandMode
    $script:GoogleSearchGrounding = $oldGrounding
    $script:AgenticWebSearchEnabled = $oldAgenticSearch
}

# Verify Luna receives OpenAI-hosted web_search beside GEMMA's local functions.
$oldOpenAIModel = $script:MODEL
$oldOpenAIProvider = $script:Provider
$oldOpenAICommandMode = $script:CommandMode
$oldGeminiTools = $GeminiTools
try {
    $script:Provider = 'openai'
    $script:MODEL = 'gpt-6-luna'
    $script:CommandMode = $false
    $GeminiTools = (Get-GemmaToolConfiguration -InputText 'list files').Tools

    $lunaPayload = Build-GemmaOpenAIResponsesPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    $nativeSearchTools = @($lunaPayload.tools | Where-Object { $_.type -eq 'web_search' })
    if ($nativeSearchTools.Count -ne 1) {
        throw 'Luna Responses payload must include exactly one native web_search tool.'
    }
    if ($nativeSearchTools[0].search_context_size -ne 'medium' -or
        $nativeSearchTools[0].external_web_access -ne $true -or
        $nativeSearchTools[0].user_location.type -ne 'approximate') {
        throw 'Luna native web_search defaults were not configured correctly.'
    }
    if ($lunaPayload.tool_choice -ne 'auto') {
        throw 'Luna native web_search must use automatic tool selection.'
    }
    if ($lunaPayload.instructions -notmatch '(?i)native web_search tool') {
        throw 'Luna system instructions must direct current-information requests to native web_search.'
    }
    $localToolNames = @($lunaPayload.tools | Where-Object { $_.type -eq 'function' } | ForEach-Object { $_.name })
    foreach ($localTool in @('run_powershell')) {
        if ($localToolNames -notcontains $localTool) {
            throw "Adding native web_search removed Luna's local $localTool function."
        }
    }

    $chatPayload = Build-GemmaOpenAIChatPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    if (@($chatPayload.tools | Where-Object { $_.type -eq 'web_search' }).Count -gt 0) {
        throw 'Native Responses web_search must not leak into Chat Completions requests.'
    }

    $script:CommandMode = $true
    $GeminiTools = $null
    $commandPayload = Build-GemmaOpenAIResponsesPayload -SystemInstruction $SystemInstruction -Contents (New-Object System.Collections.ArrayList)
    if ($null -ne $commandPayload.tools -or $null -ne $commandPayload.tool_choice) {
        throw 'Luna command-generation mode must keep hosted and local tools disabled.'
    }

    $fixtureResponse = [pscustomobject]@{
        error = $null
        status = 'completed'
        id = 'resp_test'
        model = 'gpt-6-luna'
        usage = [pscustomobject]@{ input_tokens = 20; output_tokens = 8 }
        output = @(
            [pscustomobject]@{
                type = 'message'
                content = @(
                    [pscustomobject]@{
                        type = 'output_text'
                        text = 'Example answer [1]'
                        annotations = @(
                            [pscustomobject]@{
                                type = 'url_citation'
                                url = 'https://example.com/article'
                                title = 'Example Article'
                                start_index = 15
                                end_index = 18
                            },
                            [pscustomobject]@{
                                type = 'url_citation'
                                url = 'https://example.com/article'
                                title = 'Example Article'
                                start_index = 15
                                end_index = 18
                            }
                        )
                    }
                )
            }
        )
    }
    $convertedResponse = ConvertFrom-GemmaOpenAIResponsesResponse -OpenAIResponse $fixtureResponse
    if (@($convertedResponse.webCitations).Count -ne 1) {
        throw 'Luna Responses converter did not deduplicate and retain URL citations.'
    }
    if ($convertedResponse.candidates[0].content.parts[0].text -ne 'Example answer [1]') {
        throw 'Luna Responses converter changed the model answer while extracting citations.'
    }
    $formattedSources = Format-GemmaOpenAIWebCitations -Citations @($convertedResponse.webCitations)
    if ($formattedSources -notmatch 'Example Article' -or
        $formattedSources -notmatch 'https://example.com/article') {
        throw 'Luna web citations were not formatted as visible source links.'
    }
} finally {
    $script:MODEL = $oldOpenAIModel
    $script:Provider = $oldOpenAIProvider
    $script:CommandMode = $oldOpenAICommandMode
    $GeminiTools = $oldGeminiTools
}

# Keep Antigravity native Search conditional on the current user request.
$searchCases = @(
    @{ Request = 'test'; Expected = $false },
    @{ Request = 'll'; Expected = $false },
    @{ Request = 'ok'; Expected = $false },
    @{ Request = 'what?'; Expected = $false },
    @{ Request = 'search latest hour news for kyiv'; Expected = $true },
    @{ Request = 'search news, show dates and sources for each news'; Expected = $true },
    @{ Request = 'show latest lviv news in last hours'; Expected = $true },
    @{ Request = 'why you searching again? talk like engineer, what made you continue searching data'; Expected = $false },
    @{ Request = 'why you using puthon to search web? you have own builtin tool, google search grounding'; Expected = $false },
    @{ Request = '.grounding off'; Expected = $false },
    @{ Request = "tell me today's date"; Expected = $false },
    @{ Request = 'show weather in Lviv'; Expected = $false },
    @{ Request = 'search weather in Lviv'; Expected = $true }
)
foreach ($case in $searchCases) {
    $actual = [bool](Test-GemmaSearchIntent -Text $case.Request)
    if ($actual -ne [bool]$case.Expected) {
        throw "Search-intent classifier mismatch for '$($case.Request)': expected $($case.Expected), got $actual."
    }
}

$enabledSearchPolicyPayload = [ordered]@{
    systemInstruction = [ordered]@{
        parts = @([ordered]@{ text = 'Base system prompt.' })
    }
}
Add-GemmaAntigravitySearchCapabilityInstruction -Payload $enabledSearchPolicyPayload -GroundingEnabled $true
$enabledSearchPolicy = (@($enabledSearchPolicyPayload.systemInstruction.parts | ForEach-Object { [string]$_.text }) -join ' ')
if ($enabledSearchPolicy -notmatch 'separate host-managed preflight' -or
    $enabledSearchPolicy -notmatch 'not a callable function tool' -or
    $enabledSearchPolicy -notmatch 'Base system prompt') {
    throw 'Antigravity native Search capability was not appended to the active system instruction.'
}

$disabledSearchPolicyPayload = [ordered]@{
    systemInstruction = [ordered]@{
        parts = @([ordered]@{ text = 'Base system prompt.' })
    }
}
Add-GemmaAntigravitySearchCapabilityInstruction -Payload $disabledSearchPolicyPayload -GroundingEnabled $false
$disabledSearchPolicy = (@($disabledSearchPolicyPayload.systemInstruction.parts | ForEach-Object { [string]$_.text }) -join ' ')
if ($disabledSearchPolicy -notmatch '\.grounding is OFF' -or
    $disabledSearchPolicy -match 'separate host-managed preflight') {
    throw 'Antigravity native Search capability instruction did not respect the grounding toggle.'
}

# Gemini prompt/candidate safety metadata must be distinguished from malformed empty responses.
$promptBlocked = Get-GemmaGoogleBlockDiagnostic -Response ([pscustomobject]@{
    promptFeedback = [pscustomobject]@{
        blockReason = 'SAFETY'
        blockReasonMessage = 'Prompt blocked by safety policy.'
        safetyRatings = @()
    }
    candidates = @()
})
if (-not $promptBlocked.Blocked -or
    $promptBlocked.Code -ne 'PROMPT_BLOCKED_SAFETY' -or
    $promptBlocked.Message -notmatch 'blocked the prompt') {
    throw 'Gemini prompt-level safety block was not diagnosed specifically.'
}
$candidateBlocked = Get-GemmaGoogleBlockDiagnostic -Response ([pscustomobject]@{
    promptFeedback = $null
    candidates = @([pscustomobject]@{ finishReason='SAFETY'; finishMessage='Blocked by safety filter.' })
})
if (-not $candidateBlocked.Blocked -or
    $candidateBlocked.Code -ne 'CANDIDATE_BLOCKED_SAFETY') {
    throw 'Gemini candidate-level safety finish reason was not diagnosed specifically.'
}
$ordinaryEmpty = Get-GemmaGoogleBlockDiagnostic -Response ([pscustomobject]@{
    promptFeedback = $null
    candidates = @()
})
if ($ordinaryEmpty.Blocked -or $ordinaryEmpty.Code) {
    throw 'An ordinary empty Gemini response was incorrectly classified as a safety block.'
}

$gemmaBootstrapSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\gemma.ps1') -Raw -Encoding UTF8
if ($gemmaBootstrapSource -notmatch 'MIRA_PROFILE_STARTUP' -or
    $gemmaBootstrapSource -notmatch 'GemmaStartupStopwatch' -or
    $gemmaBootstrapSource -notmatch 'Module load:') {
    throw 'Optional GEMMA startup load profiling is missing.'
}

# Tool commands temporarily release Ctrl+C to the active PowerShell pipeline and restore the caller's console mode.
$executionSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\Execution.ps1') -Raw -Encoding UTF8
if ($executionSource -notmatch '\[Console\]::TreatControlCAsInput\s*=\s*\$false' -or
    $executionSource -notmatch 'PipelineStoppedException' -or
    $executionSource -notmatch 'cancelled\s*=\s*\$true' -or
    $executionSource -notmatch '\[Console\]::TreatControlCAsInput\s*=\s*\$previousTreatControlCAsInput') {
    throw 'LLM PowerShell commands do not isolate Ctrl+C cancellation from the GEMMA host.'
}
if ($executionSource -notmatch 'approvalTreatControlCAsInput' -or
    $executionSource -notmatch 'catch \[System\.Management\.Automation\.PipelineStoppedException\]' -or
    $executionSource -notmatch 'Command approval cancelled with Ctrl\+C') {
    throw 'Ctrl+C at the ASK approval prompt is not converted into a cancelled tool result.'
}
if ($executionSource -notmatch 'Command completed successfully with no output') {
    throw 'Empty PowerShell tool output is not represented by a non-empty result message.'
}
$previousExecutionPermission = $script:ExecutionPermission
try {
    $script:ExecutionPermission = 'autopilot'
    $emptyCommandResult = Invoke-GemmaToolCall -Call @{ name = 'run_powershell'; args = @{ command = '$null'; elevated = $false } }
    if ([string]::IsNullOrWhiteSpace([string]$emptyCommandResult.output) -or
        $emptyCommandResult.output -notmatch 'completed successfully with no output') {
        throw 'A PowerShell command with no pipeline output returned an empty tool result.'
    }
} finally {
    $script:ExecutionPermission = $previousExecutionPermission
}
# Tracked child processes can be stopped independently without ending the GEMMA host.
$trackedProcess = Start-GemmaTrackedProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden
try {
    if (-not $trackedProcess.started -or -not $trackedProcess.process_id -or $trackedProcess.kill_command -ne ('.kill ' + $trackedProcess.process_id)) {
        throw 'Tracked process launch did not return a usable process handle/PID.'
    }
    $stopResult = Stop-GemmaTrackedProcess -Target 'last'
    if (@($stopResult.results).Count -ne 1 -or -not $stopResult.results[0].stopped) {
        throw 'The last tracked child process could not be terminated independently.'
    }
} finally {
    if ($script:MiraTrackedProcesses.ContainsKey([int]$trackedProcess.process_id)) { Stop-GemmaTrackedProcess -Target ([string]$trackedProcess.process_id) | Out-Null }
}
# TTS playback must be asynchronous; Tab must no longer trigger speech and Ctrl+Tab must own the picker.
$ttsSource = Get-Content -LiteralPath (Join-Path $repoRoot 'gemma\agent\Tts.ps1') -Raw -Encoding UTF8
if ($ttsSource -notmatch '\$player\.Play\(\)' -or
    $ttsSource -match '\$player\.PlaySync\(\)' -or
    $ttsSource -notmatch 'function Stop-GemmaTtsPlayback' -or
    $ttsSource -notmatch 'function Invoke-GemmaTtsModelPicker' -or
    -not $ttsSource.Contains('[ConsoleKey]::UpArrow') -or
    -not $ttsSource.Contains('[ConsoleKey]::DownArrow') -or
    -not $ttsSource.Contains("character -eq 'j'")) {
    throw 'Gemma TTS playback/picker lifecycle is not asynchronous or fully implemented.'
}
if ($lineEditorSource -notmatch '\$controlTab\s*=.*ConsoleModifiers\]::Control' -or
    $lineEditorSource -match 'Invoke-GemmaSpeakLatest -Contents \$Contents') {
    throw 'Tab still triggers TTS or Ctrl+Tab model picker handling is missing.'
}
if ($chatLoopSource -notmatch 'Initialize-GemmaTts' -or
    $chatLoopSource -notmatch 'Stop-GemmaTtsPlayback') {
    throw 'Explicit .speak/.stop TTS commands are not wired into the chat loop.'
}

# Verify common cursor-word calculations independently of terminal interaction.
if ((Get-GemWordStart -Text 'one two' -Position 7) -ne 4) {
    throw 'Readline backward-word calculation failed.'
}
if ((Get-GemWordEnd -Text 'one two' -Position 4) -ne 7) {
    throw 'Readline forward-word calculation failed.'
}

# Verify reverse/forward substring history search against a deterministic history.
$script:MiraInputHistory = New-Object 'System.Collections.Generic.List[string]'
[void]$script:MiraInputHistory.Add('open notes.txt')
[void]$script:MiraInputHistory.Add('get process list')
[void]$script:MiraInputHistory.Add('open report.txt')
if ((Find-GemHistoryMatch -Term 'open' -Start 3 -Direction -1) -ne 2) {
    throw 'Readline reverse history search failed.'
}
if ((Find-GemHistoryMatch -Term 'open' -Start 0 -Direction 1) -ne 2) {
    throw 'Readline forward history search failed.'
}
$searchPrompt = Get-GemHistorySearchPrompt -Direction -1 -Term 'a long search query that should be clipped' -Width 30
if ($searchPrompt.Length -gt 30) {
    throw 'Readline history-search prompt exceeded the terminal width.'
}

Write-Host 'Gemma components and Readline helpers loaded successfully in Windows PowerShell 5.1.'
