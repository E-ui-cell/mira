function Get-GeminiApiKeys {
    # Return only the explicit candidates configured in Defaults.ps1.
    return @($script:GeminiApiKeys)
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
        $page = $null
        $lastError = $null
        for ($keyOffset = 0; $keyOffset -lt $keys.Count; $keyOffset++) {
            $candidateIndex = ($keyIndex + $keyOffset) % $keys.Count
            try {
                $page = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'x-goog-api-key' = $keys[$candidateIndex] } -TimeoutSec 30 -ErrorAction Stop
                $keyIndex = $candidateIndex
                $script:MiraGeminiApiKeyIndex = ($keyIndex + 1) % $keys.Count
                break
            } catch {
                $lastError = $_
                $status = 0
                try { $status = [int]$_.Exception.Response.StatusCode } catch {}
                if ($status -notin @(0,401,403,408,429,500,502,503,504)) { throw }
            }
        }
        if ($null -eq $page) { throw "Gemini model discovery failed with all configured API keys. $($lastError.Exception.Message)" }
        foreach ($item in @($page.models)) {
            if ($null -ne $item -and @($item.supportedGenerationMethods) -contains "generateContent") { [void]$allModels.Add($item) }
        }
        $pageToken = [string]$page.nextPageToken
        $pageCount++
        if ($pageCount -ge 100) { throw "Google model list exceeded 100 pages; stopping to avoid an endless pagination loop." }
    } while (-not [string]::IsNullOrWhiteSpace($pageToken))
    return $allModels.ToArray()
}

