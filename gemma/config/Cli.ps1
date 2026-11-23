function Get-GemmaCliArgs {
    param([object[]]$RawArgs)

    $a = @($RawArgs | ForEach-Object { [string]$_ })
    if ($a.Count -ge 2 -and $a[0] -ieq '-Command') {
        $cmd = ([string]$a[1]).Replace(' ', '').Replace([string][char]9, '').Replace([string][char]13, '').Replace([string][char]10, '')
        $expected = 'if((Get-ExecutionPolicy)-neAllSigned){Set-ExecutionPolicy-ScopeProcessBypass}'
        if ($cmd -ieq $expected) {
            return @($a | Select-Object -Skip 2)
        }
    }

    return $a
}

function Initialize-GemmaCliMode {
    param(
        [string]$Prompt,
        [string]$ExplainCommand,
        [object[]]$RemainingArgs
    )

    $script:RemainingCliArgs = @(Get-GemmaCliArgs -RawArgs $RemainingArgs)
    $script:OneShot = [bool](-not [string]::IsNullOrWhiteSpace($Prompt) -or
        -not [string]::IsNullOrWhiteSpace($ExplainCommand))
    $script:CommandMode = -not [string]::IsNullOrWhiteSpace($ExplainCommand)
    $script:OneShotCompleted = $false

    if ($script:CommandMode) { return $ExplainCommand }
    return $Prompt
}
