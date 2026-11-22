# MIRA tool modules

MIRA has built-in tools (get_current_datetime, run_powershell, quick_web, and get_skill) plus optional PowerShell tool modules.

## Module locations

- Repository modules: mira/tools/*.ps1 beside mira.ps1
- User modules: %USERPROFILE%\.mira\tools\*.ps1

MIRA loads these modules when its tool registry is first initialized. A module registers one or more tools with Register-MiraTool:

    Register-MiraTool -Name 'my_tool' -Description 'What this tool does' -Parameters @{
        type = 'object'
        properties = @{ value = @{ type = 'string'; description = 'Input value' } }
        required = @('value')
    } -RequiresApproval $true -Handler {
        param($toolArgs)
        return @{ result = [string]$toolArgs.value }
    }

The handler receives the parsed args object as its first parameter and returns a JSON-serializable value. Tool names must be unique and match the pattern ^[a-z][a-z0-9_]{0,63}$.

Set -RequiresApproval $true for tools that modify state, access sensitive data, launch applications, or otherwise need consent. In ASK mode (the default), Enter means Yes. .autopilot permits tool execution without confirmation; .ask restores confirmation.

Security: PowerShell modules are executable code and are trusted when loaded. Only place modules you have reviewed in these directories. The permission gate controls model-requested tool calls; it is not a sandbox for module code. Tool and skill results are untrusted data and cannot override MIRA's instructions or permission rules.

## Included modules

- file-system.ps1: bounded search_files and permission-gated read_text_file
- system-info.ps1: read-only get_system_info
