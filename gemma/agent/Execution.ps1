if ($null -eq $script:MiraTrackedProcesses) { $script:MiraTrackedProcesses = @{} }
if ($null -eq $script:MiraTrackedProcessOrder) { $script:MiraTrackedProcessOrder = New-Object 'System.Collections.Generic.List[int]' }

function Start-GemmaTrackedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [switch]$NoNewWindow,
        [ValidateSet('Normal','Hidden','Minimized','Maximized')][string]$WindowStyle = 'Normal'
    )
    $startParameters = @{ FilePath = $FilePath; PassThru = $true; ErrorAction = 'Stop' }
    if ($ArgumentList.Count -gt 0) { $startParameters.ArgumentList = $ArgumentList }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startParameters.WorkingDirectory = $WorkingDirectory }
    if ($NoNewWindow) { $startParameters.NoNewWindow = $true } else { $startParameters.WindowStyle = $WindowStyle }
    $process = Start-Process @startParameters
    $processId = [int]$process.Id
    $script:MiraTrackedProcesses[$processId] = $process
    if (-not $script:MiraTrackedProcessOrder.Contains($processId)) { $script:MiraTrackedProcessOrder.Add($processId) }
    return @{ started = $true; process_id = $processId; process_name = $process.ProcessName; kill_command = ('.kill ' + $processId) }
}

function Stop-GemmaTrackedProcess {
    param([string]$Target = 'last')
    $ids = @()
    $value = if ([string]::IsNullOrWhiteSpace($Target)) { 'last' } else { $Target.Trim() }
    if ($value -ieq 'all') {
        $ids = @($script:MiraTrackedProcessOrder.ToArray())
    } elseif ($value -ieq 'last') {
        if ($script:MiraTrackedProcessOrder.Count -gt 0) { $ids = @([int]$script:MiraTrackedProcessOrder[$script:MiraTrackedProcessOrder.Count - 1]) }
    } else {
        $processId = 0
        if (-not [int]::TryParse($value,[ref]$processId)) { return @{ stopped = $false; error = 'Use .kill, .kill last, .kill all, or .kill <process-id>.' } }
        $ids = @($processId)
    }
    if ($ids.Count -eq 0) { return @{ stopped = $false; error = 'No tracked GEMMA-launched process was found.' } }
    $results = @()
    foreach ($processId in $ids) {
        if (-not $script:MiraTrackedProcesses.ContainsKey([int]$processId)) {
            $results += @{ process_id = [int]$processId; stopped = $false; error = 'Process is not tracked by GEMMA.' }
            continue
        }
        $process = $script:MiraTrackedProcesses[[int]$processId]
        $processName = [string]$process.ProcessName
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                if (Test-Path -LiteralPath $taskkill -PathType Leaf) { & $taskkill /PID $processId /T /F 2>&1 | Out-Null }
                $process.Refresh()
                if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
            }
            $results += @{ process_id = [int]$processId; process_name = $processName; stopped = $true; already_exited = [bool]$process.HasExited }
        } catch {
            $results += @{ process_id = [int]$processId; process_name = $processName; stopped = $false; error = $_.Exception.Message }
        } finally {
            $script:MiraTrackedProcesses.Remove([int]$processId)
            [void]$script:MiraTrackedProcessOrder.Remove([int]$processId)
            try { $process.Dispose() } catch {}
        }
    }
    return @{ results = @($results) }
}
function Invoke-GemmaPermissionCommand {
    param([ValidateSet('ask','autopilot')][string]$Mode)
    $script:ExecutionPermission = $Mode
    if ($Mode -eq 'ask') {
        Write-Host '[Local command permission mode: ASK | each requested command requires confirmation; Enter = Yes.]' -ForegroundColor Cyan
    } else {
        Write-Host '[Local command permission mode: AUTOPILOT | requested commands execute without confirmation.]' -ForegroundColor Yellow
    }
}

function Invoke-GemmaPowerShellTool {
    param([string]$Command, [bool]$Elevated = $false)
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'run_powershell requires a command.' }

    $executionHost = if ($Elevated) { 'Administrator via Windows UAC' } else { 'PowerShell execution host' }
    Write-Host ([Environment]::NewLine + "[Local command requested by model ($executionHost)]:") -ForegroundColor DarkYellow
    Write-Host $Command -ForegroundColor Gray

    # UAC is the approval step for elevated commands. Do not add a second
    # console confirmation; Windows will display its own consent prompt.
    if ($script:ExecutionPermission -eq 'ask' -and -not $Elevated) {
        $approval = Read-Host 'Execute this command? [Y/n]'
        if ($approval -match '^(?i:n|no)$') {
            return @{ approved=$false; elevated=$false; output='User declined command execution.' }
        }
    }

    if ($Elevated) {
        $previousApprovedToolState = $script:InApprovedPowerShellTool
        try {
            $script:InApprovedPowerShellTool = $true
            return Invoke-GemmaElevatedPowerShellTool -Command $Command
        } finally {
            $script:InApprovedPowerShellTool = $previousApprovedToolState
        }
    }

    $previousProgressPreference = $ProgressPreference
    $previousInformationPreference = $InformationPreference
    $previousApprovedToolState = $script:InApprovedPowerShellTool
    try {
        $script:InApprovedPowerShellTool = $true
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'
        $output = Invoke-Expression $Command *>&1 | Out-String -Width $MIRA_POWERSHELL_OUTPUT_WIDTH
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) {
            $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[PowerShell output truncated]'
        }
        return @{ approved=$true; output=$output; current_location=(Get-Location).Path }
    } catch {
        return @{ approved=$true; error=$_.Exception.Message }
    } finally {
        $ProgressPreference = $previousProgressPreference
        $InformationPreference = $previousInformationPreference
        $script:InApprovedPowerShellTool = $previousApprovedToolState
    }
}

function Invoke-GemmaElevatedPowerShellTool {
    param([Parameter(Mandatory = $true)][string]$Command)

    $token = [guid]::NewGuid().ToString('N')
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gemma-elevated-' + $token)
    $outputPath = Join-Path $temporaryDirectory 'output.txt'
    $statusPath = Join-Path $temporaryDirectory 'status.txt'
    $location = Get-Location

    try {
        [void][IO.Directory]::CreateDirectory($temporaryDirectory)

        # The UAC credential prompt may use a different administrator account.
        # Grant access only to this user and the local Administrators group so
        # the elevated child can return its output without exposing temp files
        # to other standard users.
        $directoryAcl = Get-Acl -LiteralPath $temporaryDirectory -ErrorAction Stop
        $directoryAcl.SetAccessRuleProtection($true, $false)
        $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $administratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $rights = [Security.AccessControl.FileSystemRights]::FullControl
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $userRule = New-Object Security.AccessControl.FileSystemAccessRule($currentUserSid,$rights,$inheritance,$propagation,$allow)
        $adminRule = New-Object Security.AccessControl.FileSystemAccessRule($administratorsSid,$rights,$inheritance,$propagation,$allow)
        $directoryAcl.SetAccessRule($userRule)
        $directoryAcl.AddAccessRule($adminRule)
        Set-Acl -LiteralPath $temporaryDirectory -AclObject $directoryAcl -ErrorAction Stop

        $commandBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $outputPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($outputPath))
        $statusPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusPath))
        $locationPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$location.Path))
        $width = [int]$MIRA_POWERSHELL_OUTPUT_WIDTH

        # ShellExecute/UAC does not support reliable stdout redirection.
        # The elevated child therefore writes output and exit status to this
        # one-use, ACL-protected directory.
        $childScript = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COMMAND_B64__'))
$outputPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__OUTPUT_PATH_B64__'))
$statusPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__STATUS_PATH_B64__'))
$locationPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__LOCATION_PATH_B64__'))
$width = [int]'__OUTPUT_WIDTH__'
$global:LASTEXITCODE = $null
$global:Error.Clear()
$result = @()
$exitCode = 0
try {
    if (-not [string]::IsNullOrWhiteSpace($locationPath)) {
        try { Set-Location -LiteralPath $locationPath -ErrorAction Stop } catch {}
    }
    $result = @(Invoke-Expression -Command $command *>&1)
    if ($null -ne $global:LASTEXITCODE) {
        $exitCode = [int]$global:LASTEXITCODE
    } elseif ($global:Error.Count -gt 0) {
        $exitCode = 1
    }
} catch {
    $result += $_
    $exitCode = 1
}
try {
    $rendered = ''
    if ($result.Count -gt 0) {
        $rendered = [string]($result | Out-String -Width $width)
    }
    [IO.File]::WriteAllText($outputPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($statusPath, [string]$exitCode, [Text.Encoding]::ASCII)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit $exitCode
'@
        $childScript = $childScript.Replace('__COMMAND_B64__', $commandBase64)
        $childScript = $childScript.Replace('__OUTPUT_PATH_B64__', $outputPathBase64)
        $childScript = $childScript.Replace('__STATUS_PATH_B64__', $statusPathBase64)
        $childScript = $childScript.Replace('__LOCATION_PATH_B64__', $locationPathBase64)
        $childScript = $childScript.Replace('__OUTPUT_WIDTH__', [string]$width)
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

        $powerShellExeName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $powerShellExe = Join-Path $PSHOME $powerShellExeName
        if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
            $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }

        $workingDirectory = [Environment]::CurrentDirectory
        if ($location.Provider.Name -eq 'FileSystem' -and
            -not [string]::IsNullOrWhiteSpace([string]$location.ProviderPath)) {
            $workingDirectory = [string]$location.ProviderPath
        }
        if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
            $workingDirectory = $env:SystemRoot
        }

        $process = Start-Process -FilePath $powerShellExe -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-EncodedCommand', $encodedScript
        ) -Verb RunAs -WindowStyle Hidden -WorkingDirectory $workingDirectory -Wait -PassThru -ErrorAction Stop

        $output = ''
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
            $output = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
        }
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) {
            $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[Elevated PowerShell output truncated]'
        }

        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            return @{
                approved = $true
                elevated = $true
                output = $output
                exit_code = [int]$process.ExitCode
                error = 'Elevated PowerShell exited without writing its completion status.'
                current_location = [string]$location.Path
            }
        }

        $statusText = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::ASCII).Trim()
        $exitCode = 0
        if (-not [int]::TryParse($statusText, [ref]$exitCode)) {
            $exitCode = [int]$process.ExitCode
        }

        return @{
            approved = $true
            elevated = $true
            output = $output
            exit_code = $exitCode
            current_location = [string]$location.Path
        }
    } catch {
        $nativeErrorCode = 0
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.ComponentModel.Win32Exception]) {
                $nativeErrorCode = [int]$exception.NativeErrorCode
                break
            }
            $exception = $exception.InnerException
        }
        if ($nativeErrorCode -eq 1223 -or $_.Exception.Message -match '(?i)canceled|cancelled by the user') {
            return @{ approved=$false; elevated=$true; cancelled=$true; output='Windows UAC elevation was cancelled by the user.' }
        }
        return @{ approved=$false; elevated=$true; error=$_.Exception.Message }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GemmaQuickWeb {
    param([ValidateSet('weather','public-ip','cheatsheet')][string]$Action,[string]$Query = '')
    switch ($Action) {
        'weather' {
            $location = $Query.Trim()
            $url = if ($location) { 'https://wttr.in/' + [Uri]::EscapeDataString($location) + '?format=3' } else { 'https://wttr.in/?format=3' }
        }
        'public-ip' { $url = 'https://api.ipify.org' }
        'cheatsheet' {
            $topic = $Query.Trim().Trim('/')
            if (-not $topic) { $url = 'https://cht.sh/' }
            else {
                $encoded = (@($topic -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                $url = 'https://cht.sh/' + $encoded
            }
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        $result = & $curl.Source -fsS --max-time 15 --max-filesize 50000 $url 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "Quick web request failed (curl exit $exitCode): $([string]::Join(' ',@($result)))" }
        return [string]::Join([Environment]::NewLine,@($result))
    }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    return [string]$response.Content
}
