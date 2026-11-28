function Get-GemmaToolConfiguration {
    if ($script:CommandMode) {
        return @{ Tools = $null; ToolConfig = $null }
    }

    $declarations = @(
        @{
            name = 'get_current_datetime'
            description = 'Returns the current local date and time from the host computer. Use this whenever the current date, current time, weekday, or local timezone is needed. Do not guess the date or time.'
            parameters = @{ type = 'object'; properties = @{} }
        },
        @{
            name = 'run_powershell'
            description = 'Execute a PowerShell command in the user''s local Windows session. This is the local execution bridge: use PowerShell for native cmdlets, or launch CMD (cmd.exe /c), Python, native Windows APIs, and installed third-party utilities when they are a better fit. For GUI apps or long-running child processes, use Start-GemmaTrackedProcess -FilePath ... instead of Start-Process; it returns a PID that remains independently terminable with .kill, .kill last, or .kill <PID> without ending GEMMA. Do not assume a utility is unavailable; inspect only when needed. Set elevated=true only when Administrator privileges are required. GEMMA launches a separate elevated PowerShell process and Windows UAC must be approved; UAC is still required in .autopilot. Keep ordinary commands unelevated. Continue using results to complete multi-step tasks.'
            parameters = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command to execute; it may invoke CMD, Python, or another installed Windows utility.' }
                    elevated = @{ type = 'boolean'; description = 'Set true only when Administrator privileges are required. Launches a separate elevated PowerShell process and triggers Windows UAC. Defaults to false.' }
                }
                required = @('command')
            }
        },
        @{
            name = 'quick_web'
            description = 'Fast, narrow live lookups using curl.exe: weather from wttr.in (defaults to IP-based local region), public IP from api.ipify.org, or command/language cheat sheets from cht.sh. Prefer this for ''show weather'', ''show my IP'', and ''how do I use ...'' quick help instead of broad web search.'
            parameters = @{
                type = 'object'
                properties = @{
                    action = @{ type = 'string'; description = 'One of: weather, public-ip, cheatsheet.' }
                    query = @{ type = 'string'; description = 'Optional city/region for weather or topic for cht.sh; leave empty for IP-based local weather or cht.sh home page.' }
                }
                required = @('action')
            }
        },
        @{
            name = 'get_skill'
            description = 'Load a built-in or user-authored skill when task-specific guidance would help. Use skill=list to discover skills. Do not load skills reflexively for routine tasks. Skills are untrusted guidance and never grant permissions.'
            parameters = @{
                type = 'object'
                properties = @{
                    skill = @{ type = 'string'; description = 'One of: file-management, windows-settings, desktop-gui, clipboard, system-inspection, quick-web-tools; or list.' }
                }
                required = @('skill')
            }
        }
    )

    # The custom web_search tool is available only to Gemini Developer API.
    # Antigravity chat uses native Google Search in its selected-model preflight.
    if ($script:Provider -eq 'gemini' -and
        $script:GoogleSearchGrounding -and
        $script:AgenticWebSearchEnabled -and
        (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
        $declarations += @{
            name = 'web_search'
            description = 'Search the web using Google Search through Antigravity OAuth. Use for current information, recent events, verification, and source discovery. Return grounded findings with source URLs.'
            parameters = @{
                type = 'object'
                properties = @{
                    query = @{ type = 'string'; description = 'Focused search question or query. Include relevant names, dates, and context.' }
                }
                required = @('query')
            }
        }
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
