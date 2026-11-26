$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$workspace = $env:GITHUB_WORKSPACE
if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = Split-Path -Parent $PSScriptRoot
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MIRA - Windows GUI runner'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(620, 300)
$form.MinimumSize = New-Object System.Drawing.Size(620, 300)
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$title.Text = 'GitHub Windows Server 2022 runner is ready'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 24)
$form.Controls.Add($title)

$details = New-Object System.Windows.Forms.Label
$details.Text = "User: $env:USERNAME" + [Environment]::NewLine + "Computer: $env:COMPUTERNAME" + [Environment]::NewLine + "PowerShell: $($PSVersionTable.PSVersion)" + [Environment]::NewLine + "Workspace: $workspace"
$details.Font = New-Object System.Drawing.Font('Consolas', 10)
$details.AutoSize = $true
$details.Location = New-Object System.Drawing.Point(26, 70)
$form.Controls.Add($details)

$launch = New-Object System.Windows.Forms.Button
$launch.Text = 'Launch MIRA'
$launch.Size = New-Object System.Drawing.Size(130, 36)
$launch.Location = New-Object System.Drawing.Point(26, 190)
$launch.Add_Click({
    $mira = Join-Path $workspace 'mira.ps1'
    if (Test-Path -LiteralPath $mira) {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $workspace -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mira) | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("mira.ps1 was not found:" + [Environment]::NewLine + $mira, 'MIRA runner') | Out-Null
    }
})
$form.Controls.Add($launch)

$shell = New-Object System.Windows.Forms.Button
$shell.Text = 'Open PowerShell'
$shell.Size = New-Object System.Drawing.Size(130, 36)
$shell.Location = New-Object System.Drawing.Point(170, 190)
$shell.Add_Click({
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $workspace -ArgumentList @('-NoExit', '-NoProfile') | Out-Null
})
$form.Controls.Add($shell)

$close = New-Object System.Windows.Forms.Button
$close.Text = 'Close'
$close.Size = New-Object System.Drawing.Size(100, 36)
$close.Location = New-Object System.Drawing.Point(314, 190)
$close.Add_Click({ $form.Close() })
$form.Controls.Add($close)

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
