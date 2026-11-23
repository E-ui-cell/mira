function Get-AntigravityClientCredentials {
    # Public installed-app credentials from the Antigravity-compatible client reference.
    # They are not user credentials; user refresh/access tokens are stored separately.
    $idBytes = @(49,48,55,49,48,48,54,48,54,48,53,57,49,45,116,109,104,115,115,105,110,50,104,50,49,108,99,114,101,50,51,53,118,116,111,108,111,106,104,52,103,52,48,51,101,112,46,97,112,112,115,46,103,111,111,103,108,101,117,115,101,114,99,111,110,116,101,110,116,46,99,111,109)
    $secretBytes = @(71,79,67,83,80,88,45,75,53,56,70,87,82,52,56,54,76,100,76,74,49,109,76,66,56,115,88,67,52,122,54,113,68,65,102)
    $clientId = if ($env:AGY_GOOGLE_CLIENT_ID) { $env:AGY_GOOGLE_CLIENT_ID } else { -join ([char[]]$idBytes) }
    $clientSecret = if ($env:AGY_GOOGLE_CLIENT_SECRET) { $env:AGY_GOOGLE_CLIENT_SECRET } else { -join ([char[]]$secretBytes) }
    return @{ ClientId = $clientId; ClientSecret = $clientSecret }
}

function Get-AntigravityHomeDirectory {
    $homePath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = [string]$env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = [string]$HOME }
    if ([string]::IsNullOrWhiteSpace($homePath)) { throw 'Could not determine the current Windows user profile directory.' }
    return [System.IO.Path]::GetFullPath($homePath)
}

function Get-AntigravityTokenPath {
    $homePath = Get-AntigravityHomeDirectory
    return [System.IO.Path]::Combine($homePath,'.gemini','antigravity-cli','antigravity-oauth-token')
}

function ConvertTo-GemmaBase64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-GemmaRandomString {
    param([int]$ByteCount = 32)
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ConvertTo-GemmaBase64Url -Bytes $bytes
}

function Save-AntigravityToken {
    param([hashtable]$TokenData)
    $path = Get-AntigravityTokenPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $json = $TokenData | ConvertTo-Json -Depth 8
    $temp = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backup = $null

    try {
        [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))

        if (Test-Path -LiteralPath $path) {
            # File.Replace requires a valid backup path on some .NET/Windows
            # combinations; passing $null can produce "path is not of a legal form".
            $backup = $path + '.bak-' + [guid]::NewGuid().ToString('N')
            [System.IO.File]::Replace($temp, $path, $backup)
            if (Test-Path -LiteralPath $backup) {
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
        } else {
            [System.IO.File]::Move($temp, $path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AntigravityTokenRequest {
    param([hashtable]$Form)
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Form.Keys) {
        [void]$pairs.Add(([uri]::EscapeDataString([string]$key) + '=' + [uri]::EscapeDataString([string]$Form[$key])))
    }
    $body = [string]::Join('&', $pairs)
    try {
        return Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $body -ErrorAction Stop
    } catch {
        throw "Google OAuth token request failed: $($_.Exception.Message)"
    }
}

function Invoke-AntigravityLogin {
    $credentials = Get-AntigravityClientCredentials
    if ([string]::IsNullOrWhiteSpace($credentials.ClientId) -or [string]::IsNullOrWhiteSpace($credentials.ClientSecret)) { throw 'Antigravity OAuth client credentials are unavailable.' }
    $state = New-GemmaRandomString -ByteCount 32
    $verifier = New-GemmaRandomString -ByteCount 64
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $challengeBytes = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier)) } finally { $sha.Dispose() }
    $challenge = ConvertTo-GemmaBase64Url -Bytes $challengeBytes
    $scopes = 'https://www.googleapis.com/auth/aicode https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs openid'
    $parameters = [ordered]@{
        client_id = $credentials.ClientId
        redirect_uri = 'https://antigravity.google/oauth-callback'
        response_type = 'code'
        scope = $scopes
        access_type = 'offline'
        prompt = 'consent'
        state = $state
        code_challenge = $challenge
        code_challenge_method = 'S256'
    }
    $query = @($parameters.Keys | ForEach-Object { [uri]::EscapeDataString([string]$_) + '=' + [uri]::EscapeDataString([string]$parameters[$_]) }) -join '&'
    $authUrl = 'https://accounts.google.com/o/oauth2/v2/auth?' + $query
    Write-Host "`nOpening Google Antigravity sign-in in your browser..." -ForegroundColor Cyan
    Write-Host 'If the browser does not open, copy this URL:' -ForegroundColor DarkGray
    Write-Host $authUrl -ForegroundColor Gray
    try { Start-Process $authUrl -ErrorAction Stop } catch { Write-Host '[Could not launch browser automatically; open the URL above.]' -ForegroundColor Yellow }
    Write-Host "`nAfter approval, paste the authorization code or the full callback URL." -ForegroundColor Yellow
    $inputCode = Read-Host 'Authorization code'
    if ([string]::IsNullOrWhiteSpace($inputCode)) { throw 'Authorization code was empty; sign-in cancelled.' }
    $code = $inputCode.Trim()
    if ($code -match '^https?://') {
        Add-Type -AssemblyName System.Web
        $callback = [uri]$code
        $queryValues = [System.Web.HttpUtility]::ParseQueryString($callback.Query)
        if ($queryValues['error']) { throw "Google authorization failed: $($queryValues['error'])" }
        if ($queryValues['state'] -and $queryValues['state'] -cne $state) { throw 'OAuth state validation failed. Restart .auth login.' }
        $code = [string]$queryValues['code']
    }
    if ([string]::IsNullOrWhiteSpace($code)) { throw 'The callback did not contain an authorization code.' }
    $form = @{ code = $code; client_id = $credentials.ClientId; client_secret = $credentials.ClientSecret; redirect_uri = 'https://antigravity.google/oauth-callback'; grant_type = 'authorization_code'; code_verifier = $verifier }
    $token = Invoke-AntigravityTokenRequest -Form $form
    if ([string]::IsNullOrWhiteSpace([string]$token.access_token) -or [string]::IsNullOrWhiteSpace([string]$token.refresh_token)) { throw 'Google did not return both access_token and refresh_token.' }
    $tokenData = @{
        auth_method = 'consumer'
        token = @{
            access_token = [string]$token.access_token
            token_type = if ($token.token_type) { [string]$token.token_type } else { 'Bearer' }
            refresh_token = [string]$token.refresh_token
            expiry = (Get-Date).ToUniversalTime().AddSeconds([int]$token.expires_in).ToString('o')
        }
    }
    Save-AntigravityToken -TokenData $tokenData
    $script:AntigravityProject = $null
    Write-Host "`n[Google Antigravity OAuth saved in your home directory.]" -ForegroundColor Green
}

function Get-AntigravityAccessToken {
    $path = Get-AntigravityTokenPath
    if (-not (Test-Path -LiteralPath $path)) { throw "Not signed in to Google Antigravity. Run .auth login. Token path: $path" }
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $data.token) { throw 'Antigravity token file has an invalid format.' }
    $token = $data.token
    $expiry = [DateTimeOffset]::MinValue
    if ($token.expiry) { [void][DateTimeOffset]::TryParse([string]$token.expiry, [ref]$expiry) }
    if (-not [string]::IsNullOrWhiteSpace([string]$token.access_token) -and $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { return [string]$token.access_token }
    if ([string]::IsNullOrWhiteSpace([string]$token.refresh_token)) { throw 'Antigravity access token expired and no refresh token is stored. Run .auth login.' }
    $credentials = Get-AntigravityClientCredentials
    $form = @{ refresh_token = [string]$token.refresh_token; client_id = $credentials.ClientId; client_secret = $credentials.ClientSecret; grant_type = 'refresh_token' }
    $refreshed = Invoke-AntigravityTokenRequest -Form $form
    if ([string]::IsNullOrWhiteSpace([string]$refreshed.access_token)) { throw 'Google OAuth refresh returned no access token.' }
    $token.access_token = [string]$refreshed.access_token
    if ($refreshed.refresh_token) { $token.refresh_token = [string]$refreshed.refresh_token }
    if ($refreshed.token_type) { $token.token_type = [string]$refreshed.token_type }
    $token.expiry = [DateTimeOffset]::UtcNow.AddSeconds([int]$refreshed.expires_in).ToString('o')
    Save-AntigravityToken -TokenData @{ auth_method = 'consumer'; token = $token }
    return [string]$token.access_token
}

function Invoke-AntigravityLogout {
    $path = Get-AntigravityTokenPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host '[Google Antigravity OAuth token removed.]' -ForegroundColor Green }
    else { Write-Host '[No saved Google Antigravity OAuth token.]' -ForegroundColor Yellow }
    $script:AntigravityProject = $null
}

function Get-AntigravityHeaders {
    param([string]$AccessToken)
    return @{
        Authorization = 'Bearer ' + $AccessToken
        'User-Agent' = 'antigravity/hub/2.17.0 (aidev_client; os_type=windows; arch=amd64; cl=986210228)'
        'X-Goog-Api-Client' = 'google-cloud-sdk vscode_cloudshelleditor/0.1'
        'Client-Metadata' = '{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}'
    }
}

function Invoke-AntigravityPost {
    param([string]$Method, [hashtable]$Body, [string]$AccessToken)
    $url = 'https://daily-cloudcode-pa.googleapis.com/v1internal:' + $Method
    $headers = Get-AntigravityHeaders -AccessToken $AccessToken
    return Invoke-RestMethod -Uri $url -Method Post -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 30) -ErrorAction Stop
}

function Get-AntigravityProject {
    if (-not [string]::IsNullOrWhiteSpace($script:AntigravityProject)) { return $script:AntigravityProject }
    $token = Get-AntigravityAccessToken
    $body = @{ metadata = @{ ideType = 'ANTIGRAVITY'; platform = 'PLATFORM_UNSPECIFIED'; pluginType = 'GEMINI' } }
    $loaded = Invoke-AntigravityPost -Method 'loadCodeAssist' -Body $body -AccessToken $token
    $project = [string]$loaded.cloudaicompanionProject
    if ([string]::IsNullOrWhiteSpace($project)) { throw 'Google loadCodeAssist did not return cloudaicompanionProject.' }
    $script:AntigravityProject = $project
    return $project
}

function Get-AntigravityModels {
    $token = Get-AntigravityAccessToken
    $project = Get-AntigravityProject
    $catalog = Invoke-AntigravityPost -Method 'fetchAvailableModels' -Body @{ project = $project } -AccessToken $token

    # Google returns a per-account Search model list for the dedicated research
    # backend used by Gemini API web_search. This list does not gate native Search
    # on the user's selected Antigravity chat model.
    $script:AntigravityCapabilityProbeAttempted = $true
    $script:AntigravityWebSearchModelIds = $null
    if ($catalog.PSObject.Properties['webSearchModelIds'] -and $null -ne $catalog.webSearchModelIds) {
        $script:AntigravityWebSearchModelIds = @(
            foreach ($searchModelId in @($catalog.webSearchModelIds)) {
                $normalizedId = ([string]$searchModelId).Trim() -replace '^models/',''
                if ($normalizedId) { $normalizedId }
            }
        )
    }

    $items = $null
    foreach ($key in @('models','modelInfos','availableModels','availableModelInfos')) {
        if ($catalog.PSObject.Properties[$key]) { $items = $catalog.$key; if ($null -ne $items) { break } }
    }
    if ($null -eq $items) { throw 'Antigravity model catalogue did not contain a recognized models collection.' }
    $result = New-Object System.Collections.Generic.List[object]
    if ($items -is [System.Array] -or $items -is [System.Collections.IList]) {
        foreach ($item in $items) {
            if ($item -is [string]) { $id = [string]$item; $display = $id }
            else {
                $id = ''; $display = ''
                foreach ($field in @('catalogId','catalogID','modelId','modelID','id','slug','model','name')) { if ($item.PSObject.Properties[$field] -and $item.$field) { $id = [string]$item.$field; break } }
                foreach ($field in @('displayName','display_name','label','title')) { if ($item.PSObject.Properties[$field] -and $item.$field) { $display = [string]$item.$field; break } }
                if (-not $display) { $display = $id }
            }
            if ($id) { [void]$result.Add([pscustomobject]@{ name = ($id -replace '^models/',''); displayName = $display }) }
        }
    } else {
        foreach ($property in $items.PSObject.Properties) {
            $id = [string]$property.Name; $display = $id
            if ($property.Value -and $property.Value.PSObject.Properties['displayName']) { $display = [string]$property.Value.displayName }
            [void]$result.Add([pscustomobject]@{ name = ($id -replace '^models/',''); displayName = $display })
        }
    }
    if ($result.Count -eq 0) { throw 'Antigravity returned no selectable models.' }
    return @($result | Sort-Object name)
}

function Invoke-GemmaAuthCommand {
    param([string]$Argument = '')
    $action = $Argument.Trim().ToLowerInvariant()
    if ($action -eq 'login') {
        try { Invoke-AntigravityLogin } catch { Write-Host "`n[OAuth login failed]: $($_.Exception.Message)" -ForegroundColor Red }
        return
    }
    if ($action -eq 'logout') {
        try { Invoke-AntigravityLogout } catch { Write-Host "`n[OAuth logout failed]: $($_.Exception.Message)" -ForegroundColor Red }
        return
    }
    if ($action -eq 'status' -or [string]::IsNullOrWhiteSpace($action)) {
        $path = Get-AntigravityTokenPath
        if (Test-Path -LiteralPath $path) {
            try {
                $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $email = if ($data.email) { [string]$data.email } else { '(account email not recorded)' }
                Write-Host "`nGoogle Antigravity: signed in ($email)" -ForegroundColor Green
                Write-Host "Token file: $path" -ForegroundColor DarkGray
            } catch { Write-Host '[Saved token file exists but could not be read.]' -ForegroundColor Red }
        } else {
            Write-Host "`nGoogle Antigravity: not signed in" -ForegroundColor Yellow
            Write-Host 'Run .auth login to connect.' -ForegroundColor DarkGray
        }
        return
    }
    Write-Host 'Usage: .auth login | .auth status | .auth logout' -ForegroundColor Yellow
}

function Get-GemmaSearchModelCandidates {
    param([string]$PreferredModel = $MIRA_SEARCH_MODEL)

    # Discover Search-capable models for the separate research agent used by
    # Gemini API web_search. This is not used to filter Antigravity chat models.
    if (-not $script:AntigravityCapabilityProbeAttempted) {
        try { [void](Get-AntigravityModels) } catch { }
    }

    $preferred = ([string]$PreferredModel).Trim() -replace '^models/',''
    $ids = New-Object System.Collections.Generic.List[string]
    if ($script:AntigravityCapabilityProbeAttempted -and $null -ne $script:AntigravityWebSearchModelIds) {
        $available = @($script:AntigravityWebSearchModelIds)
        if ($preferred -and $available -contains $preferred) { [void]$ids.Add($preferred) }
        foreach ($id in $available) {
            if ($id -and -not $ids.Contains([string]$id)) { [void]$ids.Add([string]$id) }
        }
    } elseif ($preferred) {
        # Compatibility fallback only when this account's endpoint omits the
        # capability field; do not invent additional Search-capable models.
        [void]$ids.Add($preferred)
    }
    return @($ids)
}

function Invoke-GemmaAntigravitySearchRequest {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$Model = $MIRA_SEARCH_MODEL
    )
    $models = @(Get-GemmaSearchModelCandidates -PreferredModel $Model)
    if ($models.Count -eq 0) { throw 'Google did not advertise any Search-capable Antigravity models for this account.' }

    $lastError = $null
    foreach ($candidateModel in $models) {
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $response = Invoke-GemmaAntigravityRequest -Payload $Payload -Model $candidateModel
                return @{ result = $response; model = [string]$candidateModel }
            } catch {
                $lastError = $_.Exception.Message
                $transient = $lastError -match '(?i)(429|500|502|503|504|RESOURCE_EXHAUSTED|MODEL_CAPACITY_EXHAUSTED|temporarily unavailable)'
                if (-not $transient -or $attempt -ge 2) { break }
                $delay = [int][Math]::Min(12,2 * [Math]::Pow(2,$attempt))
                Start-Sleep -Seconds $delay
            }
        }
    }
    throw "Google Search failed on all configured or account-advertised candidate models. Last error: $lastError"
}

function Invoke-GemmaSearchCommand {
    param([string]$Argument = '')
    $value = $Argument.Trim().ToLowerInvariant()
    if ($value -eq 'on') {
        $script:GoogleSearchGrounding = $true
        Write-Host '[Grounding ON]' -ForegroundColor Green
    } elseif ($value -eq 'off') {
        $script:GoogleSearchGrounding = $false
        Write-Host '[Grounding OFF]' -ForegroundColor Yellow
    } elseif ($value -eq 'status' -or -not $value) {
        $state = if ($script:GoogleSearchGrounding) { 'ON' } else { 'OFF' }
        Write-Host "[Grounding: $state]" -ForegroundColor Cyan
    } else {
        Write-Host 'Usage: .grounding on | .grounding off | .grounding status' -ForegroundColor Yellow
    }
}

function Invoke-GemmaAntigravityRequest {
    param([System.Collections.IDictionary]$Payload, [string]$Model = $script:MODEL)
    $token = Get-AntigravityAccessToken
    $project = Get-AntigravityProject
    $Payload.systemInstruction.role = 'user'
    if ($Payload.Contains('safetySettings')) { [void]$Payload.Remove('safetySettings') }
    $requestId = 'agent-' + [guid]::NewGuid().ToString('N')
    $envelope = @{ project = $project; requestId = $requestId; request = $Payload; model = $Model; userAgent = 'antigravity'; requestType = 'agent' }
    return Invoke-AntigravityPost -Method 'generateContent' -Body $envelope -AccessToken $token
}


function Test-GemmaSearchIntent {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $request = $Text.Trim()

    # Questions ABOUT the previous Search operation are conversation, not
    # requests to search again. Likewise, explicit instructions not to search.
    if ($request -match '(?i)^\s*(?:why|what|how)\b.{0,120}\b(?:search(?:ing|ed)?|google\s+search|grounding)\b') {
        return $false
    }
    if ($request -match '(?i)\b(?:do\s+not|don''t|dont|stop|without|avoid|no\s+need\s+to)\b.{0,40}\b(?:search|browse|google)\b') {
        return $false
    }

    # The host exposes a dedicated local date/time tool. Do not Search for
    # the computer's current date/time when that tool can answer directly.
    if ($request -match '(?i)\b(?:what(?:''s|\s+is)\s+(?:the\s+)?(?:current\s+|local\s+)?(?:date|time)|current\s+(?:local\s+)?(?:date|time)|today''s\s+date|what\s+day\s+is\s+it|local\s+time)\b' -and
        $request -notmatch '(?i)\b(?:in|for)\s+[A-Z][a-z]+\b') {
        return $false
    }

    # Weather has a dedicated quick_web tool; do not spend the native Search
    # preflight on ordinary weather requests.
    $explicitSearch = $request -match '(?i)\b(?:search(?:\s+for)?|google(?:\s+search)?|browse(?:\s+the\s+web)?|look\s+up|research|fact[- ]?check)\b'
    if ($request -match '(?i)\bweather\b' -and -not $explicitSearch) { return $false }
    if ($explicitSearch) { return $true }

    # Freshness/current-events requests need native Google Search. Short
    # conversational replies ("ok", "what?", "ll", etc.) do not.
    $freshness = $request -match '(?i)\b(?:latest|current|currently|recent|recently|newest|breaking|live|right\s+now|today|tonight|this\s+(?:morning|afternoon|evening|week|month|year)|last\s+(?:(?:\d+|few|several)\s+)?(?:minutes?|hours?|days?|weeks?)|past\s+\d+\s+(?:minutes?|hours?|days?|weeks?)|up[- ]to[- ]date|as\s+of\s+now)\b'
    if ($freshness -and $request -match '(?i)\b(?:what|who|when|where|how|show|get|give|list|tell|find|check|verify|compare|update|updates|status|price|version|rate|news|headline|headlines|happening)\b') {
        return $true
    }

    # A request for news/headlines implies current reporting unless it clearly
    # asks a general or historical question.
    if ($request -match '(?i)\b(?:news|headlines|breaking\s+news)\b' -and
        $request -match '(?i)\b(?:show|get|give|list|tell|find|check|latest|today|recent|current|updates?)\b') {
        return $true
    }

    return $false
}

function Invoke-GemmaAntigravityGoogleSearchPreflight {
    if (-not $script:GoogleSearchGrounding) {
        throw 'This request needs Google Search, but grounding is OFF. Enable it with .grounding on or rephrase as a normal chat request.'
    }
    if ($script:CommandMode) { return }
    if (-not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) {
        throw 'This request needs Google Search, but Antigravity OAuth is not available. Run .auth login.'
    }

    # Search only the current user request. Include earlier user prompts solely
    # when the current request explicitly refers back to prior context. Never
    # feed assistant-generated news summaries back as Search instructions.
    if ($Contents.Count -eq 0) {
        throw 'Google Search could not find the current user request.'
    }
    $currentUserTurn = $Contents[$Contents.Count - 1]
    if ($null -eq $currentUserTurn -or $currentUserTurn.role -ne 'user') {
        throw 'Google Search could not identify the current user request.'
    }
    $currentTextParts = @(
        @($currentUserTurn.parts) |
            Where-Object { $null -ne $_.text -and -not $_.thought } |
            ForEach-Object { ([string]$_.text).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($currentTextParts.Count -eq 0) {
        throw 'Google Search could not find text in the current user request.'
    }
    $searchContext = [string]::Join([Environment]::NewLine, $currentTextParts)
    if ($searchContext -match '(?i)\b(?:that|those|these|it|there|same|previous|above|earlier)\b') {
        $priorUserRequests = New-Object System.Collections.Generic.List[string]
        for ($i = $Contents.Count - 2; $i -ge 0 -and $priorUserRequests.Count -lt 3; $i--) {
            $entry = $Contents[$i]
            if ($null -eq $entry -or $entry.role -ne 'user') { continue }
            $priorParts = @(
                @($entry.parts) |
                    Where-Object { $null -ne $_.text -and -not $_.thought } |
                    ForEach-Object { ([string]$_.text).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            if ($priorParts.Count -gt 0) {
                $priorUserRequests.Insert(0,[string]::Join([Environment]::NewLine,$priorParts))
            }
        }
        if ($priorUserRequests.Count -gt 0) {
            $searchContext = 'Earlier user requests for reference only:' + [Environment]::NewLine +
                [string]::Join(([Environment]::NewLine + [Environment]::NewLine),$priorUserRequests) +
                [Environment]::NewLine + [Environment]::NewLine +
                'Current request (the only request to research):' + [Environment]::NewLine + $searchContext
        }
    }
    if ($searchContext.Length -gt 16000) {
        $searchContext = $searchContext.Substring($searchContext.Length - 16000)
    }

    # This is an isolated native Google Search request using the SAME selected
    # Antigravity model. It is not mixed with the local functionDeclarations.
    $searchInstruction = 'You are the Google Search phase for an explicit web/current-information request. Research ONLY the current user request. Use earlier user requests solely to resolve explicit references; never re-search an earlier topic merely because it appears in conversation history. Do not answer from memory. Verify dates and return a concise factual research brief with source-specific details. Do not invent sources. If Google Search cannot be used or produces no grounded results, return no fabricated substitute.'
    $searchPayload = @{
        systemInstruction = @{
            role = 'user'
            parts = @(@{ text = $searchInstruction })
        }
        contents = @(@{
            role = 'user'
            parts = @(@{ text = $searchContext })
        })
        tools = @(@{ googleSearch = @{} })
        toolConfig = @{ includeServerSideToolInvocations = $true }
    }

    $searchResponse = $null
    $lastFailure = ''
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            # Retry only the identical request on the identical model after a
            # transient service error. Never switch models or skip Search.
            $searchResponse = Invoke-GemmaAntigravityRequest -Payload $searchPayload -Model $script:MODEL
            $lastFailure = ''
            break
        } catch {
            $lastFailure = $_.Exception.Message
            $status = 0
            $body = ''
            try {
                $webResponse = $_.Exception.Response
                if ($null -ne $webResponse) {
                    $status = [int]$webResponse.StatusCode
                    $stream = $webResponse.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                        $reader.Dispose()
                        $stream.Dispose()
                    }
                }
            } catch {}
            if ($body) { $lastFailure += ' | Google response: ' + $body }

            $transient = $status -in @(408,429,500,502,503,504)
            if (-not $transient -or $attempt -ge 2) {
                if ($status -gt 0) {
                    throw "Mandatory Google Search failed for selected Antigravity model '$script:MODEL' (HTTP $status). No ungrounded answer was generated. $lastFailure"
                }
                throw "Mandatory Google Search failed for selected Antigravity model '$script:MODEL'. No ungrounded answer was generated. $lastFailure"
            }
            $delay = [int][Math]::Min(8,2 * [Math]::Pow(2,$attempt))
            Start-Sleep -Seconds $delay
        }
    }

    if ($null -eq $searchResponse -or $null -eq $searchResponse.response) {
        throw "Mandatory Google Search returned no response from selected model '$script:MODEL'. No ungrounded answer was generated. $lastFailure"
    }
    $result = $searchResponse.response
    if ($null -eq $result.candidates -or $result.candidates.Count -eq 0) {
        throw "Mandatory Google Search returned no candidates from selected model '$script:MODEL'. No ungrounded answer was generated."
    }

    $candidate = $result.candidates[0]
    $metadata = $candidate.groundingMetadata
    if ($null -eq $metadata -or (
        @($metadata.webSearchQueries).Count -eq 0 -and
        @($metadata.groundingChunks).Count -eq 0
    )) {
        throw "Selected Antigravity model '$script:MODEL' did not return Google Search grounding metadata. No ungrounded answer was generated."
    }

    $researchParts = @(
        @($candidate.content.parts) |
            Where-Object { $_.text -and -not $_.thought } |
            ForEach-Object { ([string]$_.text).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $queryLines = @(
        @($metadata.webSearchQueries) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { '- ' + [string]$_ }
    )
    $sourceLines = New-Object System.Collections.Generic.List[string]
    $seenSources = @{}
    foreach ($chunk in @($metadata.groundingChunks)) {
        if ($chunk.web -and $chunk.web.uri) {
            $uri = [string]$chunk.web.uri
            if (-not $seenSources.ContainsKey($uri)) {
                $seenSources[$uri] = $true
                $title = if ($chunk.web.title) { [string]$chunk.web.title } else { $uri }
                [void]$sourceLines.Add(('- ' + $title + ' — ' + $uri))
            }
        }
    }

    $researchText = [string]::Join(([Environment]::NewLine + [Environment]::NewLine), $researchParts)
    if ($queryLines.Count -gt 0) {
        if ($researchText) { $researchText += [Environment]::NewLine + [Environment]::NewLine }
        $researchText += 'Google Search queries:' + [Environment]::NewLine + [string]::Join([Environment]::NewLine, $queryLines)
    }
    if ($sourceLines.Count -gt 0) {
        if ($researchText) { $researchText += [Environment]::NewLine + [Environment]::NewLine }
        $researchText += 'Google Search sources:' + [Environment]::NewLine + [string]::Join([Environment]::NewLine, @($sourceLines))
    }
    if ([string]::IsNullOrWhiteSpace($researchText)) {
        throw "Selected Antigravity model '$script:MODEL' returned grounding metadata but no readable research. No ungrounded answer was generated."
    }
    if ($researchText.Length -gt $MIRA_MAX_SEARCH_OUTPUT_CHARS) {
        $researchText = $researchText.Substring(0,$MIRA_MAX_SEARCH_OUTPUT_CHARS) + [Environment]::NewLine + '[Grounded Search context truncated]'
    }

    # Add verified Search material to the current user message. The answer
    # request consumes grounded context and does not receive googleSearch.
    $currentUserTurn = $Contents[$Contents.Count - 1]
    if ($null -eq $currentUserTurn -or $currentUserTurn.role -ne 'user') {
        throw 'Mandatory Google Search could not attach results to the current user turn.'
    }
    $currentUserTurn.parts = @($currentUserTurn.parts) + @(@{
        text = "Mandatory Google Search results from selected Antigravity model '$script:MODEL'. Use these grounded results as the factual basis of your answer. Preserve dates and uncertainty, cite supplied source URLs, and do not claim additional searches." + [Environment]::NewLine + [Environment]::NewLine + $researchText
    })

}


function Invoke-GemmaWebSearch {
    param([string]$Query)
    if (-not (Test-Path -LiteralPath (Get-AntigravityTokenPath))) { throw 'Web search requires Antigravity OAuth. Run .auth login.' }
    if ([string]::IsNullOrWhiteSpace($Query)) { throw 'web_search requires a non-empty query.' }

    # This research agent is invoked only by Gemini Developer API models. It uses
    # the configured Gemini 3.1 Flash Lite Search model through Antigravity OAuth.
    $searchModel = $MIRA_SEARCH_MODEL
    $payload = @{
        systemInstruction = @{ role = 'user'; parts = @(@{ text = 'You are a web research tool. Use Google Search to investigate the supplied query. Return a concise factual research brief, preserve uncertainty and dates, and include source-specific details. Do not invent sources or claim to have searched unless grounding metadata is returned.' }) }
        contents = @(@{ role = 'user'; parts = @(@{ text = "Search the web for this exact request. Return a concise factual research brief grounded in the search results. Request: $Query" }) })
        tools = @(@{ googleSearch = @{} })
        toolConfig = @{ includeServerSideToolInvocations = $true }
    }
    $searchCall = Invoke-GemmaAntigravitySearchRequest -Payload $payload -Model $searchModel
    $result = $searchCall.result
    $searchModel = [string]$searchCall.model
    if ($null -eq $result.response -or $null -eq $result.response.candidates -or $result.response.candidates.Count -eq 0) { throw "Google Search returned no candidates from model '$searchModel'." }
    $candidate = $result.response.candidates[0]
    $metadata = $candidate.groundingMetadata
    if ($null -eq $metadata -or (@($metadata.webSearchQueries).Count -eq 0 -and @($metadata.groundingChunks).Count -eq 0)) {
        throw "Model '$searchModel' returned no Google Search grounding metadata. No ungrounded text will be presented as search results."
    }

    $parts = @($candidate.content.parts | Where-Object { $_.text -and -not $_.thought } | ForEach-Object { [string]$_.text.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $sources = New-Object System.Collections.Generic.List[string]
    $sourceUris = @{}
    foreach ($chunk in @($metadata.groundingChunks)) {
        if ($chunk.web -and $chunk.web.uri) {
            $uri = [string]$chunk.web.uri
            if (-not $sourceUris.ContainsKey($uri)) {
                $sourceUris[$uri] = $true
                $title = if ($chunk.web.title) { [string]$chunk.web.title } else { $uri }
                [void]$sources.Add(('- ' + $title + ' — ' + $uri))
            }
        }
    }
    $queries = @($metadata.webSearchQueries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { '- ' + [string]$_ })
    $research = [string]::Join("`n`n",$parts)
    if ($queries.Count -gt 0) { if ($research) { $research += "`n`n" }; $research += "Google Search queries:`n" + [string]::Join("`n",$queries) }
    if ($sources.Count -gt 0) { if ($research) { $research += "`n`n" }; $research += "Google Search sources:`n" + [string]::Join("`n",$sources) }
    if ([string]::IsNullOrWhiteSpace($research)) { throw "Model '$searchModel' returned grounding metadata but no readable research or sources." }
    if ($research.Length -gt $MIRA_MAX_SEARCH_OUTPUT_CHARS) { $research = $research.Substring(0,$MIRA_MAX_SEARCH_OUTPUT_CHARS) + "`n[Search results truncated]" }
    return @{ query=$Query; research=$research; sources=@($sources); search_queries=@($metadata.webSearchQueries); search_model=$searchModel }
}
