# MIRA tool module: read-only Windows host summary.
Register-MiraTool -Name 'get_system_info' -Description 'Returns a compact read-only summary of Windows, PowerShell, CPU, memory and fixed drives.' -Parameters @{type='object';properties=@{}} -RequiresApproval $false -Handler {
    $os=Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu=Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue|Select-Object -First 1
    $drives=@(Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue|ForEach-Object{
        @{device=$_.DeviceID;size_gb=[Math]::Round(([double]$_.Size/1GB),1);free_gb=[Math]::Round(([double]$_.FreeSpace/1GB),1)}
    })
    return @{
        computer_name=$env:COMPUTERNAME
        user_name=$env:USERNAME
        os_caption=if($os){[string]$os.Caption}else{[Environment]::OSVersion.VersionString}
        os_version=[Environment]::OSVersion.Version.ToString()
        architecture=[Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
        powershell_version=$PSVersionTable.PSVersion.ToString()
        processor=if($cpu){[string]$cpu.Name}else{''}
        logical_processors=[Environment]::ProcessorCount
        total_memory_gb=if($os){[Math]::Round(([double]$os.TotalVisibleMemorySize/1MB),1)}else{$null}
        drives=$drives
    }
}
