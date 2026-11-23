function Initialize-GemmaNativeWindows {
    if ('GemmaNativeWindows' -as [type]) { return }
    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class GemmaWindowInfo { public IntPtr Handle {get;set;} public int ProcessId {get;set;} public string Title {get;set;} }
public static class GemmaNativeWindows {
 const uint CF_UNICODETEXT=13, GMEM_MOVEABLE=2;
 delegate bool EnumWindowsProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll",SetLastError=true)] static extern bool OpenClipboard(IntPtr h);
 [DllImport("user32.dll",SetLastError=true)] static extern bool CloseClipboard();
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetClipboardData(uint f);
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetClipboardData(uint f,IntPtr h);
 [DllImport("user32.dll",SetLastError=true)] static extern bool EmptyClipboard();
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalLock(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalUnlock(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalAlloc(uint f,UIntPtr n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalFree(IntPtr h);
 [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(EnumWindowsProc cb,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",SetLastError=true)] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",SetLastError=true)] static extern bool ShowWindow(IntPtr h,int cmd);
 [DllImport("user32.dll",SetLastError=true)] static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll",SetLastError=true)] static extern bool IsWindow(IntPtr h);
 static void OpenRetry(){for(int i=0;i<8;i++){if(OpenClipboard(IntPtr.Zero))return;System.Threading.Thread.Sleep(40);}throw new InvalidOperationException("Clipboard is busy or unavailable.");}
 public static string ReadText(){OpenRetry();try{IntPtr h=GetClipboardData(CF_UNICODETEXT);if(h==IntPtr.Zero)return null;IntPtr p=GlobalLock(h);if(p==IntPtr.Zero)throw new InvalidOperationException("Cannot lock clipboard data.");try{return Marshal.PtrToStringUni(p);}finally{GlobalUnlock(h);}}finally{CloseClipboard();}}
 public static void WriteText(string value){byte[] b=Encoding.Unicode.GetBytes((value??"")+"\0");IntPtr h=GlobalAlloc(GMEM_MOVEABLE,new UIntPtr((uint)b.Length));if(h==IntPtr.Zero)throw new OutOfMemoryException("GlobalAlloc failed.");bool transferred=false;try{IntPtr p=GlobalLock(h);if(p==IntPtr.Zero)throw new InvalidOperationException("Cannot lock clipboard allocation.");try{Marshal.Copy(b,0,p,b.Length);}finally{GlobalUnlock(h);}OpenRetry();try{if(!EmptyClipboard())throw new InvalidOperationException("EmptyClipboard failed.");if(SetClipboardData(CF_UNICODETEXT,h)==IntPtr.Zero)throw new InvalidOperationException("SetClipboardData failed.");transferred=true;}finally{CloseClipboard();}}finally{if(!transferred)GlobalFree(h);}}
 public static List<GemmaWindowInfo> Windows(){var a=new List<GemmaWindowInfo>();EnumWindows(delegate(IntPtr h,IntPtr l){if(!IsWindowVisible(h))return true;var s=new StringBuilder(1024);if(GetWindowText(h,s,s.Capacity)<=0)return true;uint pid;GetWindowThreadProcessId(h,out pid);a.Add(new GemmaWindowInfo{Handle=h,ProcessId=(int)pid,Title=s.ToString()});return true;},IntPtr.Zero);return a;}
 public static bool Activate(long value){IntPtr h=new IntPtr(value);if(!IsWindow(h))return false;ShowWindow(h,9);return SetForegroundWindow(h);}
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}
function Confirm-GemmaDirectAction {
    param([string]$Description)
    if ($script:InApprovedPowerShellTool) { return $true }
    if ($script:ExecutionPermission -eq 'autopilot') { return $true }
    Write-Host "[Action] $Description" -ForegroundColor Yellow
    return ((Read-Host 'Proceed? [Y/n]') -notmatch '^(?i:n|no)$')
}
function Invoke-GemmaDirectCommand {
    param([string]$Name,[string]$Argument)
    if ($Name.Trim().ToLowerInvariant() -in @('clipboard-read','clipboard-write','window-list','window-activate')) { Initialize-GemmaNativeWindows }
    switch ($Name.Trim().ToLowerInvariant()) {
        'help' { return "Commands: system-info, process-list, clipboard-read, clipboard-write, window-list, window-activate, ui-tree, ui-action, app-launch, settings-open, network-check, file-search. Skills: `$HOME\.gemma\skills\<name>.md. CLI: gemma -p <request> | gemma -e <command request>." }
        'system-info' {
            $os=Get-CimInstance Win32_OperatingSystem; $cs=Get-CimInstance Win32_ComputerSystem; $cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
            return [pscustomobject]@{Computer=$cs.Name;Manufacturer=$cs.Manufacturer;Model=$cs.Model;OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber;Architecture=$os.OSArchitecture;CPU=$cpu.Name;RAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);PowerShell=$PSVersionTable.PSVersion.ToString()}
        }
        'process-list' { return @(Get-Process|Sort-Object WorkingSet64 -Descending|Select-Object -First 30 Id,ProcessName,CPU,@{n='MemoryMB';e={[math]::Round($_.WorkingSet64/1MB,1)}}) }
        'clipboard-read' {
            $value=[GemmaNativeWindows]::ReadText()
            if ($null -eq $value) { return @{format='unsupported-or-empty';text=$null} }
            return @{format='unicode-text';text=$value}
        }
        'clipboard-write' {
            if (-not (Confirm-GemmaDirectAction 'Replace the current Windows clipboard contents.')) { throw 'Clipboard write not approved.' }
            [GemmaNativeWindows]::WriteText($Argument)
            return @{written=$true;characters=$Argument.Length}
        }
        'window-list' {
            return @([GemmaNativeWindows]::Windows() | ForEach-Object {
                $processName=try{(Get-Process -Id $_.ProcessId -ErrorAction Stop).ProcessName}catch{'unknown'}
                [pscustomobject]@{Handle=('0x{0:X}' -f $_.Handle.ToInt64());ProcessId=$_.ProcessId;Process=$processName;Title=$_.Title}
            })
        }
        'window-activate' {
            if ($Argument -notmatch '^(0x[0-9a-fA-F]+|[0-9]+)$') { throw 'Provide a decimal or 0x window handle.' }
            $handle=if($Argument.StartsWith('0x')){[Convert]::ToInt64($Argument.Substring(2),16)}else{[long]$Argument}
            if (-not (Confirm-GemmaDirectAction "Activate window $Argument")) { throw 'Window activation not approved.' }
            return @{activated=[GemmaNativeWindows]::Activate($handle);handle=$Argument}
        }
        'settings-open' {
            $allowed=@('display','sound','network-wifi','network-ethernet','appsfeatures','windowsupdate','privacy','bluetooth','printers','storagesense','startupapps','about','activation','notifications','personalization','windowssecurity')
            $page=$Argument.Trim().ToLowerInvariant()
            if($page -notin $allowed){throw ('Unsupported settings page. Allowed: '+($allowed -join ', '))}
            if(-not (Confirm-GemmaDirectAction "Open Windows Settings page: $page")){throw 'Settings launch not approved.'}
            Start-Process -FilePath ("ms-settings:"+$page) -ErrorAction Stop
            return @{opened=$true;page=$page}
        }
        'app-launch' {
            if ([string]::IsNullOrWhiteSpace($Argument)) { throw 'Provide an application path or name.' }
            if (-not (Confirm-GemmaDirectAction "Launch application: $Argument")) { throw 'Application launch not approved.' }
            $p=Start-Process -FilePath $Argument -PassThru -ErrorAction Stop
            return @{launched=$true;process_id=$p.Id;application=$Argument}
        }
        'network-check' {
            $dns=@(Get-DnsClientServerAddress -ErrorAction SilentlyContinue|Where-Object{$_.ServerAddresses.Count -gt 0}|Select-Object InterfaceAlias,AddressFamily,ServerAddresses)
            $ok=Test-NetConnection www.google.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
            return @{dns=$dns;google_https_reachable=[bool]$ok}
        }
        'file-search' {
            $parts=$Argument -split '\|',2
            if($parts.Count -ne 2){throw 'Usage: file-search <path>|<wildcard>'}
            return @(Get-ChildItem -LiteralPath $parts[0] -Filter $parts[1] -File -Recurse -ErrorAction SilentlyContinue|Select-Object -First 500 FullName,Length,LastWriteTime)
        }
        'ui-action' {
            $parts=$Argument -split '\|',4
            if($parts.Count -lt 3){throw 'Usage: ui-action <window-handle>|<automation-id-or-name>|<invoke|toggle|setvalue>|[value]'}
            $handleText=$parts[0];$target=$parts[1];$action=$parts[2].ToLowerInvariant();$value=if($parts.Count -gt 3){$parts[3]}else{''}
            if($handleText -notmatch '^(0x[0-9a-fA-F]+|[0-9]+)$'){throw 'Invalid window handle.'}
            $handle=if($handleText.StartsWith('0x')){[Convert]::ToInt64($handleText.Substring(2),16)}else{[long]$handleText}
            if($action -notin @('invoke','toggle','setvalue')){throw 'Supported UI actions: invoke, toggle, setvalue.'}
            if(-not (Confirm-GemmaDirectAction "UI Automation $action on '$target' in window $handleText")){throw 'UI action not approved.'}
            Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
            Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
            $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$handle)
            if($null -eq $root){throw 'UI Automation could not attach to the window.'}
            $elements=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
            $match=$null
            foreach($element in $elements){if($element.Current.AutomationId -ceq $target -or $element.Current.Name -ceq $target){$match=$element;break}}
            if($null -eq $match){throw "No control matched AutomationId or Name '$target'."}
            switch($action){
                'invoke' {$pattern=$null;if(-not $match.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw 'Target does not support InvokePattern.'};$pattern.Invoke()}
                'toggle' {$pattern=$null;if(-not $match.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$pattern)){throw 'Target does not support TogglePattern.'};$pattern.Toggle()}
                'setvalue' {$pattern=$null;if(-not $match.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){throw 'Target does not support ValuePattern.'};if($pattern.Current.IsReadOnly){throw 'Target value is read-only.'};$pattern.SetValue($value)}
            }
            return @{success=$true;target=$target;action=$action}
        }
        'ui-tree' {
            if($Argument -notmatch '^(0x[0-9a-fA-F]+|[0-9]+)$'){throw 'Provide a window handle.'}
            Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
            Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
            $h=if($Argument.StartsWith('0x')){[Convert]::ToInt64($Argument.Substring(2),16)}else{[long]$Argument}
            $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
            if($null -eq $root){throw 'UI Automation could not attach to window.'}
            $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
            $queue=New-Object System.Collections.Queue; $queue.Enqueue(@($root,0))
            $items=New-Object System.Collections.Generic.List[object]
            while($queue.Count -gt 0 -and $items.Count -lt 150){
                $entry=$queue.Dequeue();$element=$entry[0];$depth=[int]$entry[1]
                $items.Add([pscustomobject]@{Depth=$depth;Name=$element.Current.Name;AutomationId=$element.Current.AutomationId;ControlType=$element.Current.ControlType.ProgrammaticName;Enabled=$element.Current.IsEnabled;Offscreen=$element.Current.IsOffscreen})|Out-Null
                if($depth -ge 5){continue}
                $child=$walker.GetFirstChild($element)
                while($null -ne $child){$queue.Enqueue(@($child,$depth+1));$child=$walker.GetNextSibling($child)}
            }
            return @($items)
        }
        default { throw "Unknown direct command '$Name'. Available: help, system-info, process-list, clipboard-read, clipboard-write, window-list, window-activate, ui-tree, ui-action, app-launch, settings-open, network-check, file-search." }
    }
}
