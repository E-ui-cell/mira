# Unified model picker. Provider identity is carried by each catalogue entry.

function Add-GemmaModelCatalogEntry {
    param(
        [System.Collections.Generic.List[object]]$List,
        [hashtable]$Seen,
        [string]$Provider,
        [object]$Item
    )

    $id = ''
    $displayName = ''
    if ($Item -is [string]) {
        $id = [string]$Item
        $displayName = $id
    } elseif ($null -ne $Item) {
        if ($null -ne $Item.name) { $id = [string]$Item.name }
        if ($null -ne $Item.displayName) { $displayName = [string]$Item.displayName }
        if ([string]::IsNullOrWhiteSpace($id) -and $null -ne $Item.modelId) { $id = [string]$Item.modelId }
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $id }
    }

    $id = ($id.Trim() -replace '^models/','')
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    $seenKey = $Provider + '|' + $id.ToLowerInvariant()
    if ($Seen.ContainsKey($seenKey)) { return }
    $Seen[$seenKey] = $true

    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $id }
    [void]$List.Add([pscustomobject]@{
        name = $id
        displayName = $displayName
        provider = $Provider
    })
}

function Get-GemmaModelCatalog {
    $models = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $statuses = @{}

    # OpenAI is intentionally pinned to Luna for this application.
    $openAIModel = [string]$MIRA_OPENAI_DEFAULT_MODEL
    $openAIKeys = @(Get-GemmaOpenAIApiKeys)
    if (-not [string]::IsNullOrWhiteSpace($openAIModel) -and $openAIKeys.Count -gt 0) {
        Add-GemmaModelCatalogEntry -List $models -Seen $seen -Provider 'openai' -Item ([pscustomobject]@{
            name = $openAIModel
            displayName = 'GPT-6 Luna'
        })
    } elseif ($openAIKeys.Count -eq 0) {
        $statuses['openai'] = 'No OpenAI API key configured'
    } else {
        $statuses['openai'] = 'No OpenAI model configured'
    }

    # Antigravity OAuth has its own catalogue and must not be conflated with
    # the Gemini Developer API catalogue.
    $antigravityTokenPath = Get-AntigravityTokenPath
    if (Test-Path -LiteralPath $antigravityTokenPath -PathType Leaf) {
        try {
            $antigravityModels = @(Get-AntigravityModels)
            foreach ($item in $antigravityModels) {
                Add-GemmaModelCatalogEntry -List $models -Seen $seen -Provider 'antigravity' -Item $item
            }
            if ($antigravityModels.Count -eq 0) {
                $statuses['antigravity'] = 'No selectable models returned'
            }
        } catch {
            $statuses['antigravity'] = 'Unavailable: ' + [string]$_.Exception.Message
        }
    } else {
        $statuses['antigravity'] = 'Not authenticated; run .auth login'
    }

    # Get-GeminiModels dispatches to Antigravity when that provider is active.
    # Temporarily select the Gemini API route only while fetching its catalogue.
    $geminiKeys = @(Get-GeminiApiKeys)
    if ($geminiKeys.Count -gt 0) {
        $originalProvider = [string]$script:Provider
        try {
            $script:Provider = 'gemini'
            $geminiModels = @(Get-GeminiModels)
            foreach ($item in $geminiModels) {
                Add-GemmaModelCatalogEntry -List $models -Seen $seen -Provider 'gemini' -Item $item
            }
            if ($geminiModels.Count -eq 0) {
                $statuses['gemini'] = 'No selectable models returned'
            }
        } catch {
            $statuses['gemini'] = 'Unavailable: ' + [string]$_.Exception.Message
        } finally {
            $script:Provider = $originalProvider
        }
    } else {
        $statuses['gemini'] = 'No Gemini API key configured'
    }

    return [pscustomobject]@{
        Models = @($models.ToArray())
        ProviderStatuses = $statuses
    }
}

function Read-GemmaModelSelection {
    param(
        [object[]]$Models,
        [string]$CurrentModel,
        [string]$CurrentProvider,
        [hashtable]$ProviderStatuses = @{}
    )

    $modelList = @($Models)
    $providerDefinitions = @(
        [pscustomobject]@{ Id = 'openai'; Label = 'OpenAI' },
        [pscustomobject]@{ Id = 'antigravity'; Label = 'Antigravity' },
        [pscustomobject]@{ Id = 'gemini'; Label = 'Google AI Studio API' }
    )

    $displayRows = New-Object 'System.Collections.Generic.List[object]'
    $modelRowIndices = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $modelList.Count; $i++) { [void]$modelRowIndices.Add(-1) }

    foreach ($provider in $providerDefinitions) {
        [void]$displayRows.Add([pscustomobject]@{
            Kind = 'header'
            Provider = $provider.Id
            Text = $provider.Label
            ModelIndex = -1
        })

        $providerModelIndices = @(
            for ($i = 0; $i -lt $modelList.Count; $i++) {
                if ([string]$modelList[$i].provider -eq $provider.Id) { $i }
            }
        )

        if ($providerModelIndices.Count -eq 0) {
            $status = ''
            if ($null -ne $ProviderStatuses -and $ProviderStatuses.ContainsKey($provider.Id)) {
                $status = [string]$ProviderStatuses[$provider.Id]
            }
            if ([string]::IsNullOrWhiteSpace($status)) { $status = 'No selectable models' }
            [void]$displayRows.Add([pscustomobject]@{
                Kind = 'status'
                Provider = $provider.Id
                Text = $status
                ModelIndex = -1
            })
        } else {
            foreach ($modelIndex in $providerModelIndices) {
                $modelRowIndices[$modelIndex] = $displayRows.Count
                [void]$displayRows.Add([pscustomobject]@{
                    Kind = 'model'
                    Provider = $provider.Id
                    Text = [string]$modelList[$modelIndex].name
                    ModelIndex = [int]$modelIndex
                })
            }
        }
    }

    if ($modelList.Count -eq 0) {
        Write-Host 'No selectable models are currently available.' -ForegroundColor Yellow
        foreach ($row in $displayRows) {
            if ($row.Kind -eq 'header') {
                Write-Host $row.Text -ForegroundColor Cyan
            } else {
                Write-Host ('    ' + $row.Text) -ForegroundColor DarkGray
            }
        }
        return -1
    }

    $selectedIndex = 0
    for ($i = 0; $i -lt $modelList.Count; $i++) {
        if ([string]$modelList[$i].provider -eq $CurrentProvider -and
            [string]$modelList[$i].name -ieq $CurrentModel) {
            $selectedIndex = $i
            break
        }
    }
    $selectedDisplayIndex = $modelRowIndices[$selectedIndex]

    $interactive = $false
    try {
        $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    } catch {}
    if (-not $interactive) {
        $number = 0
        foreach ($provider in $providerDefinitions) {
            Write-Host $provider.Label -ForegroundColor Cyan
            $providerModelIndices = @(
                for ($i = 0; $i -lt $modelList.Count; $i++) {
                    if ([string]$modelList[$i].provider -eq $provider.Id) { $i }
                }
            )
            if ($providerModelIndices.Count -eq 0) {
                $status = if ($ProviderStatuses.ContainsKey($provider.Id)) { [string]$ProviderStatuses[$provider.Id] } else { 'No selectable models' }
                Write-Host ('    ' + $status) -ForegroundColor DarkGray
            } else {
                foreach ($modelIndex in $providerModelIndices) {
                    $number++
                    $marker = if ($modelIndex -eq $selectedIndex) { '  [CURRENT]' } else { '' }
                    Write-Host ('    {0,3}. {1}{2}' -f $number,$modelList[$modelIndex].name,$marker)
                }
            }
        }

        $selection = Read-Host 'Select model number or exact model ID; Enter cancels'
        if ([string]::IsNullOrWhiteSpace($selection)) { return -1 }
        $selection = $selection.Trim() -replace '^models/',''
        if ($selection -match '^\d+$') {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $modelList.Count) { return $index }
            return -1
        }

        $matchingIndices = @(
            for ($i = 0; $i -lt $modelList.Count; $i++) {
                if ([string]$modelList[$i].name -ieq $selection) { $i }
            }
        )
        if ($matchingIndices.Count -eq 1) { return [int]$matchingIndices[0] }
        if ($matchingIndices.Count -gt 1) {
            foreach ($index in $matchingIndices) {
                if ([string]$modelList[$index].provider -eq $CurrentProvider) { return [int]$index }
            }
        }
        return -1
    }

    $windowHeight = [Math]::Max(10,[Console]::WindowHeight)
    $visibleRows = [Math]::Max(1,[Math]::Min(12,$windowHeight - 6))
    $visibleRows = [Math]::Min($visibleRows,$displayRows.Count)
    $menuHeight = $visibleRows + 3
    $windowTop = [Console]::WindowTop
    $top = [Console]::CursorTop
    $viewportBottom = $windowTop + $windowHeight
    $spaceBelow = $viewportBottom - $top
    if ($spaceBelow -lt ($menuHeight + 1)) {
        $paddingRows = ($menuHeight + 1) - $spaceBelow
        [Console]::Write(([Environment]::NewLine * $paddingRows))
        $top = [Console]::CursorTop
    }

    $oldForeground = [Console]::ForegroundColor
    $oldBackground = [Console]::BackgroundColor
    $cancelled = $false
    $confirmed = $false

    function Draw-GemmaModelMenu {
        $first = [Math]::Max(0,[Math]::Min(
            $selectedDisplayIndex - [int][Math]::Floor($visibleRows / 2),
            $displayRows.Count - $visibleRows
        ))

        # Keep the selected provider heading visible when it fits in the viewport.
        if ($displayRows[$first].Kind -eq 'model') {
            $providerId = [string]$displayRows[$first].Provider
            $headerIndex = $first
            while ($headerIndex -gt 0) {
                $previousRow = $displayRows[$headerIndex - 1]
                if ($previousRow.Kind -eq 'header') {
                    if ([string]$previousRow.Provider -eq $providerId) { $headerIndex-- }
                    break
                }
                if ([string]$previousRow.Provider -ne $providerId) { break }
                $headerIndex--
            }
            if (($selectedDisplayIndex - $headerIndex) -lt $visibleRows) { $first = $headerIndex }
        }

        $last = $first + $visibleRows
        $clearWidth = [Math]::Max(1,[Console]::WindowWidth - 1)
        [Console]::SetCursorPosition(0,$top)

        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        $title = 'Select model'
        [Console]::Write($title.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write(('Up/Down or j/k move; Enter select; Esc or q cancel').PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::WriteLine()

        for ($rowIndex = $first; $rowIndex -lt $last; $rowIndex++) {
            $row = $displayRows[$rowIndex]
            $line = ''
            $isSelected = $false

            if ($row.Kind -eq 'header') {
                $line = [string]$row.Text
                [Console]::ForegroundColor = [ConsoleColor]::Cyan
                [Console]::BackgroundColor = $oldBackground
            } elseif ($row.Kind -eq 'status') {
                $line = '    ' + [string]$row.Text
                [Console]::ForegroundColor = [ConsoleColor]::DarkGray
                [Console]::BackgroundColor = $oldBackground
            } else {
                $model = $modelList[$row.ModelIndex]
                $marker = if ($row.ModelIndex -eq $selectedIndex) { '>' } else { ' ' }
                $current = if ([string]$model.provider -eq $CurrentProvider -and [string]$model.name -ieq $CurrentModel) { '  [current]' } else { '' }
                $line = ('    {0} {1}{2}' -f $marker,$model.name,$current)
                $isSelected = ($row.ModelIndex -eq $selectedIndex)
                if ($isSelected) {
                    [Console]::ForegroundColor = [ConsoleColor]::White
                    [Console]::BackgroundColor = [ConsoleColor]::DarkCyan
                } else {
                    [Console]::ForegroundColor = [ConsoleColor]::Gray
                    [Console]::BackgroundColor = $oldBackground
                }
            }

            if ($line.Length -gt $clearWidth) { $line = $line.Substring(0,$clearWidth) }
            [Console]::Write($line.PadRight($clearWidth).Substring(0,$clearWidth))
            [Console]::WriteLine()
        }

        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        $footer = (' {0}/{1} models ' -f ($selectedIndex + 1),$modelList.Count)
        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
        [Console]::Write($footer.PadRight($clearWidth).Substring(0,$clearWidth))
        [Console]::SetCursorPosition(0,[Math]::Min($top + $menuHeight,[Console]::BufferHeight - 1))
    }

    try {
        Draw-GemmaModelMenu
        while (-not $confirmed -and -not $cancelled) {
            $key = [Console]::ReadKey($true)
            $character = [char]::ToLowerInvariant($key.KeyChar)

            if ($key.Key -eq [ConsoleKey]::UpArrow -or $character -eq 'k') {
                $selectedIndex = [Math]::Max(0,$selectedIndex - 1)
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::DownArrow -or $character -eq 'j') {
                $selectedIndex = [Math]::Min($modelList.Count - 1,$selectedIndex + 1)
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::Home) {
                $selectedIndex = 0
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::End) {
                $selectedIndex = $modelList.Count - 1
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::PageUp) {
                $selectedIndex = [Math]::Max(0,$selectedIndex - $visibleRows)
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::PageDown) {
                $selectedIndex = [Math]::Min($modelList.Count - 1,$selectedIndex + $visibleRows)
                $selectedDisplayIndex = $modelRowIndices[$selectedIndex]
                Draw-GemmaModelMenu
            } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                $confirmed = $true
            } elseif ($key.Key -eq [ConsoleKey]::Escape -or $character -eq 'q') {
                $cancelled = $true
            }
        }
    } finally {
        [Console]::ForegroundColor = $oldForeground
        [Console]::BackgroundColor = $oldBackground
        try {
            [Console]::SetCursorPosition(0,[Math]::Min($top + $menuHeight,[Console]::BufferHeight - 1))
        } catch {}
        [Console]::WriteLine()
    }

    if ($cancelled) { return -1 }
    return $selectedIndex
}

function Set-GemmaActiveModel {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('openai','antigravity','gemini')][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Model
    )

    if ($Provider -eq 'openai' -and @(Get-GemmaOpenAIApiKeys).Count -eq 0) {
        Write-Host '[OpenAI API key is not configured. Add a key to the explicit OpenAI key list in Defaults.ps1.]' -ForegroundColor Yellow
        return $false
    }
    if ($Provider -eq 'antigravity' -and -not (Test-Path -LiteralPath (Get-AntigravityTokenPath) -PathType Leaf)) {
        Write-Host '[Antigravity is not authenticated. Run .auth login first.]' -ForegroundColor Yellow
        return $false
    }
    if ($Provider -eq 'gemini' -and @(Get-GeminiApiKeys).Count -eq 0) {
        Write-Host '[Google AI Studio API key is not configured. Add a key to the explicit Gemini key list in Defaults.ps1.]' -ForegroundColor Yellow
        return $false
    }

    $script:Provider = $Provider
    $script:MODEL = $Model
    if ($Provider -ne 'openai') { $script:GemmaLastGeminiProvider = $Provider }

    $providerLabel = switch ($Provider) {
        'openai' { 'OpenAI' }
        'antigravity' { 'Antigravity' }
        'gemini' { 'Google AI Studio API' }
    }
    Write-Host (([Environment]::NewLine) + '[Provider: ' + $providerLabel + ' | Model: ' + $script:MODEL + ']') -ForegroundColor Green
    $effectiveEffort = Get-GemmaRequestEffort -Provider $Provider
    Write-Host "[Reasoning effort: $effectiveEffort (provider override or shared .effort setting).]" -ForegroundColor DarkGray
    return $true
}

function Invoke-GemmaModelPicker {
    param([string]$RequestedModel = '')

    $requested = ([string]$RequestedModel).Trim()
    $explicitProvider = $null
    $requestedId = $requested

    if (-not [string]::IsNullOrWhiteSpace($requested)) {
        $providerMatch = [regex]::Match(
            $requested,
            '^(openai|antigravity|gemini|google-ai-studio|googleai|aistudio)[:/](.+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($providerMatch.Success) {
            $providerName = $providerMatch.Groups[1].Value.ToLowerInvariant()
            $requestedId = $providerMatch.Groups[2].Value.Trim()
            switch ($providerName) {
                'openai' { $explicitProvider = 'openai' }
                'antigravity' { $explicitProvider = 'antigravity' }
                { $_ -in @('gemini','google-ai-studio','googleai','aistudio') } { $explicitProvider = 'gemini' }
            }
        }
        $requestedId = $requestedId -replace '^models/',''

        if (($null -eq $explicitProvider -or $explicitProvider -eq 'openai') -and
            $requestedId -ieq [string]$MIRA_OPENAI_DEFAULT_MODEL) {
            [void](Set-GemmaActiveModel -Provider 'openai' -Model ([string]$MIRA_OPENAI_DEFAULT_MODEL))
            return
        }
    } else {
        $catalog = Get-GemmaModelCatalog
        $selectedIndex = Read-GemmaModelSelection -Models @($catalog.Models) -CurrentModel ([string]$script:MODEL) -CurrentProvider ([string]$script:Provider) -ProviderStatuses $catalog.ProviderStatuses
        if ($selectedIndex -lt 0 -or $selectedIndex -ge @($catalog.Models).Count) { return }
        $selected = @($catalog.Models)[$selectedIndex]
        [void](Set-GemmaActiveModel -Provider ([string]$selected.provider) -Model ([string]$selected.name))
        return
    }

    $catalog = Get-GemmaModelCatalog
    $matchingModels = @(
        $catalog.Models | Where-Object {
            [string]$_.name -ieq $requestedId -and
            ($null -eq $explicitProvider -or [string]$_.provider -eq $explicitProvider)
        }
    )

    if ($matchingModels.Count -eq 0) {
        if ($null -ne $explicitProvider) {
            if ($catalog.ProviderStatuses.ContainsKey($explicitProvider)) {
                Write-Host ('[' + [string]$catalog.ProviderStatuses[$explicitProvider] + ']') -ForegroundColor Yellow
                return
            }
            if ($explicitProvider -eq 'openai') {
                Write-Host ('[OpenAI is pinned to ' + [string]$MIRA_OPENAI_DEFAULT_MODEL + '.]') -ForegroundColor Yellow
                return
            }
            [void](Set-GemmaActiveModel -Provider $explicitProvider -Model $requestedId)
            return
        }

        if ($script:Provider -in @('antigravity','gemini') -and
            -not $catalog.ProviderStatuses.ContainsKey([string]$script:Provider)) {
            [void](Set-GemmaActiveModel -Provider ([string]$script:Provider) -Model $requestedId)
            return
        }

        Write-Host ("[Unknown model '{0}'. Run .model to browse the available models, or use .model provider:model-id.]" -f $requestedId) -ForegroundColor Yellow
        return
    }

    if ($matchingModels.Count -gt 1) {
        $activeMatches = @($matchingModels | Where-Object { [string]$_.provider -eq [string]$script:Provider })
        if ($activeMatches.Count -eq 1) {
            $matchingModels = $activeMatches
        } else {
            Write-Host ("[Model '{0}' is available from multiple providers. Use .model antigravity:{0} or .model google-ai-studio:{0}.]" -f $requestedId) -ForegroundColor Yellow
            return
        }
    }

    $selectedModel = $matchingModels[0]
    [void](Set-GemmaActiveModel -Provider ([string]$selectedModel.provider) -Model ([string]$selectedModel.name))
}
