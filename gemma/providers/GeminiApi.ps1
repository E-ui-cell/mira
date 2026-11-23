function Get-GeminiModels {
    if ($script:Provider -eq 'antigravity') { return Get-AntigravityModels }
    if ([string]::IsNullOrWhiteSpace($API_KEY)) {
        throw "No Antigravity OAuth token or Gemini API key found. Run .auth login or set GEMINI_API."
    }
    $allModels = New-Object 'System.Collections.Generic.List[object]'
    $pageToken = $null
    $pageCount = 0
    do {
        $uri = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100"
        if (-not [string]::IsNullOrWhiteSpace($pageToken)) { $uri += "&pageToken=$([uri]::EscapeDataString($pageToken))" }
        $page = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ "x-goog-api-key" = $API_KEY } -ErrorAction Stop
        foreach ($item in @($page.models)) {
            if ($null -ne $item -and @($item.supportedGenerationMethods) -contains "generateContent") { [void]$allModels.Add($item) }
        }
        $pageToken = [string]$page.nextPageToken
        $pageCount++
        if ($pageCount -ge 100) { throw "Google model list exceeded 100 pages; stopping to avoid an endless pagination loop." }
    } while (-not [string]::IsNullOrWhiteSpace($pageToken))
    return $allModels.ToArray()
}

. (Join-Path $PSScriptRoot 'ui\ModelPicker.ps1')
