function Get-GeminiApiKeys {
    $raw = @()
    if (-not [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEYS)) { $raw += ($env:GEMINI_API_KEYS -split '[;,\r\n]+') }
    foreach ($name in @('GEMINI_API','GEMINI_API_KEY','GEMINI_APIJ')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $raw += $value }
    }
    $seen = @{}
    $keys = @(foreach ($item in $raw) {
        $key = ([string]$item).Trim().Trim('"').Trim("'")
        if ($key -and -not $seen.ContainsKey($key)) { $seen[$key] = $true; $key }
    })
    return ,$keys
}

function Get-GeminiModels {
    if ($script:Provider -eq 'antigravity') { return Get-AntigravityModels }
    $keys = @(Get-GeminiApiKeys)
    if ($keys.Count -eq 0) { throw 'No Gemini API key found. Set GEMINI_API or GEMINI_API_KEYS.' }
    $keyIndex = 0
    $allModels = New-Object 'System.Collections.Generic.List[object]'
    $pageToken = $null
    $pageCount = 0
    do {
        $uri = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100"
        if (-not [string]::IsNullOrWhiteSpace($pageToken)) { $uri += "&pageToken=$([uri]::EscapeDataString($pageToken))" }
        $page = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'x-goog-api-key' = $keys[$keyIndex] } -ErrorAction Stop
        foreach ($item in @($page.models)) {
            if ($null -ne $item -and @($item.supportedGenerationMethods) -contains "generateContent") { [void]$allModels.Add($item) }
        }
        $pageToken = [string]$page.nextPageToken
        $pageCount++
        if ($pageCount -ge 100) { throw "Google model list exceeded 100 pages; stopping to avoid an endless pagination loop." }
    } while (-not [string]::IsNullOrWhiteSpace($pageToken))
    return $allModels.ToArray()
}

