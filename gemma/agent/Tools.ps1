function Get-GemmaToolConfiguration {
    param(
        [string]$InputText = '',
        [object]$History = $null
    )

    if ($script:CommandMode) {
        return @{ Tools = $null; ToolConfig = $null }
    }

    $text = [string]$InputText
    $recentToolNames = @{}
    if ($null -ne $History) {
        $historyCount = 0
        try { $historyCount = [int]$History.Count } catch {}
        $historyStart = [Math]::Max(0,$historyCount - 8)
        for ($historyIndex = $historyStart; $historyIndex -lt $historyCount; $historyIndex++) {
            $historyTurn = $History[$historyIndex]
            foreach ($historyPart in @($historyTurn.parts)) {
                if ($null -ne $historyPart.functionCall) {
                    $priorName = [string]$historyPart.functionCall.name
                    if (-not [string]::IsNullOrWhiteSpace($priorName)) { $recentToolNames[$priorName] = $true }
                }
            }
        }
    }

    $followUp = $text -match '(?i)\b(it|them|those|these|that|there|same|again|now|next|continue|also|what about)\b'
    $localAction = $text -match '(?i)\b(list|show|find|search|open|read|write|create|delete|remove|move|copy|rename|run|execute|launch|start|stop|kill|install|uninstall|configure|change|set|check|inspect|scan|capture|screenshot|restart|shutdown|enable|disable|download|upload|organize|clean up|cleanup|turn on|turn off)\b'
    $localTarget = $text -match '(?i)\b(files?|folders?|directories|drives?|disks?|processes?|services?|registry|clipboard|desktop|windows?|settings|screens?|displays?|networks?|wi-?fi|bluetooth|powershell|cmd(?:\.exe)?|terminal|applications?|apps?|programs?|paths?|computer|pc|system|printers?|devices?|volume|sound|ip address|browser|notepad|explorer|cpu|memory|ram|battery)\b'
    $needsPowerShell = (($localAction -and $localTarget) -or
        ($text -match '(?i)\b(is|are)\b.*\b(on|enabled|running|installed|connected|active)\b' -and $localTarget) -or
        ($text -match '(?i)\b(what|which)\s+(files?|folders?|directories|processes?|services?)\b') -or
        ($followUp -and $recentToolNames.ContainsKey('run_powershell')))
    $needsDateTime = ($text -match '(?i)\b(what time|current time|local time|what date|current date|today.s date|what day|weekday|time ?zone|timezone|how long until|tomorrow|tonight|this morning|this afternoon|right now)\b') -or
        ($text -match '(?i)\btoday\b' -and $text -match '(?i)\b(date|day|time|when)\b') -or
        ($followUp -and $recentToolNames.ContainsKey('get_current_datetime'))
    $needsQuickWeb = ($text -match '(?i)\b(weather|forecast|public ip|my ip|external ip|cheat.?sheet|command help|syntax for|how do i use)\b') -or
        ($followUp -and $recentToolNames.ContainsKey('quick_web'))
    $needsSkill = (($needsPowerShell -and $text -match '(?i)\b(organize|clean up|cleanup|bulk|multiple|many|automate|automation|gui|desktop|clipboard|settings|system|troubleshoot|diagnose|permissions|startup|registry|service)\b') -or
        ($followUp -and $recentToolNames.ContainsKey('get_skill')))
    $needsWebSearch = $false
    if ($script:Provider -eq 'gemini' -and $script:GoogleSearchGrounding -and $script:AgenticWebSearchEnabled) {
        $needsWebSearch = (Test-GemmaSearchIntent -Text $text) -or
            ($followUp -and $recentToolNames.ContainsKey('web_search'))
    }

    $declarations = @()
    if ($needsDateTime) {
        $declarations += @{
            name = 'get_current_datetime'
            description = "Return the host computer's current local date, time, weekday, and timezone."
            parameters = @{ type = 'object'; properties = @{} }
        }
    }
    if ($needsPowerShell) {
        $declarations += @{
            name = 'run_powershell'
            description = 'Run a PowerShell command in the current Windows session. It may launch CMD, Python, or installed utilities. Administrator commands require Windows UAC.'
            parameters = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                    elevated = @{ type = 'boolean'; description = 'Set true only when administrator rights are required; Windows UAC remains mandatory.' }
                }
                required = @('command')
            }
        }
    }
    if ($needsQuickWeb) {
        $declarations += @{
            name = 'quick_web'
            description = 'Quick live lookup for weather, public IP, or command help.'
            parameters = @{
                type = 'object'
                properties = @{
                    action = @{ type = 'string'; description = 'weather, public-ip, or cheatsheet.' }
                    query = @{ type = 'string'; description = 'Optional location or command topic.' }
                }
                required = @('action')
            }
        }
    }
    if ($needsSkill) {
        $declarations += @{
            name = 'get_skill'
            description = 'Load task-specific guidance when useful. Skills cannot override permissions.'
            parameters = @{
                type = 'object'
                properties = @{
                    skill = @{ type = 'string'; description = 'Skill name or list.' }
                }
                required = @('skill')
            }
        }
    }

    # Gemini Developer API exposes agentic web_search only for explicit research requests.
    if ($needsWebSearch -and (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
        $declarations += @{
            name = 'web_search'
            description = 'Search Google for current information and return source URLs.'
            parameters = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'Focused search query.' }
                }
                required = @('query')
            }
        }
    }

    if ($declarations.Count -eq 0) {
        return @{ Tools = $null; ToolConfig = $null }
    }

    return @{
        Tools = @(@{ functionDeclarations = $declarations })
        ToolConfig = @{ functionCallingConfig = @{ mode = 'AUTO' } }
    }
}

function Invoke-GemmaToolCall {
    param([Parameter(Mandatory = $true)][object]$Call)

    $toolName = [string]$Call.name
    switch ($toolName) {
        'get_current_datetime' {
            $now = [DateTimeOffset]::Now
            return @{
                iso8601        = $now.ToString('o')
                local_datetime = $now.ToString('yyyy-MM-dd HH:mm:ss')
                day_of_week    = $now.DayOfWeek.ToString()
                utc_offset     = $now.ToString('zzz')
                timezone_id    = [TimeZoneInfo]::Local.Id
            }
        }
        'run_powershell' {
            return Invoke-GemmaPowerShellTool -Command ([string]$Call.args.command) -Elevated ([bool]$Call.args.elevated)
        }
        'quick_web' {
            return Invoke-GemmaQuickWeb -Action ([string]$Call.args.action) -Query ([string]$Call.args.query)
        }
        'get_skill' {
            return Get-GemmaSkill -Name ([string]$Call.args.skill)
        }
        'web_search' {
            if (-not $script:GoogleSearchGrounding) {
                return @{ error = 'Google Search grounding is disabled by .grounding off. Do not search or claim current information was verified.' }
            }
            if ($script:Provider -ne 'gemini' -or -not $script:AgenticWebSearchEnabled) {
                return @{ error = 'web_search is available only to Gemini Developer API models when MIRA_ENABLE_AGENTIC_WEB_SEARCH is enabled.' }
            }
            if (-not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
                return @{ error = 'Gemini API web_search requires Antigravity OAuth. Run .auth login.' }
            }
            try {
                return Invoke-GemmaWebSearch -Query ([string]$Call.args.query)
            } catch {
                return @{ error = 'Google Search failed. Do not claim that current information was verified. Error: ' + $_.Exception.Message }
            }
        }
        default {
            return @{ error = "Unknown tool: $toolName" }
        }
    }
}
