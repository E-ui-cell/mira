# MIRA tool module: bounded local file operations.
# This module is dot-sourced by MIRA and registers tools through Register-MiraTool.

Register-MiraTool -Name 'search_files' -Description 'Search file names under a user-specified directory, optionally matching file contents. Read-only and bounded to 200 results.' -Parameters @{
    type='object'
    properties=@{
        root=@{type='string';description='Directory to search.'}
        pattern=@{type='string';description='File name wildcard, e.g. *.log or notes*.'}
        content_query=@{type='string';description='Optional literal text that must occur in the file.'}
        max_results=@{type='integer';description='Maximum results, 1 to 200; defaults to 50.'}
    }
    required=@('root','pattern')
} -RequiresApproval $true -Handler {
    param($toolArgs)
    $rootText=[string]$toolArgs.root
    if([string]::IsNullOrWhiteSpace($rootText)){throw 'search_files requires root.'}
    $root=Resolve-Path -LiteralPath $rootText -ErrorAction Stop
    if($root.Provider.Name -ne 'FileSystem'){throw 'search_files only supports filesystem paths.'}
    $pattern=[string]$toolArgs.pattern
    if([string]::IsNullOrWhiteSpace($pattern)){$pattern='*'}
    $limit=50
    if($null -ne $toolArgs.max_results -and [int]$toolArgs.max_results -gt 0){$limit=[Math]::Min(200,[int]$toolArgs.max_results)}
    $query=[string]$toolArgs.content_query
    $results=New-Object System.Collections.Generic.List[object]
    foreach($file in Get-ChildItem -LiteralPath $root.Path -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue){
        if($results.Count -ge $limit){break}
        if($query){
            $match=Select-String -LiteralPath $file.FullName -SimpleMatch -Pattern $query -List -ErrorAction SilentlyContinue
            if($null -eq $match){continue}
            [void]$results.Add([pscustomobject]@{path=$file.FullName;length=$file.Length;last_write_time=$file.LastWriteTime.ToString('o');match_line=[int]$match.LineNumber;match=$match.Line.Trim()})
        }else{
            [void]$results.Add([pscustomobject]@{path=$file.FullName;length=$file.Length;last_write_time=$file.LastWriteTime.ToString('o')})
        }
    }
    return @{root=$root.Path;pattern=$pattern;content_query=$query;count=$results.Count;results=@($results)}
}

Register-MiraTool -Name 'read_text_file' -Description 'Read a user-selected text file up to 256 KB. Requires ASK/AUTOPILOT permission because file contents may be sensitive.' -Parameters @{
    type='object'
    properties=@{
        path=@{type='string';description='Full or relative path to a text file.'}
        max_chars=@{type='integer';description='Maximum returned characters, up to 20000; defaults to 12000.'}
    }
    required=@('path')
} -RequiresApproval $true -Handler {
    param($toolArgs)
    $pathText=[string]$toolArgs.path
    if([string]::IsNullOrWhiteSpace($pathText)){throw 'read_text_file requires path.'}
    $item=Get-Item -LiteralPath $pathText -Force -ErrorAction Stop
    if($item.PSIsContainer){throw 'read_text_file does not read directories.'}
    if($item.Length -gt 262144){throw 'File exceeds the 256 KB read limit.'}
    $limit=12000
    if($null -ne $toolArgs.max_chars -and [int]$toolArgs.max_chars -gt 0){$limit=[Math]::Min(20000,[int]$toolArgs.max_chars)}
    $text=[IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8)
    $truncated=$false
    if($text.Length -gt $limit){$text=$text.Substring(0,$limit);$truncated=$true}
    return @{path=$item.FullName;length=$item.Length;truncated=$truncated;content=$text}
}
