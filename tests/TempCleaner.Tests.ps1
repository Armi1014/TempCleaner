$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'TempCleaner.ps1')

Describe 'TempCleaner option resolution' {
    It 'applies config, CLI, and handoff precedence in the expected order' {
        $configPath = Join-Path $env:TEMP ("tc_config_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $importPath = Join-Path $env:TEMP ("tc_import_{0}.json" -f ([guid]::NewGuid().ToString('N')))

        try {
            @'
{
  "Preset": "Full",
  "DetailedLog": true,
  "SkipUpdateCheck": false,
  "IncludeDirectXShaderCache": true
}
'@ | Set-Content -LiteralPath $configPath -Encoding UTF8

            @'
{
  "Preset": "Custom",
  "WhatIf": true,
  "IncludeWindowsErrorReporting": true
}
'@ | Set-Content -LiteralPath $importPath -Encoding UTF8

            $configOptions = Read-OptionsFile -Path $configPath
            $importOptions = Read-OptionsFile -Path $importPath
            $cliOverrides = Get-OptionOverridesFromBoundParameters -BoundParameters @{
                Silent           = $true
                DetailedLogLimit = 120
            }

            $resolved = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions $configOptions -CliOverrides $cliOverrides -ImportOptions $importOptions

            $resolved.Preset | Should Be 'Custom'
            $resolved.DetailedLog | Should Be $true
            $resolved.WhatIf | Should Be $true
            $resolved.Silent | Should Be $true
            $resolved.DetailedLogLimit | Should Be 120
            $resolved.SkipUpdateCheck | Should Be $false
            $resolved.IncludeDirectXShaderCache | Should Be $true
            $resolved.IncludeWindowsErrorReporting | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $configPath, $importPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps update checks disabled by default unless explicitly enabled' {
        $resolved = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions $null -CliOverrides ([pscustomobject]@{}) -ImportOptions $null
        $resolved.SkipUpdateCheck | Should Be $true
    }
}

Describe 'TempCleaner path safety' {
    $allowedRoots = @(
        'C:\Users\TestUser\AppData\Local\Temp',
        'C:\Windows\Temp',
        'C:\Users\TestUser\AppData\Local\Microsoft\Windows\Explorer',
        'C:\Users\TestUser\AppData\Local\D3DSCache',
        'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache',
        'C:\Users\TestUser\AppData\Local\Microsoft\Windows\WER\ReportQueue'
    )

    It 'treats blank paths as dangerous' {
        (Get-PathSafetyIssue -Path ' ' -AllowedRoots $allowedRoots) | Should Be 'Empty path'
    }

    It 'blocks drive roots' {
        (Test-IsDangerousPath -Path 'C:\' -AllowedRoots $allowedRoots) | Should Be $true
    }

    It 'blocks UNC share roots' {
        (Test-IsDangerousPath -Path '\\server\share\' -AllowedRoots $allowedRoots) | Should Be $true
    }

    It 'treats malformed paths as dangerous' {
        (Test-IsDangerousPath -Path 'C:\Temp\bad|name' -AllowedRoots $allowedRoots) | Should Be $true
    }

    It 'allows configured child paths under allowlisted roots' {
        (Test-IsDangerousPath -Path 'C:\Users\TestUser\AppData\Local\Temp\child' -AllowedRoots $allowedRoots) | Should Be $false
    }

    It 'allows new optional cache roots when they are on the allowlist' {
        (Test-IsDangerousPath -Path 'C:\Users\TestUser\AppData\Local\D3DSCache\entry.bin' -AllowedRoots $allowedRoots) | Should Be $false
    }
}

Describe 'TempCleaner execution planning' {
    It 'falls back to user-only cleanup when a non-admin run cannot rely on elevation' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions $null -CliOverrides ([pscustomobject]@{}) -ImportOptions $null
        $plan = Get-ExecutionPlan -IsAdmin:$false -Options $options -HasImportedOptions:$true

        $plan.RunSystemTargets | Should Be $false
        $plan.ShouldAttemptElevation | Should Be $false
        $plan.SystemTargetSkipReason | Should Be 'no administrator privileges'
    }
}

Describe 'TempCleaner target composition' {
    It 'keeps Full preset semantics when applied non-interactively' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions ([pscustomobject]@{
                Preset = 'Full'
            }) -CliOverrides ([pscustomobject]@{
                Silent = $true
            }) -ImportOptions $null

        Set-PresetOptions -Name $options.Preset -Options $options

        $options.DetailedLog | Should Be $true
        $options.IncludeThumbnails | Should Be $true
        $options.SkipThumbnails | Should Be $false
    }

    It 'keeps explicit CLI switches after applying non-interactive preset defaults' {
        $cliOverrides = Get-OptionOverridesFromBoundParameters -BoundParameters @{
            Preset               = 'Basic'
            Silent               = $true
            WhatIf               = $true
            DisableNotifications = $true
            DetailedLog          = $true
        }

        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions $null -CliOverrides $cliOverrides -ImportOptions $null
        Set-PresetOptions -Name $options.Preset -Options $options
        $options = Restore-ExplicitOptionOverrides -Options $options -CliOverrides $cliOverrides -ImportOptions $null
        $options = Get-NormalizedOptions -Options $options -FallbackPreset 'Basic'

        $options.WhatIf | Should Be $true
        $options.DisableNotifications | Should Be $true
        $options.DetailedLog | Should Be $true
    }

    It 'keeps all optional targets out of Basic even when they are enabled' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions ([pscustomobject]@{
                Preset                          = 'Basic'
                IncludeDirectXShaderCache       = $true
                IncludeDeliveryOptimizationCache = $true
                IncludeWindowsErrorReporting    = $true
            }) -CliOverrides ([pscustomobject]@{}) -ImportOptions $null

        $targets = Get-RunTargets -Options $options
        ($targets.Desc -join '|') | Should Not Match 'DirectX Shader Cache'
        ($targets.Desc -join '|') | Should Not Match 'Delivery Optimization Cache'
        ($targets.Desc -join '|') | Should Not Match 'WER Report'
    }

    It 'adds only enabled optional targets to Full' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions ([pscustomobject]@{
                Preset                          = 'Full'
                IncludeDirectXShaderCache       = $true
                IncludeDeliveryOptimizationCache = $false
                IncludeWindowsErrorReporting    = $true
            }) -CliOverrides ([pscustomobject]@{}) -ImportOptions $null

        $targets = Get-RunTargets -Options $options
        ($targets.Desc -join '|') | Should Match 'DirectX Shader Cache'
        ($targets.Desc -join '|') | Should Match 'WER Report Queue \(User\)'
        ($targets.Desc -join '|') | Should Match 'WER Report Archive \(System\)'
        ($targets.Desc -join '|') | Should Not Match 'Delivery Optimization Cache'
    }

    It 'uses the current option values as Custom prompt defaults' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions ([pscustomobject]@{
                Preset                          = 'Custom'
                IncludeDirectXShaderCache       = $true
                IncludeDeliveryOptimizationCache = $false
                IncludeWindowsErrorReporting    = $true
            }) -CliOverrides ([pscustomobject]@{}) -ImportOptions $null

        $states = Get-OptionalCleanupOptionStates -Options $options

        (($states | Where-Object { $_.OptionKey -eq 'IncludeDirectXShaderCache' }).Enabled) | Should Be $true
        (($states | Where-Object { $_.OptionKey -eq 'IncludeDeliveryOptimizationCache' }).Enabled) | Should Be $false
        (($states | Where-Object { $_.OptionKey -eq 'IncludeWindowsErrorReporting' }).Enabled) | Should Be $true
    }

    It 'keeps user-scoped optional targets runnable and system-scoped ones skippable without admin' {
        $options = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions ([pscustomobject]@{
                Preset                          = 'Full'
                IncludeDirectXShaderCache       = $true
                IncludeDeliveryOptimizationCache = $true
                IncludeWindowsErrorReporting    = $true
            }) -CliOverrides ([pscustomobject]@{}) -ImportOptions $null

        $targets = Get-RunTargets -Options $options
        $plan = Get-ExecutionPlan -IsAdmin:$false -Options $options -HasImportedOptions:$true
        $runnableTargets = @($targets | Where-Object { (-not $_.RequiresAdmin) -or $plan.RunSystemTargets })
        $skippedTargets = @($targets | Where-Object { $_.RequiresAdmin -and -not $plan.RunSystemTargets })

        ($runnableTargets.Desc -join '|') | Should Match 'DirectX Shader Cache'
        ($runnableTargets.Desc -join '|') | Should Match 'WER Report Queue \(User\)'
        ($skippedTargets.Desc -join '|') | Should Match 'Delivery Optimization Cache'
        ($skippedTargets.Desc -join '|') | Should Match 'WER Report Archive \(System\)'
    }
}

Describe 'TempCleaner settings persistence' {
    It 'writes optional target settings back to config as valid JSON' {
        $configPath = Join-Path $env:TEMP ("tc_settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))

        try {
            $configDefaults = New-DefaultOptions
            $configDefaults.IncludeDirectXShaderCache = $true
            $configDefaults.IncludeDeliveryOptimizationCache = $false
            $configDefaults.IncludeWindowsErrorReporting = $true

            Write-OptionsFile -Options $configDefaults -Path $configPath
            $reloaded = Read-OptionsFile -Path $configPath

            $reloaded.IncludeDirectXShaderCache | Should Be $true
            $reloaded.IncludeDeliveryOptimizationCache | Should Be $false
            $reloaded.IncludeWindowsErrorReporting | Should Be $true
            $reloaded.Preset | Should Be 'Basic'
        }
        finally {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TempCleaner cleanup accounting' {
    It 'credits freed bytes only for files deleted successfully' {
        $tempRoot = Join-Path $env:TEMP ("tc_stats_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $logPath = Join-Path $tempRoot 'cleanup.log'

        try {
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'a.tmp'), [byte[]](1..5))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'b.tmp'), [byte[]](1..7))

            $script:RunStats.Clear()
            $script:ActiveLogFile = $logPath

            Clear-Folder -Path $tempRoot -Description 'Accounting success' -SilentMode -AllowedRoots @($tempRoot)
            $stats = $script:RunStats[$script:RunStats.Count - 1]

            $stats.Result | Should Be 'Cleaned'
            $stats.FreedBytes | Should Be 12
        }
        finally {
            $script:ActiveLogFile = $null
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports partial cleanup and excludes locked files from freed bytes' {
        $tempRoot = Join-Path $env:TEMP ("tc_locked_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $logPath = Join-Path $tempRoot 'cleanup.log'
        $lockedFile = Join-Path $tempRoot 'locked.tmp'
        $openFile = Join-Path $tempRoot 'open.tmp'
        $lockedStream = $null

        try {
            [System.IO.File]::WriteAllBytes($lockedFile, [byte[]](1..9))
            [System.IO.File]::WriteAllBytes($openFile, [byte[]](1..4))
            $lockedStream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

            $script:RunStats.Clear()
            $script:ActiveLogFile = $logPath

            Clear-Folder -Path $tempRoot -Description 'Accounting partial' -SilentMode -AllowedRoots @($tempRoot)
            $stats = $script:RunStats[$script:RunStats.Count - 1]

            $stats.Result | Should Be 'Partial'
            $stats.FreedBytes | Should Be 4
            $stats.Notes | Should Match 'busy/locked'
        }
        finally {
            if ($lockedStream) {
                $lockedStream.Dispose()
            }
            $script:ActiveLogFile = $null
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'cleans a user-scoped optional target path like the DirectX shader cache' {
        $tempRoot = Join-Path $env:TEMP ("tc_d3ds_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $logPath = Join-Path $tempRoot 'cleanup.log'

        try {
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'shader.bin'), [byte[]](1..8))

            $script:RunStats.Clear()
            $script:ActiveLogFile = $logPath

            Clear-Folder -Path $tempRoot -Description 'DirectX Shader Cache' -SilentMode -AllowedRoots @($tempRoot)
            $stats = $script:RunStats[$script:RunStats.Count - 1]

            $stats.Description | Should Be 'DirectX Shader Cache'
            $stats.Result | Should Be 'Cleaned'
            $stats.FreedBytes | Should Be 8
        }
        finally {
            $script:ActiveLogFile = $null
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TempCleaner log rotation' {
    function New-AgedLog {
        param([string]$Root, [string]$Name, [int]$AgeDays)
        $path = Join-Path $Root $Name
        Set-Content -LiteralPath $path -Value '' -Encoding UTF8
        (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
        return $path
    }

    It 'keeps the most recent N runs when KeepCount is set' {
        $logRoot = Join-Path $env:TEMP ("tc_logrot_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        try {
            for ($i = 1; $i -le 35; $i++) {
                New-AgedLog -Root $logRoot -Name ("cleanup_test_{0:D3}.log" -f $i) -AgeDays $i | Out-Null
            }
            $result = Invoke-LogRotation -LogRoot $logRoot -KeepCount 30 -MaxAgeDays 0
            $result.Deleted | Should Be 5
            (Get-ChildItem -LiteralPath $logRoot -Filter 'cleanup_*.log').Count | Should Be 30
        }
        finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'purges files older than MaxAgeDays regardless of count' {
        $logRoot = Join-Path $env:TEMP ("tc_logage_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        try {
            New-AgedLog -Root $logRoot -Name 'cleanup_recent_a.log' -AgeDays 1 | Out-Null
            New-AgedLog -Root $logRoot -Name 'cleanup_recent_b.log' -AgeDays 3 | Out-Null
            New-AgedLog -Root $logRoot -Name 'cleanup_old_a.log' -AgeDays 10 | Out-Null
            New-AgedLog -Root $logRoot -Name 'cleanup_old_b.log' -AgeDays 20 | Out-Null

            $result = Invoke-LogRotation -LogRoot $logRoot -KeepCount 100 -MaxAgeDays 5
            $result.Deleted | Should Be 2
            $remaining = Get-ChildItem -LiteralPath $logRoot -Filter 'cleanup_*.log'
            $remaining.Count | Should Be 2
            ($remaining.Name -join '|') | Should Match 'recent'
            ($remaining.Name -join '|') | Should Not Match 'old'
        }
        finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is a no-op when both retention rules are disabled' {
        $logRoot = Join-Path $env:TEMP ("tc_lognoop_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        try {
            for ($i = 1; $i -le 5; $i++) {
                New-AgedLog -Root $logRoot -Name ("cleanup_keep_{0}.log" -f $i) -AgeDays ($i * 10) | Out-Null
            }
            $result = Invoke-LogRotation -LogRoot $logRoot -KeepCount 0 -MaxAgeDays 0
            $result.Deleted | Should Be 0
            $result.Kept | Should Be 5
            (Get-ChildItem -LiteralPath $logRoot -Filter 'cleanup_*.log').Count | Should Be 5
        }
        finally {
            Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TempCleaner config parsing' {
    It 'throws when the config file contains malformed JSON' {
        $configPath = Join-Path $env:TEMP ("tc_badconfig_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        try {
            Set-Content -LiteralPath $configPath -Value '{ "Preset": "Full"' -Encoding UTF8
            $threw = $false
            try {
                Read-OptionsFile -Path $configPath | Out-Null
            }
            catch {
                $threw = $true
            }
            $threw | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TempCleaner deletion preview' {
    It 'returns scan totals from Invoke-FolderScan without deleting' {
        $tempRoot = Join-Path $env:TEMP ("tc_scan_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'a.bin'), [byte[]](1..3))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'b.bin'), [byte[]](1..7))
            $logPath = Join-Path $tempRoot 'scan.log'
            $script:ActiveLogFile = $logPath

            $scan = Invoke-FolderScan -Path $tempRoot -Description 'Scan only' -SilentMode -AllowedRoots @($tempRoot)

            $scan.FileItems.Count | Should Be 2
            $scan.SizeBytes | Should Be 10
            $scan.PreResolvedResult | Should Be $null
            (Test-Path -LiteralPath (Join-Path $tempRoot 'a.bin')) | Should Be $true
        }
        finally {
            $script:ActiveLogFile = $null
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TempCleaner reparse point safety' {
    $junctionProbe = Join-Path $env:TEMP ("tc_junc_probe_{0}" -f ([guid]::NewGuid().ToString('N')))
    $junctionTarget = Join-Path $env:TEMP ("tc_junc_target_{0}" -f ([guid]::NewGuid().ToString('N')))
    $cmdPath = if ($env:ComSpec -and (Test-Path -LiteralPath $env:ComSpec)) {
        $env:ComSpec
    }
    else {
        (Get-Command cmd.exe -ErrorAction SilentlyContinue).Source
    }
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    if ($cmdPath) {
        & $cmdPath /c "mklink /J `"$junctionProbe`" `"$junctionTarget`"" *> $null
    }
    $junctionsSupported = ($cmdPath -and $LASTEXITCODE -eq 0)
    if ($cmdPath -and (Test-Path -LiteralPath $junctionProbe)) { & $cmdPath /c "rmdir `"$junctionProbe`"" *> $null }
    Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue

    It 'skips junction directories without recursing into the target' -Skip:(-not $junctionsSupported) {
        $base = Join-Path $env:TEMP ("tc_junc_{0}" -f ([guid]::NewGuid().ToString('N')))
        $sourceRoot = Join-Path $base 'source'
        $targetRoot = Join-Path $base 'target'
        $junctionPath = Join-Path $sourceRoot 'link'
        New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        $protectedFile = Join-Path $targetRoot 'protected.txt'
        Set-Content -LiteralPath $protectedFile -Value 'keep' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $sourceRoot 'normal.txt') -Value 'remove' -Encoding UTF8
        & $cmdPath /c "mklink /J `"$junctionPath`" `"$targetRoot`"" *> $null

        try {
            $script:RunStats.Clear()
            $script:ActiveLogFile = (Join-Path $base 'cleanup.log')

            Clear-Folder -Path $sourceRoot -Description 'Junction guard' -SilentMode -AllowedRoots @($sourceRoot)
            $stats = $script:RunStats[$script:RunStats.Count - 1]

            (Test-Path -LiteralPath $protectedFile) | Should Be $true
            $stats.Notes | Should Match 'junction'
        }
        finally {
            $script:ActiveLogFile = $null
            if (Test-Path -LiteralPath $junctionPath) {
                & $cmdPath /c "rmdir `"$junctionPath`"" *> $null
            }
            Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
