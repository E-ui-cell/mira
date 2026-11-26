[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===')
}

$runnerUser = $env:USERNAME
$actor = $env:GITHUB_ACTOR
if ([string]::IsNullOrWhiteSpace($actor)) {
    throw 'GITHUB_ACTOR is missing; this runner must be started by a GitHub user.'
}

Write-Section 'Runner'
Write-Host "User: $runnerUser"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Session ID: $((Get-Process -Id $PID).SessionId)"
try {
    & "$env:SystemRoot\System32\query.exe" user
}
catch {
    Write-Host 'Could not query interactive sessions.'
}

Write-Section 'Passwordless SSH'
$sshRoot = Join-Path $env:ProgramData 'ssh'
$sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($sshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

$sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
$keygenExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
if (!(Test-Path -LiteralPath $sshExe) -or !(Test-Path -LiteralPath $sshdExe)) {
    throw 'Windows OpenSSH installation did not provide ssh.exe and sshd.exe.'
}

$keysUri = 'https://api.github.com/users/' + [Uri]::EscapeDataString($actor) + '/keys'
$githubKeys = @(Invoke-RestMethod -UseBasicParsing -Uri $keysUri -Headers @{
    'User-Agent' = 'MIRA-GUI-Runner'
    'Accept' = 'application/vnd.github+json'
})
$publicKeys = @($githubKeys | ForEach-Object { $_.key } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($publicKeys.Count -eq 0) {
    throw "No public SSH key is registered on GitHub account '$actor'. Add your public key under GitHub Settings > SSH and GPG keys, then start the runner again."
}

New-Item -ItemType Directory -Path $sshRoot -Force | Out-Null
$sshLogs = Join-Path $sshRoot 'logs'
New-Item -ItemType Directory -Path $sshLogs -Force | Out-Null

# OpenSSH refuses to start when ProgramData\ssh or its logs directory has unsafe ACLs.
# Keep write access limited to SYSTEM and Administrators; authenticated users get read-only access.
foreach ($directory in @($sshRoot, $sshLogs)) {
    & icacls.exe $directory /inheritance:r /remove:g '*S-1-5-11' /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' /grant '*S-1-5-11:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set secure permissions on $directory."
    }
}

$authorizedKeys = Join-Path $sshRoot 'administrators_authorized_keys'
$publicKeys | Set-Content -LiteralPath $authorizedKeys -Encoding Ascii
& icacls.exe $authorizedKeys /inheritance:r /remove:g '*S-1-5-11' /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not set secure permissions on administrators_authorized_keys.'
}

& $keygenExe -A
if ($LASTEXITCODE -ne 0) {
    throw 'Could not generate the OpenSSH host keys.'
}

# Host private keys must not inherit read access for Authenticated Users.
foreach ($hostKey in @('ssh_host_ed25519_key', 'ssh_host_rsa_key', 'ssh_host_ecdsa_key')) {
    $hostKeyPath = Join-Path $sshRoot $hostKey
    if (Test-Path -LiteralPath $hostKeyPath) {
        & icacls.exe $hostKeyPath /inheritance:r /remove:g '*S-1-5-11' /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not secure OpenSSH host key: $hostKeyPath"
        }
    }
}

$sshdConfig = Join-Path $sshRoot 'sshd_config'
$config = @"
Port 22
AddressFamily inet
ListenAddress 127.0.0.1
HostKey C:/ProgramData/ssh/ssh_host_ed25519_key
HostKey C:/ProgramData/ssh/ssh_host_rsa_key
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding yes
PermitTTY yes
AllowAgentForwarding no
X11Forwarding no
AllowUsers $runnerUser
AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys
Subsystem sftp sftp-server.exe
SyslogFacility LOCAL0
LogLevel VERBOSE
"@
Set-Content -LiteralPath $sshdConfig -Value $config -Encoding Ascii
& icacls.exe $sshdConfig /inheritance:r /remove:g '*S-1-5-11' /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not set secure permissions on sshd_config.'
}

& $sshdExe -t -f $sshdConfig
if ($LASTEXITCODE -ne 0) {
    throw 'OpenSSH rejected the generated sshd_config.'
}

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -Value '-Command' -PropertyType String -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellEscapeArguments -Value 1 -PropertyType DWord -Force | Out-Null
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service -Name sshd).Status -ne 'Running') {
    try {
        Start-Service -Name sshd -ErrorAction Stop
    }
    catch {
        Write-Section 'OpenSSH startup diagnostics'
        Write-Host 'Service registration:'
        Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue |
            Format-List Name, State, StartName, StartMode, PathName, ExitCode, ProcessId |
            Out-String | ForEach-Object { Write-Host $_ }

        Write-Host 'sshd configuration validation:'
        & $sshdExe -t -f $sshdConfig 2>&1 | ForEach-Object { Write-Host $_ }
        Write-Host "Configuration validation exit code: $LASTEXITCODE"

        Write-Host 'OpenSSH directory ACLs:'
        & icacls.exe $sshRoot 2>&1 | ForEach-Object { Write-Host $_ }
        & icacls.exe $sshLogs 2>&1 | ForEach-Object { Write-Host $_ }
        & icacls.exe $sshdConfig 2>&1 | ForEach-Object { Write-Host $_ }
        foreach ($hostKey in @('ssh_host_ed25519_key', 'ssh_host_rsa_key', 'ssh_host_ecdsa_key')) {
            $hostKeyPath = Join-Path $sshRoot $hostKey
            if (Test-Path -LiteralPath $hostKeyPath) {
                & icacls.exe $hostKeyPath 2>&1 | ForEach-Object { Write-Host $_ }
            }
        }

        # Run sshd in foreground debug mode: this exposes the daemon's own startup error,
        # which Service Control Manager's generic 7034 event omits.
        $debugStdOut = Join-Path $env:TEMP 'mira-sshd-debug.out'
        $debugStdErr = Join-Path $env:TEMP 'mira-sshd-debug.err'
        Remove-Item -LiteralPath $debugStdOut, $debugStdErr -Force -ErrorAction SilentlyContinue
        try {
            $debugProcess = Start-Process -FilePath $sshdExe -ArgumentList @('-ddd', '-e', '-f', $sshdConfig) -PassThru -NoNewWindow -RedirectStandardOutput $debugStdOut -RedirectStandardError $debugStdErr
            Start-Sleep -Seconds 4
            $debugProcess.Refresh()
            if (-not $debugProcess.HasExited) {
                Write-Host 'Foreground sshd debug process stayed alive for 4 seconds; terminating diagnostic instance.'
                Stop-Process -Id $debugProcess.Id -Force -ErrorAction SilentlyContinue
                try { $debugProcess.WaitForExit() } catch {}
            }
            else {
                Write-Host "Foreground sshd debug process exited with code $($debugProcess.ExitCode)."
            }
        }
        catch {
            Write-Host "Could not run foreground sshd diagnostics: $($_.Exception.Message)"
        }
        foreach ($debugFile in @($debugStdOut, $debugStdErr)) {
            if (Test-Path -LiteralPath $debugFile) {
                Write-Host "--- $debugFile ---"
                Get-Content -LiteralPath $debugFile -Tail 120 -ErrorAction SilentlyContinue
            }
        }

        $diagnosticStart = (Get-Date).AddMinutes(-5)
        foreach ($logName in @('OpenSSH/Operational', 'Application', 'System')) {
            try {
                $events = Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $diagnosticStart } -MaxEvents 30 -ErrorAction Stop
                foreach ($event in $events) {
                    if ($logName -eq 'System' -and $event.ProviderName -ne 'Service Control Manager') {
                        continue
                    }
                    if ($logName -eq 'Application' -and $event.ProviderName -notmatch 'OpenSSH|Application Error|Windows Error Reporting|\.NET Runtime') {
                        continue
                    }
                    Write-Host ("{0} [{1}] Event {2}: {3}" -f $event.TimeCreated, $event.ProviderName, $event.Id, $event.Message)
                }
            }
            catch {
                Write-Host "Could not read event log '$logName': $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $sshLogs) {
            Get-ChildItem -LiteralPath $sshLogs -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 5 |
                ForEach-Object {
                    Write-Host "--- $($_.FullName) ---"
                    Get-Content -LiteralPath $_.FullName -Tail 120 -ErrorAction SilentlyContinue
                }
        }
        throw
    }
}
Start-Sleep -Seconds 2

$sshListener = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
if (-not ($sshListener | Where-Object { $_.LocalAddress -eq '127.0.0.1' })) {
    throw 'OpenSSH is not listening on 127.0.0.1:22.'
}
Write-Host "SSH is ready for $runnerUser. Authentication is public-key only; no password is enabled."

Write-Section 'Passwordless VNC'
$vncVersion = '2.8.90'
$vncMsi = Join-Path $env:TEMP "tightvnc-$vncVersion-gpl-setup-64bit.msi"
$vncUrl = "https://www.tightvnc.com/download/$vncVersion/tightvnc-$vncVersion-gpl-setup-64bit.msi"
Invoke-WebRequest -UseBasicParsing -Uri $vncUrl -OutFile $vncMsi

$expectedHash = '9693CB4CDC2E7E482E8E3F5890415B57EF87DE3369FA5C337DB516218A1170CE'
$actualHash = (Get-FileHash -LiteralPath $vncMsi -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    throw "TightVNC MSI checksum mismatch. Expected $expectedHash; received $actualHash."
}

$vncArgs = @(
    '/i', $vncMsi, '/qn', '/norestart',
    'ADDLOCAL=Server',
    'SERVER_REGISTER_AS_SERVICE=1',
    'SERVER_ADD_FIREWALL_EXCEPTION=0',
    'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0',
    'SET_ACCEPTRFBCONNECTIONS=1', 'VALUE_OF_ACCEPTRFBCONNECTIONS=1',
    'SET_ALLOWLOOPBACK=1', 'VALUE_OF_ALLOWLOOPBACK=1',
    'SET_LOOPBACKONLY=1', 'VALUE_OF_LOOPBACKONLY=1',
    'SET_RFBPORT=1', 'VALUE_OF_RFBPORT=5900',
    'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=0'
)
$install = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $vncArgs -Wait -PassThru
if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
    throw "TightVNC installation failed with exit code $($install.ExitCode)."
}

$tvnServer = Join-Path $env:ProgramFiles 'TightVNC\tvnserver.exe'
if (!(Test-Path -LiteralPath $tvnServer)) {
    throw 'TightVNC Server executable was not found after installation.'
}
$tvnService = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
if (-not $tvnService) {
    & $tvnServer -install -silent
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not register the TightVNC service.'
    }
}
Set-Service -Name 'tvnserver' -StartupType Manual
Start-Service -Name 'tvnserver'
Start-Sleep -Seconds 3

$vncListeners = @(Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue)
if ($vncListeners.Count -eq 0) {
    throw 'TightVNC is not listening on TCP 5900.'
}
Write-Host 'TightVNC is configured for loopback-only access, with VNC authentication disabled.'

Write-Section 'GUI smoke test'
$guiScript = Join-Path $env:GITHUB_WORKSPACE 'tests\Gui-Smoke.ps1'
if (!(Test-Path -LiteralPath $guiScript)) {
    throw "GUI smoke script was not found: $guiScript"
}
$guiProcess = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $env:GITHUB_WORKSPACE -WindowStyle Normal -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $guiScript
)
Write-Host "Started GUI smoke window (PID $($guiProcess.Id))."

Write-Section 'Temporary SSH tunnel'
Write-Host 'Pinggy will print a temporary TCP host and port below.'
Write-Host "SSH: ssh -p <PORT> $runnerUser@<HOST>"
Write-Host "VNC tunnel: ssh -N -L 5901:127.0.0.1:5900 -p <PORT> $runnerUser@<HOST>"
Write-Host 'Then connect your VNC Viewer to 127.0.0.1::5901. No VNC password is required.'
Write-Host 'The VNC service is loopback-only; the SSH key is the access gate.'
Write-Host 'Cancel this GitHub Actions job when finished.'

$tunnelArgs = @(
    '-p', '443',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ExitOnForwardFailure=yes',
    '-T',
    '-R', '0:127.0.0.1:22',
    'tcp@free.pinggy.io'
)
& $sshExe @tunnelArgs

if ($LASTEXITCODE -ne 0) {
    throw "The Pinggy tunnel exited with code $LASTEXITCODE."
}
