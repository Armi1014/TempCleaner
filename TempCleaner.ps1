<#
.SYNOPSIS
  Cleans common Windows temp/cache folders with optional presets.
.DESCRIPTION
  Runs a safe cleanup pass for user/system temp locations, with per-run logs
  and optional thumbnail-cache cleanup. Interactive mode shows a simple menu
  plus a Settings screen for opt-in Windows cache targets.
.EXAMPLE
  .\TempCleaner.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Basic', 'Full', 'Custom')]
    [string]$Preset,
    [switch]$WhatIf,
    [switch]$DetailedLog,
    [int]$DetailedLogLimit,
    [switch]$IncludeThumbnails,
    [switch]$SkipThumbnails,
    [switch]$Silent,
    [switch]$DisableNotifications,
    [switch]$SkipUpdateCheck,
    [switch]$UserOnly,
    [switch]$IncludeDirectXShaderCache,
    [switch]$IncludeDeliveryOptimizationCache,
    [switch]$IncludeWindowsErrorReporting,
    [int]$LogRetentionCount,
    [int]$LogRetentionDays,
    [string]$ConfigPath,
    [string]$OptionsImportPath
)

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogRoot = Join-Path $script:AppRoot 'logs'
$script:VersionFile = Join-Path $script:AppRoot 'version.json'
$script:DefaultConfigPath = Join-Path $script:AppRoot 'TempCleaner.config.json'
$script:RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:DefaultUpdateFeed = "https://raw.githubusercontent.com/ardai/TempCleaner/main/version.json"
$script:RunStats = [System.Collections.Generic.List[pscustomobject]]::new()
$script:ActiveLogFile = $null
$script:IsSilent = $false
$script:AllowedCleanupRoots = @()
$script:CliBoundParameters = @{} + $PSBoundParameters
$script:Version = [version]'0.6.0'
$script:PendingLogMessages = [System.Collections.Generic.List[string]]::new()

function Write-LogPending {
    param(
        [Parameter(Mandatory)][string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $script:PendingLogMessages.Add("[$timestamp] $Message") | Out-Null
}

function Sync-PendingLogMessages {
    if (-not $script:ActiveLogFile) { return }
    if ($script:PendingLogMessages.Count -eq 0) { return }
    $logDirectory = Split-Path -Parent $script:ActiveLogFile
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    $snapshot = @($script:PendingLogMessages)
    $script:PendingLogMessages.Clear()
    Add-Content -Path $script:ActiveLogFile -Value $snapshot
}

function Invoke-LogRotation {
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [int]$KeepCount = 30,
        [int]$MaxAgeDays = 14
    )

    $result = [pscustomobject]@{ Deleted = 0; Kept = 0 }
    if (-not (Test-Path -LiteralPath $LogRoot)) { return $result }
    if ($KeepCount -le 0 -and $MaxAgeDays -le 0) {
        $existing = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'cleanup_*.log' -File -ErrorAction SilentlyContinue)
        $result.Kept = $existing.Count
        return $result
    }

    $existing = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'cleanup_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)

    $cutoff = if ($MaxAgeDays -gt 0) { (Get-Date).AddDays(-$MaxAgeDays) } else { [datetime]::MinValue }
    $toDelete = [System.Collections.Generic.List[object]]::new()
    $kept = 0
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $file = $existing[$i]
        $exceedsCount = ($KeepCount -gt 0) -and ($i -ge $KeepCount)
        $tooOld = ($MaxAgeDays -gt 0) -and ($file.LastWriteTime -lt $cutoff)
        if ($exceedsCount -or $tooOld) {
            $toDelete.Add($file) | Out-Null
        }
        else {
            $kept++
        }
    }

    foreach ($file in $toDelete) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $result.Deleted++
        }
        catch {
            # Rotation must never throw — leave the file in place if removal fails.
        }
    }
    $result.Kept = $kept
    return $result
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $script:ActiveLogFile) {
        Write-LogPending -Message $Message
        return
    }
    $logDirectory = Split-Path -Parent $script:ActiveLogFile
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    Sync-PendingLogMessages
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $script:ActiveLogFile -Value "[$timestamp] $Message"
}

function Write-LogBatch {
    param(
        [Parameter(Mandatory)][string[]]$Messages
    )
    if (-not $Messages -or $Messages.Count -eq 0) { return }
    if (-not $script:ActiveLogFile) {
        foreach ($m in $Messages) { Write-LogPending -Message $m }
        return
    }

    $logDirectory = Split-Path -Parent $script:ActiveLogFile
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    Sync-PendingLogMessages
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $buffer = foreach ($line in $Messages) {
        "[$timestamp] $line"
    }
    Add-Content -Path $script:ActiveLogFile -Value $buffer
}

function Write-Ui {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color,
        [switch]$NoNewline,
        [switch]$VerboseOnly
    )
    if ($script:IsSilent) { return }
    if ($VerboseOnly) {
        Write-Verbose $Message
        return
    }
    $writeParams = @{}
    if ($PSBoundParameters.ContainsKey('Color')) {
        $writeParams.ForegroundColor = $Color
    }
    if ($NoNewline) {
        $writeParams.NoNewline = $true
    }
    Write-Host $Message @writeParams
}

function Format-Bytes {
    param([long]$Bytes)
    if ($null -eq $Bytes -or $Bytes -le 0) { return "0 MB" }
    $units = @("B","KB","MB","GB","TB")
    $i = 0
    $value = [double]$Bytes
    while ($value -ge 1024 -and $i -lt $units.Count - 1) {
        $value /= 1024
        $i++
    }
    return ("{0:N2} {1}" -f $value, $units[$i])
}

function Get-UiWidth {
    try {
        $width = [int]$Host.UI.RawUI.WindowSize.Width
        if ($width -lt 40) { return 80 }
        return $width
    }
    catch {
        return 80
    }
}

function Write-Rule {
    param(
        [char]$Char = '-',
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )

    $width = Get-UiWidth
    $ruleLength = [Math]::Min([Math]::Max(52, $width - 2), 110)
    Write-Ui ($Char.ToString() * $ruleLength) -Color $Color
}

function Write-KeyValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray
    )

    $label = (" {0,-13}" -f ($Key + ':'))
    Write-Ui $label -Color DarkGray -NoNewline
    Write-Ui $Value -Color $ValueColor
}

function Write-Section {
    param(
        [Parameter(Mandatory)][string]$Title,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    Write-Ui ""
    Write-Rule -Char '=' -Color DarkCyan
    Write-Ui (" [{0}]" -f $Title.ToUpperInvariant()) -Color $Color
    Write-Rule -Char '-' -Color DarkCyan
}

function Show-Header {
    Write-Rule -Char '=' -Color DarkCyan
    Write-Ui (" TempCleaner v{0}" -f $script:Version) -Color Cyan
    Write-Ui (" Safe temp/cache cleanup for Windows") -Color DarkGray
    Write-KeyValue -Key "Session" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -ValueColor DarkGray
    Write-KeyValue -Key "Safety" -Value "Allowlisted targets only, roots blocked" -ValueColor DarkGray
    Write-Rule -Char '=' -Color DarkCyan
    Write-Ui ""
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AppVersion {
    $fallbackVersion = [version]'0.6.0'
    try {
        if (-not (Test-Path -LiteralPath $script:VersionFile)) {
            return $fallbackVersion
        }

        $rawVersion = Get-Content -LiteralPath $script:VersionFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($rawVersion.PSObject.Properties.Name -contains 'version' -and -not [string]::IsNullOrWhiteSpace([string]$rawVersion.version)) {
            return [version]$rawVersion.version
        }
    }
    catch {
        return $fallbackVersion
    }

    return $fallbackVersion
}

$script:Version = Get-AppVersion

function New-DefaultOptions {
    return [pscustomobject]@{
        DetailedLog          = $false
        DetailedLogLimit     = 5000
        SkipThumbnails       = $true
        IncludeThumbnails    = $false
        WhatIf               = $false
        Silent               = $false
        DisableNotifications = $false
        Preset               = 'Basic'
        UpdateFeed           = $script:DefaultUpdateFeed
        SkipUpdateCheck      = $true
        UpdateTimeoutSec     = 5
        UserOnly             = $false
        IncludeDirectXShaderCache = $false
        IncludeDeliveryOptimizationCache = $false
        IncludeWindowsErrorReporting = $false
        LogRetentionCount    = 30
        LogRetentionDays     = 14
    }
}

function Copy-OptionValues {
    param(
        [Parameter(Mandatory)][pscustomobject]$Target,
        $Source
    )

    if ($null -eq $Source) {
        return $Target
    }

    foreach ($prop in $Target.PSObject.Properties.Name) {
        if ($Source.PSObject.Properties.Name -contains $prop) {
            $Target.$prop = $Source.$prop
        }
    }

    return $Target
}

function Get-OptionOverridesFromBoundParameters {
    param(
        [Parameter(Mandatory)][hashtable]$BoundParameters
    )

    $supportedKeys = @(
        'Preset',
        'WhatIf',
        'DetailedLog',
        'DetailedLogLimit',
        'IncludeThumbnails',
        'SkipThumbnails',
        'Silent',
        'DisableNotifications',
        'SkipUpdateCheck',
        'UserOnly',
        'IncludeDirectXShaderCache',
        'IncludeDeliveryOptimizationCache',
        'IncludeWindowsErrorReporting',
        'LogRetentionCount',
        'LogRetentionDays'
    )

    $overrides = [ordered]@{}
    foreach ($key in $supportedKeys) {
        if (-not $BoundParameters.ContainsKey($key)) {
            continue
        }

        $value = $BoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            $overrides[$key] = [bool]$value
        }
        else {
            $overrides[$key] = $value
        }
    }

    return [pscustomobject]$overrides
}

function Resolve-Options {
    param(
        [Parameter(Mandatory)][pscustomobject]$DefaultOptions,
        $ConfigOptions,
        $CliOverrides,
        $ImportOptions
    )

    $resolved = [pscustomobject]@{}
    foreach ($prop in $DefaultOptions.PSObject.Properties.Name) {
        $resolved | Add-Member -NotePropertyName $prop -NotePropertyValue $DefaultOptions.$prop
    }

    $resolved = Copy-OptionValues -Target $resolved -Source $ConfigOptions
    $resolved = Copy-OptionValues -Target $resolved -Source $CliOverrides
    $resolved = Copy-OptionValues -Target $resolved -Source $ImportOptions

    return Get-NormalizedOptions -Options $resolved -FallbackPreset $DefaultOptions.Preset
}

function Restore-ExplicitOptionOverrides {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        $CliOverrides,
        $ImportOptions
    )

    $Options = Copy-OptionValues -Target $Options -Source $CliOverrides
    $Options = Copy-OptionValues -Target $Options -Source $ImportOptions

    return $Options
}

function Read-OptionsFile {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-OptionsFile {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][string]$Path
    )

    $normalizedOptions = Get-NormalizedOptions -Options $Options -FallbackPreset 'Basic'
    $orderedOptions = [ordered]@{
        DetailedLog                     = $normalizedOptions.DetailedLog
        DetailedLogLimit                = $normalizedOptions.DetailedLogLimit
        SkipThumbnails                  = $normalizedOptions.SkipThumbnails
        IncludeThumbnails               = $normalizedOptions.IncludeThumbnails
        WhatIf                          = $normalizedOptions.WhatIf
        Silent                          = $normalizedOptions.Silent
        DisableNotifications            = $normalizedOptions.DisableNotifications
        Preset                          = $normalizedOptions.Preset
        UpdateFeed                      = $normalizedOptions.UpdateFeed
        SkipUpdateCheck                 = $normalizedOptions.SkipUpdateCheck
        UpdateTimeoutSec                = $normalizedOptions.UpdateTimeoutSec
        UserOnly                        = $normalizedOptions.UserOnly
        IncludeDirectXShaderCache       = $normalizedOptions.IncludeDirectXShaderCache
        IncludeDeliveryOptimizationCache = $normalizedOptions.IncludeDeliveryOptimizationCache
        IncludeWindowsErrorReporting    = $normalizedOptions.IncludeWindowsErrorReporting
        LogRetentionCount               = $normalizedOptions.LogRetentionCount
        LogRetentionDays                = $normalizedOptions.LogRetentionDays
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = [pscustomobject]$orderedOptions | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Sync-OptionValues {
    param(
        [Parameter(Mandatory)][pscustomobject]$Target,
        [Parameter(Mandatory)][pscustomobject]$Source,
        [Parameter(Mandatory)][string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        if ($Target.PSObject.Properties.Name -contains $propertyName -and $Source.PSObject.Properties.Name -contains $propertyName) {
            $Target.$propertyName = $Source.$propertyName
        }
    }

    return $Target
}

function Get-OptionalCleanupOptionDefinitions {
    return @(
        [pscustomobject]@{
            OptionKey         = 'IncludeDirectXShaderCache'
            Label             = 'DirectX Shader Cache'
            Prompt            = 'Clean DirectX shader cache?'
            SettingsDetail    = '%LOCALAPPDATA%\D3DSCache'
            RequiresAdmin     = $false
        },
        [pscustomobject]@{
            OptionKey         = 'IncludeDeliveryOptimizationCache'
            Label             = 'Delivery Optimization Cache'
            Prompt            = 'Clean Delivery Optimization cache?'
            SettingsDetail    = 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache'
            RequiresAdmin     = $true
        },
        [pscustomobject]@{
            OptionKey         = 'IncludeWindowsErrorReporting'
            Label             = 'Windows Error Reporting'
            Prompt            = 'Clean Windows Error Reporting queues/archives?'
            SettingsDetail    = 'WER ReportQueue + ReportArchive'
            RequiresAdmin     = $false
        }
    )
}

function Get-OptionalCleanupOptionStates {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )

    return @(
        foreach ($definition in Get-OptionalCleanupOptionDefinitions) {
            [pscustomobject]@{
                OptionKey      = $definition.OptionKey
                Label          = $definition.Label
                Prompt         = $definition.Prompt
                SettingsDetail = $definition.SettingsDetail
                RequiresAdmin  = $definition.RequiresAdmin
                Enabled        = [bool]$Options.($definition.OptionKey)
            }
        }
    )
}

function Get-OptionalCleanupOptionKeys {
    return @((Get-OptionalCleanupOptionDefinitions | ForEach-Object { $_.OptionKey }))
}

function Get-TargetDescriptors {
    return @(
        [pscustomobject]@{
            Path              = $env:TEMP
            Desc              = 'User Temp Files'
            RequiresAdmin     = $false
            OptionalSettingKey = $null
            Presets           = @('Basic', 'Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"
            Desc              = 'Edge/IE Cache'
            RequiresAdmin     = $false
            OptionalSettingKey = $null
            Presets           = @('Basic', 'Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:LOCALAPPDATA\D3DSCache"
            Desc              = 'DirectX Shader Cache'
            RequiresAdmin     = $false
            OptionalSettingKey = 'IncludeDirectXShaderCache'
            Presets           = @('Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"
            Desc              = 'WER Report Queue (User)'
            RequiresAdmin     = $false
            OptionalSettingKey = 'IncludeWindowsErrorReporting'
            Presets           = @('Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"
            Desc              = 'WER Report Archive (User)'
            RequiresAdmin     = $false
            OptionalSettingKey = 'IncludeWindowsErrorReporting'
            Presets           = @('Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = 'C:\Windows\Temp'
            Desc              = 'System Temp Files'
            RequiresAdmin     = $true
            OptionalSettingKey = $null
            Presets           = @('Basic', 'Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = 'C:\Windows\SoftwareDistribution\Download'
            Desc              = 'Windows Update Cache'
            RequiresAdmin     = $true
            OptionalSettingKey = $null
            Presets           = @('Basic', 'Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = 'C:\Windows\Minidump'
            Desc              = 'Memory Dumps'
            RequiresAdmin     = $true
            OptionalSettingKey = $null
            Presets           = @('Basic', 'Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache'
            Desc              = 'Delivery Optimization Cache'
            RequiresAdmin     = $true
            OptionalSettingKey = 'IncludeDeliveryOptimizationCache'
            Presets           = @('Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportQueue"
            Desc              = 'WER Report Queue (System)'
            RequiresAdmin     = $true
            OptionalSettingKey = 'IncludeWindowsErrorReporting'
            Presets           = @('Full', 'Custom')
        },
        [pscustomobject]@{
            Path              = "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportArchive"
            Desc              = 'WER Report Archive (System)'
            RequiresAdmin     = $true
            OptionalSettingKey = 'IncludeWindowsErrorReporting'
            Presets           = @('Full', 'Custom')
        }
    )
}

function Get-RunTargets {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )

    $targets = foreach ($descriptor in Get-TargetDescriptors) {
        if ($descriptor.Presets -notcontains $Options.Preset) {
            continue
        }

        if ($descriptor.OptionalSettingKey) {
            if (-not $Options.($descriptor.OptionalSettingKey)) {
                continue
            }
        }

        [pscustomobject]@{
            Path          = $descriptor.Path
            Desc          = $descriptor.Desc
            RequiresAdmin = [bool]$descriptor.RequiresAdmin
            IsOptional    = [bool]$descriptor.OptionalSettingKey
        }
    }

    return @($targets)
}

function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $trimmedPath = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        return $null
    }

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($trimmedPath)
        $normalized = [System.IO.Path]::GetFullPath($expanded)
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            return $null
        }

        if ($normalized.Length -gt 3) {
            return $normalized.TrimEnd('\')
        }

        return $normalized
    }
    catch {
        return $null
    }
}

function Get-PathSafetyIssue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowedRoots
    )

    $trimmedPath = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) { return 'Empty path' }
    if ($trimmedPath -in @('\', '/')) { return 'Root path blocked' }

    $normalized = Resolve-NormalizedPath -Path $trimmedPath
    if ($null -eq $normalized) { return 'Path normalization failed' }

    $root = [System.IO.Path]::GetPathRoot($normalized)
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $comparison = if ($normalized.Length -gt 3) { $normalized.TrimEnd('\') } else { $normalized }
        $comparisonRoot = if ($root.Length -gt 3) { $root.TrimEnd('\') } else { $root }
        if ($comparison -ieq $comparisonRoot) {
            return 'Root path blocked'
        }
        if ($normalized -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?$') {
            return 'UNC share root blocked'
        }
    }

    if ($AllowedRoots -and $AllowedRoots.Count -gt 0) {
        $allowedMatches = $false
        foreach ($allowedRoot in $AllowedRoots) {
            $normalizedAllowedRoot = Resolve-NormalizedPath -Path $allowedRoot
            if ($null -eq $normalizedAllowedRoot) {
                continue
            }

            if ($normalized -ieq $normalizedAllowedRoot) {
                $allowedMatches = $true
                break
            }

            if ($normalized.StartsWith(($normalizedAllowedRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowedMatches = $true
                break
            }
        }

        if (-not $allowedMatches) {
            return 'Path is outside the cleanup allowlist'
        }
    }

    return $null
}

function Get-ExecutionPlan {
    param(
        [Parameter(Mandatory)][bool]$IsAdmin,
        [Parameter(Mandatory)][pscustomobject]$Options,
        [bool]$HasImportedOptions = $false
    )

    $shouldAttemptElevation = (-not $IsAdmin) -and (-not $Options.UserOnly) -and (-not $Options.Silent) -and (-not $HasImportedOptions)
    $runSystemTargets = $IsAdmin -and (-not $Options.UserOnly)

    $skipReason = $null
    if (-not $runSystemTargets) {
        if ($Options.UserOnly) {
            $skipReason = 'user-only mode'
        }
        elseif (-not $IsAdmin) {
            $skipReason = 'no administrator privileges'
        }
    }

    return [pscustomobject]@{
        RunSystemTargets      = $runSystemTargets
        ShouldAttemptElevation = $shouldAttemptElevation
        SystemTargetSkipReason = $skipReason
    }
}

function ConvertTo-SettingBool {
    param(
        $Value,
        [bool]$Default
    )
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $Default }

    $text = $Value.ToString().Trim().ToLowerInvariant()
    switch ($text) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'n' { return $false }
        default { return $Default }
    }
}

function ConvertTo-SettingInt {
    param(
        $Value,
        [int]$Default
    )
    if ($null -eq $Value) { return $Default }
    try {
        return [int]$Value
    }
    catch {
        return $Default
    }
}

function Get-NormalizedOptions {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [string]$FallbackPreset = 'Basic'
    )

    $validPresets = @('Basic', 'Full', 'Custom')
    $resolvedPreset = [string]$Options.Preset
    if ([string]::IsNullOrWhiteSpace($resolvedPreset)) {
        $resolvedPreset = $FallbackPreset
    }
    if ($validPresets -notcontains $resolvedPreset) {
        $resolvedPreset = if ($validPresets -contains $FallbackPreset) { $FallbackPreset } else { 'Basic' }
    }

    $normalized = [pscustomobject]@{
        DetailedLog          = ConvertTo-SettingBool -Value $Options.DetailedLog -Default $false
        DetailedLogLimit     = [Math]::Max(1, (ConvertTo-SettingInt -Value $Options.DetailedLogLimit -Default 5000))
        SkipThumbnails       = ConvertTo-SettingBool -Value $Options.SkipThumbnails -Default $true
        IncludeThumbnails    = ConvertTo-SettingBool -Value $Options.IncludeThumbnails -Default $false
        WhatIf               = ConvertTo-SettingBool -Value $Options.WhatIf -Default $false
        Silent               = ConvertTo-SettingBool -Value $Options.Silent -Default $false
        DisableNotifications = ConvertTo-SettingBool -Value $Options.DisableNotifications -Default $false
        Preset               = $resolvedPreset
        UpdateFeed           = [string]$Options.UpdateFeed
        SkipUpdateCheck      = ConvertTo-SettingBool -Value $Options.SkipUpdateCheck -Default $true
        UpdateTimeoutSec     = [Math]::Max(1, (ConvertTo-SettingInt -Value $Options.UpdateTimeoutSec -Default 5))
        UserOnly             = ConvertTo-SettingBool -Value $Options.UserOnly -Default $false
        IncludeDirectXShaderCache = ConvertTo-SettingBool -Value $Options.IncludeDirectXShaderCache -Default $false
        IncludeDeliveryOptimizationCache = ConvertTo-SettingBool -Value $Options.IncludeDeliveryOptimizationCache -Default $false
        IncludeWindowsErrorReporting = ConvertTo-SettingBool -Value $Options.IncludeWindowsErrorReporting -Default $false
        LogRetentionCount    = [Math]::Max(0, (ConvertTo-SettingInt -Value $Options.LogRetentionCount -Default 30))
        LogRetentionDays     = [Math]::Max(0, (ConvertTo-SettingInt -Value $Options.LogRetentionDays -Default 14))
    }

    if ($normalized.SkipThumbnails -and $normalized.IncludeThumbnails) {
        $normalized.IncludeThumbnails = $false
        $normalized.SkipThumbnails = $true
    }

    if ([string]::IsNullOrWhiteSpace($normalized.UpdateFeed)) {
        $normalized.UpdateFeed = $script:DefaultUpdateFeed
    }

    return $normalized
}

function Get-YesNoResponse {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$Default = $true
    )
    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $response = Read-Host "$Message $suffix"
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $Default
        }
        switch -Regex ($response.Trim()) {
            '^[Yy]' { return $true }
            '^[Nn]' { return $false }
        }
        Write-Ui "Please enter Y or N." -Color Yellow
    }
}

function Set-PresetOptions {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    switch ($Name.ToLowerInvariant()) {
        'basic' {
            $Options.DetailedLog = $false
            $Options.SkipThumbnails = $true
            $Options.IncludeThumbnails = $false
            $Options.DisableNotifications = $false
            $Options.WhatIf = $false
        }
        'full' {
            $Options.DetailedLog = $true
            $Options.SkipThumbnails = $false
            $Options.IncludeThumbnails = $true
            $Options.DisableNotifications = $false
            $Options.WhatIf = $false
        }
        'custom' { }
        default {
            Write-Ui "Unknown preset '$Name'. Falling back to Basic." -Color Yellow
        }
    }
}

function Invoke-SettingsMenu {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][pscustomobject]$ConfigDefaults,
        [Parameter(Mandatory)][string]$SettingsPath
    )

    $workingOptions = Resolve-Options -DefaultOptions (New-DefaultOptions) -ConfigOptions $ConfigDefaults -CliOverrides ([pscustomobject]@{}) -ImportOptions $null
    $settingKeys = Get-OptionalCleanupOptionKeys

    while ($true) {
        Write-Section -Title 'Settings'
        Write-KeyValue -Key 'Config' -Value $SettingsPath -ValueColor DarkGray
        Write-Ui ' Toggle persistent optional cleanup targets.' -Color DarkGray
        Write-Ui ''

        $states = Get-OptionalCleanupOptionStates -Options $workingOptions
        for ($i = 0; $i -lt $states.Count; $i++) {
            $state = $states[$i]
            $status = if ($state.Enabled) { 'ON' } else { 'OFF' }
            $statusColor = if ($state.Enabled) { 'Green' } else { 'DarkGray' }
            Write-Ui (" [{0}] {1}" -f ($i + 1), $state.Label) -Color Cyan -NoNewline
            Write-Ui ("  ({0})" -f $state.SettingsDetail) -Color DarkGray -NoNewline
            Write-Ui ("  -> {0}" -f $status) -Color $statusColor
        }

        Write-Ui ''
        Write-Ui ' [S] Save and back' -Color Green
        Write-Ui ' [D] Discard and back' -Color Yellow

        $response = Read-Host 'Choose 1-3, S, or D'
        if ([string]::IsNullOrWhiteSpace($response)) {
            Write-Ui 'Please choose an option.' -Color Yellow
            continue
        }

        switch -Regex ($response.Trim()) {
            '^[1-3]$' {
                $selectedState = $states[[int]$response - 1]
                $workingOptions.$($selectedState.OptionKey) = -not $workingOptions.$($selectedState.OptionKey)
            }
            '^[Ss]$' {
                $ConfigDefaults = Sync-OptionValues -Target $ConfigDefaults -Source $workingOptions -PropertyNames $settingKeys
                $Options = Sync-OptionValues -Target $Options -Source $workingOptions -PropertyNames $settingKeys
                try {
                    Write-OptionsFile -Options $ConfigDefaults -Path $SettingsPath
                    Write-Ui 'Settings saved.' -Color Green
                    return
                }
                catch {
                    Write-Ui ("Failed to save settings: {0}" -f $_.Exception.Message) -Color Red
                }
            }
            '^[Dd]$' {
                Write-Ui 'Settings unchanged.' -Color Yellow
                return
            }
            default {
                Write-Ui 'Please choose 1-3, S, or D.' -Color Yellow
            }
        }
    }
}

function Invoke-ModeMenu {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][pscustomobject]$ConfigDefaults,
        [Parameter(Mandatory)][string]$SettingsPath
    )
    $presetTable = @(
        [pscustomobject]@{ Id = 1; Name = "Basic";  Description = "Fast cleanup (skip thumbnails)." },
        [pscustomobject]@{ Id = 2; Name = "Full";   Description = "Everything + thumbnails + detailed log." },
        [pscustomobject]@{ Id = 3; Name = "Custom"; Description = "Pick options one by one." },
        [pscustomobject]@{ Id = 4; Name = "Settings"; Description = "Edit persistent optional cleanup defaults." }
    )

    :mainMenu while ($true) {
        Write-Section -Title "Choose Cleanup Mode"
        $defaultChoice = switch ($Options.Preset) {
            'Full' { '2' }
            'Custom' { '3' }
            default { '1' }
        }
        $selectedIndex = [Math]::Max(0, [int]$defaultChoice - 1)
        $menuWidth = [Math]::Max(68, ((Get-UiWidth) - 1))

        Write-Ui (" Use Up/Down arrows, then press Enter to continue.") -Color DarkGray
        Write-Ui ""

        $renderMenu = {
            param([int]$ActiveIndex, [int]$MenuTop)
            for ($i = 0; $i -lt $presetTable.Count; $i++) {
                $row = $presetTable[$i]
                $label = "{0,-8} {1}" -f $row.Name.ToUpperInvariant(), $row.Description
                $marker = if ($i -eq $ActiveIndex) { '>' } else { ' ' }
                $line = (" {0} [{1}] {2}" -f $marker, $row.Id, $label).PadRight($menuWidth)
                $color = switch ($row.Name) {
                    'Basic' { 'Green' }
                    'Full' { 'Yellow' }
                    'Custom' { 'Cyan' }
                    'Settings' { 'Magenta' }
                    default { 'White' }
                }
                if ($i -eq $ActiveIndex) {
                    $color = 'White'
                }
                [Console]::SetCursorPosition(0, $MenuTop + $i)
                Write-Host $line -ForegroundColor $color
            }
            [Console]::SetCursorPosition(0, $MenuTop + $presetTable.Count)
        }

        $choice = [string]($selectedIndex + 1)
        try {
            $menuTop = [Console]::CursorTop
            & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop

            :menuLoop while ($true) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        $selectedIndex = if ($selectedIndex -le 0) { $presetTable.Count - 1 } else { $selectedIndex - 1 }
                        & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop
                    }
                    'DownArrow' {
                        $selectedIndex = if ($selectedIndex -ge ($presetTable.Count - 1)) { 0 } else { $selectedIndex + 1 }
                        & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop
                    }
                    'D1' { $selectedIndex = 0; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'D2' { $selectedIndex = 1; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'D3' { $selectedIndex = 2; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'D4' { $selectedIndex = 3; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'NumPad1' { $selectedIndex = 0; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'NumPad2' { $selectedIndex = 1; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'NumPad3' { $selectedIndex = 2; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'NumPad4' { $selectedIndex = 3; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                    'Enter' {
                        $choice = [string]($selectedIndex + 1)
                        break menuLoop
                    }
                }
            }
        }
        catch {
            Write-Ui " Interactive key menu is unavailable. Using default mode." -Color Yellow
            $choice = [string]($selectedIndex + 1)
        }

        Write-Ui ""
        Write-Ui (" Selected profile: {0}" -f $presetTable[[int]$choice - 1].Name) -Color DarkGray

        switch ($choice) {
            '1' {
                Set-PresetOptions -Name 'basic' -Options $Options
                $Options.Preset = 'Basic'
                return $Options
            }
            '2' {
                Set-PresetOptions -Name 'full' -Options $Options
                $Options.Preset = 'Full'
                return $Options
            }
            '3' {
                Write-Ui ""
                Write-Ui "Custom options" -Color Cyan
                $Options.DetailedLog = Get-YesNoResponse "Detailed log file?" $Options.DetailedLog
                $Options.IncludeThumbnails = Get-YesNoResponse "Clean thumbnail cache?" $Options.IncludeThumbnails
                $Options.SkipThumbnails = -not $Options.IncludeThumbnails
                $Options.WhatIf = Get-YesNoResponse "Dry run only (no deletions)?" $Options.WhatIf
                foreach ($state in Get-OptionalCleanupOptionStates -Options $Options) {
                    $Options.$($state.OptionKey) = Get-YesNoResponse $state.Prompt $state.Enabled
                }
                $Options.DisableNotifications = -not (Get-YesNoResponse "Show completion notification?" (-not $Options.DisableNotifications))
                $Options.Preset = 'Custom'
                return $Options
            }
            '4' {
                Invoke-SettingsMenu -Options $Options -ConfigDefaults $ConfigDefaults -SettingsPath $SettingsPath
                $Options = Get-NormalizedOptions -Options $Options -FallbackPreset 'Basic'
                $ConfigDefaults = Get-NormalizedOptions -Options $ConfigDefaults -FallbackPreset 'Basic'
                continue mainMenu
            }
        }
    }
}

function Show-RunPlan {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][array]$Targets,
        [bool]$RunSystemTargets,
        [bool]$IsAdmin,
        [string]$SystemTargetSkipReason,
        [switch]$SkipConfirmation
    )

    Write-Section -Title "Run Plan"
    $runType = if ($Options.WhatIf) { "Dry run (simulation only)" } else { "Live cleanup (deletes files)" }
    $thumbMode = if ($Options.IncludeThumbnails) { "Clean thumbcache*.db" } elseif ($Options.SkipThumbnails) { "Skip thumbnails" } else { "Prompt during run" }
    $logMode = if ($Options.DetailedLog) { "Detailed" } else { "Standard" }
    $notifyMode = if ($Options.DisableNotifications) { "Off" } else { "On" }
    $privilegeMode = if ($IsAdmin) { "Administrator" } else { "Standard user" }

    Write-KeyValue -Key "Preset" -Value $Options.Preset -ValueColor Green
    Write-KeyValue -Key "Run type" -Value $runType -ValueColor $(if ($Options.WhatIf) { 'Cyan' } else { 'Yellow' })
    Write-KeyValue -Key "Thumbnails" -Value $thumbMode -ValueColor Gray
    Write-KeyValue -Key "Logging" -Value $logMode -ValueColor Gray
    Write-KeyValue -Key "Notify" -Value $notifyMode -ValueColor Gray
    Write-KeyValue -Key "Privileges" -Value $privilegeMode -ValueColor Gray
    Write-Ui ""
    Write-Ui (" Targets ({0}):" -f $Targets.Count) -Color Cyan

    foreach ($target in $Targets) {
        $tag = if ($target.RequiresAdmin) {
            if ($RunSystemTargets) { "SYSTEM" } else { "SKIP" }
        } else {
            "USER"
        }
        $color = if ($target.RequiresAdmin -and -not $RunSystemTargets) { 'DarkGray' } elseif ($target.RequiresAdmin) { 'Yellow' } else { 'Green' }
        $suffix = if ($target.RequiresAdmin -and -not $RunSystemTargets) {
            if ($SystemTargetSkipReason) { " ({0})" -f $SystemTargetSkipReason } else { " (skipped)" }
        } else { "" }
        Write-Ui ("  - [{0,-6}] {1}{2}" -f $tag, $target.Desc, $suffix) -Color $color
    }

    if ($SkipConfirmation) { return $true }
    return (Get-YesNoResponse "Start cleanup now?" $true)
}

function Show-DeletionPreview {
    param(
        [Parameter(Mandatory)][array]$ScanResults,
        [switch]$Simulate,
        [switch]$SkipConfirmation
    )

    $totalBytes = 0L
    $totalFiles = 0
    $heading = if ($Simulate) { 'Estimated Reclaimable (Dry Run)' } else { 'Estimated Reclaimable' }
    Write-Section -Title $heading
    Write-Ui (" {0,-32} {1,8} {2,14}" -f 'Target', 'Files', 'Est. Size') -Color DarkGray
    Write-Rule -Char '-' -Color DarkGray

    foreach ($scan in $ScanResults) {
        $name = if ($scan.Description.Length -gt 32) { $scan.Description.Substring(0, 32) } else { $scan.Description }
        if ($scan.PreResolvedResult -in @('Skipped', 'Failed', 'NothingToRemove')) {
            $note = if ($scan.PreResolvedNote) { $scan.PreResolvedNote } else { $scan.PreResolvedResult }
            $shortNote = if ($note.Length -gt 22) { $note.Substring(0, 22) } else { $note }
            Write-Ui (" {0,-32} {1,8} {2,14}" -f $name, '-', $shortNote) -Color DarkGray
            continue
        }
        $color = if ($scan.SizeBytes -gt 0) { 'Gray' } else { 'DarkGray' }
        Write-Ui (" {0,-32} {1,8} {2,14}" -f $name, $scan.FileItems.Count, (Format-Bytes -Bytes $scan.SizeBytes)) -Color $color
        $totalBytes += [long]$scan.SizeBytes
        $totalFiles += [int]$scan.FileItems.Count
    }

    Write-Rule -Char '-' -Color DarkGray
    Write-Ui (" {0,-32} {1,8} {2,14}" -f 'TOTAL', $totalFiles, (Format-Bytes -Bytes $totalBytes)) -Color Cyan

    if ($SkipConfirmation) { return $true }
    if ($Simulate) {
        Write-Ui ""
        Write-Ui " Dry-run preview only — no files will be deleted." -Color Cyan
        return $true
    }
    Write-Ui ""
    return (Get-YesNoResponse "Proceed with deletion?" $true)
}

function Show-RunSummary {
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Stats,
        [long]$FreedBytes,
        [long]$EstimatedBytes,
        [switch]$Simulate
    )

    $allStats = @($Stats)
    if ($allStats.Count -eq 0) { return }

    $cleanedCount = [int](($allStats | Where-Object { $_.Result -eq 'Cleaned' }).Count)
    $simCount = [int](($allStats | Where-Object { $_.Result -eq 'WhatIf' }).Count)
    $emptyCount = [int](($allStats | Where-Object { $_.Result -eq 'NothingToRemove' }).Count)
    $skippedCount = [int](($allStats | Where-Object { $_.Result -eq 'Skipped' }).Count)
    $partialCount = [int](($allStats | Where-Object { $_.Result -eq 'Partial' }).Count)
    $failedCount = [int](($allStats | Where-Object { $_.Result -eq 'Failed' }).Count)

    Write-Section -Title "Run Summary"
    Write-KeyValue -Key "Targets" -Value ("{0} processed" -f $allStats.Count) -ValueColor Gray
    Write-KeyValue -Key "Cleaned" -Value ([string]$cleanedCount) -ValueColor Green
    Write-KeyValue -Key "Simulated" -Value ([string]$simCount) -ValueColor Cyan
    Write-KeyValue -Key "Nothing" -Value ([string]$emptyCount) -ValueColor DarkGray
    Write-KeyValue -Key "Skipped" -Value ([string]$skippedCount) -ValueColor Yellow
    Write-KeyValue -Key "Partial" -Value ([string]$partialCount) -ValueColor Yellow
    Write-KeyValue -Key "Failed" -Value ([string]$failedCount) -ValueColor $(if ($failedCount -gt 0) { 'Red' } else { 'DarkGray' })
    if ($Simulate) {
        Write-KeyValue -Key "Potential" -Value (Format-Bytes -Bytes $EstimatedBytes) -ValueColor Cyan
    }
    else {
        Write-KeyValue -Key "Freed" -Value (Format-Bytes -Bytes $FreedBytes) -ValueColor Green
    }
}

function Show-AsciiProgress {
    param(
        [int]$Percent,
        [string]$Activity,
        [string]$Status,
        [switch]$SilentMode
    )
    if ($SilentMode) { return }
    $uiWidth = Get-UiWidth
    $width = [Math]::Min([Math]::Max(18, $uiWidth - 52), 40)
    $fillBlocks = [math]::Floor(($Percent / 100) * $width)
    if ($fillBlocks -lt 0) { $fillBlocks = 0 }
    if ($fillBlocks -gt $width) { $fillBlocks = $width }
    $bar = ('=' * $fillBlocks).PadRight($width, '.')
    $activityLabel = if ($Activity.Length -gt 22) { $Activity.Substring(0, 22) } else { $Activity }
    $statusText = if ($Status) { " $Status" } else { "" }
    $line = ("`r  {0,-22} [{1}] {2,3}%{3}" -f $activityLabel, $bar, [math]::Min([math]::Max($Percent, 0), 100), $statusText)
    $line = $line.PadRight([Math]::Max($uiWidth - 1, 80))
    Write-Host $line -NoNewline
    if ($Percent -ge 100) {
        Write-Host ""
    }
}

function Test-IsDangerousPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowedRoots
    )

    return ($null -ne (Get-PathSafetyIssue -Path $Path -AllowedRoots $AllowedRoots))
}

function Test-NameMatchesPatterns {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) {
            return $true
        }
    }
    return $false
}

function Write-TargetSummary {
    param([pscustomobject]$Stats)
    $bytesToShow = if ($Stats.Result -eq 'WhatIf') { $Stats.SizeBytes } elseif ($Stats.FreedBytes -gt 0) { $Stats.FreedBytes } else { $Stats.SizeBytes }
    $size = Format-Bytes -Bytes $bytesToShow
    $duration = "{0:N1}s" -f $Stats.Duration.TotalSeconds
    $name = if ($Stats.Description.Length -gt 28) { $Stats.Description.Substring(0, 28) } else { $Stats.Description }
    $notes = ""
    if ($Stats.Notes) {
        $noteText = [string]$Stats.Notes
        if ($noteText.Length -gt 42) {
            $noteText = $noteText.Substring(0, 39) + '...'
        }
        $notes = " | $noteText"
    }
    switch ($Stats.Result) {
        'Cleaned' { $icon = '[OK]'; $color = 'Green' }
        'WhatIf' { $icon = '[SIM]'; $color = 'Cyan' }
        'NothingToRemove' { $icon = '[NONE]'; $color = 'DarkGray' }
        'Partial' { $icon = '[WARN]'; $color = 'Yellow' }
        'Skipped' { $icon = '[SKIP]'; $color = 'Yellow' }
        'Failed' { $icon = '[ERR]'; $color = 'Red' }
        default { $icon = '[--]'; $color = 'Gray' }
    }
    Write-Ui (" {0} {1,-28} | {2,5} files | {3,5} dirs | {4,10} | {5,5}{6}" -f $icon, $name, $Stats.Files, $Stats.Folders, $size, $duration, $notes) -Color $color
}

function Invoke-UpdateCheck {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    if ($Options.SkipUpdateCheck) { return }
    if (-not $Options.UpdateFeed) { return }
    if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) { return }
    try {
        $timeout = 5
        if ($Options.PSObject.Properties.Name -contains 'UpdateTimeoutSec' -and $Options.UpdateTimeoutSec) {
            try {
                $timeout = [Math]::Max(1, [int]$Options.UpdateTimeoutSec)
            }
            catch {
                $timeout = 5
            }
        }
        $irmParams = @{
            Uri         = $Options.UpdateFeed
            ErrorAction = 'Stop'
            TimeoutSec  = $timeout
        }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $irmParams.UseBasicParsing = $true
        }
        $response = Invoke-RestMethod @irmParams
        if ($response.version) {
            $remoteVersion = [version]$response.version
            if ($remoteVersion -gt $script:Version) {
                Write-Ui ("Update available! Current {0}, Latest {1}" -f $script:Version, $remoteVersion) -Color Yellow
                if ($response.releaseNotes) {
                    Write-Ui "Release notes: $($response.releaseNotes)" -Color Yellow
                }
            }
            else {
                Write-Ui "You are running the latest version." -Color DarkGreen -VerboseOnly
            }
        }
    }
    catch {
        Write-Log "Update check failed: $($_.Exception.Message)"
        Write-Ui "Update check failed (see log for details)." -Color Yellow -VerboseOnly
    }
}

function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$SilentMode
    )
    if ($SilentMode) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("TempCleaner")
        $notifier.Show($toast)
    }
    catch {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shell.Popup($Message, 5, $Title, 64) | Out-Null
        }
        catch {
            Write-Log "Notification suppressed: $($_.Exception.Message)"
        }
    }
}

function Get-DeleteFailureKind {
    param(
        $Exception,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Exception -and $Exception.PSObject.Properties.Name -contains 'HResult') {
        if ([int]$Exception.HResult -eq -2147024864) {
            return 'Busy'
        }
    }

    if ($Message -match 'being used by another process|cannot access the file|used by another process') {
        return 'Busy'
    }

    return 'Error'
}

function Get-TargetIssueNote {
    param(
        [int]$BusyCount,
        [int]$OtherFailureCount,
        [int]$ScanErrorCount,
        [int]$ReparseSkipCount
    )

    $parts = @()
    if ($BusyCount -gt 0) {
        $parts += ("{0} busy/locked" -f $BusyCount)
    }
    if ($OtherFailureCount -gt 0) {
        $parts += ("{0} failed" -f $OtherFailureCount)
    }
    if ($ScanErrorCount -gt 0) {
        $parts += ("{0} scan issue(s)" -f $ScanErrorCount)
    }
    if ($ReparseSkipCount -gt 0) {
        $parts += ("{0} junction(s) skipped" -f $ReparseSkipCount)
    }

    if ($parts.Count -eq 0) {
        return ""
    }

    return ($parts -join ', ')
}

function Test-IsReparsePoint {
    param([Parameter(Mandatory)]$Item)
    if ($null -eq $Item) { return $false }
    if ($Item.PSObject.Properties.Name -notcontains 'Attributes') { return $false }
    return ([int]([IO.FileAttributes]::ReparsePoint) -band [int]$Item.Attributes) -ne 0
}

function New-FolderScanResult {
    param(
        [string]$Description,
        [string]$Path
    )
    return [pscustomobject]@{
        Description           = $Description
        Path                  = $Path
        Simulate              = $false
        DetailedLog           = $false
        SilentMode            = $false
        DetailedLogLimit      = 5000
        IncludePatterns       = @()
        NoRecurse             = $false
        SkipDirectoryDeletion = $false
        AllowedRoots          = @()
        FileItems             = @()
        FolderItems           = @()
        SizeBytes             = 0L
        ScanErrors            = @()
        ReparseSkipCount      = 0
        PreResolvedResult     = $null
        PreResolvedNote       = $null
        ScanDuration          = [timespan]::Zero
    }
}

function Invoke-FolderScan {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [switch]$Simulate,
        [switch]$DetailedLog,
        [switch]$SilentMode,
        [int]$DetailedLogLimit = 5000,
        [string[]]$IncludePatterns,
        [switch]$NoRecurse,
        [switch]$SkipDirectoryDeletion,
        [string[]]$AllowedRoots = @($script:AllowedCleanupRoots)
    )

    $scan = New-FolderScanResult -Description $Description -Path $Path
    $scan.Simulate              = [bool]$Simulate
    $scan.DetailedLog           = [bool]$DetailedLog
    $scan.SilentMode            = [bool]$SilentMode
    $scan.DetailedLogLimit      = $DetailedLogLimit
    $scan.IncludePatterns       = $IncludePatterns
    $scan.NoRecurse             = [bool]$NoRecurse
    $scan.SkipDirectoryDeletion = [bool]$SkipDirectoryDeletion
    $scan.AllowedRoots          = $AllowedRoots

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Ui "Skipping $Description (empty path)." -Color Yellow -VerboseOnly
        Write-Log "${Description}: Skipped (empty path)."
        $scan.PreResolvedResult = 'Skipped'
        $scan.PreResolvedNote = 'Empty path'
        $stopwatch.Stop()
        $scan.ScanDuration = $stopwatch.Elapsed
        return $scan
    }

    $pathSafetyIssue = Get-PathSafetyIssue -Path $Path -AllowedRoots $AllowedRoots
    if ($pathSafetyIssue) {
        Write-Ui "Skipping $Description (dangerous path: $Path)." -Color Red -VerboseOnly
        Write-Log "${Description}: Skipped unsafe path '$Path' ($pathSafetyIssue)."
        $scan.PreResolvedResult = 'Skipped'
        $scan.PreResolvedNote = $pathSafetyIssue
        $stopwatch.Stop()
        $scan.ScanDuration = $stopwatch.Elapsed
        return $scan
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Ui "Skipping $Description (missing path)." -Color Yellow -VerboseOnly
        Write-Log "${Description}: '$Path' does not exist."
        $scan.PreResolvedResult = 'Skipped'
        $scan.PreResolvedNote = 'Missing'
        $stopwatch.Stop()
        $scan.ScanDuration = $stopwatch.Elapsed
        return $scan
    }

    Write-Ui ""
    Write-Ui ("[TARGET] {0}" -f $Description) -Color Cyan
    Write-Ui "  Scanning files..." -Color DarkGray
    Write-Ui ("  {0}" -f $Path) -Color DarkGray -VerboseOnly

    $scanParams = @{
        LiteralPath = $Path
        Force       = $true
        ErrorAction = 'SilentlyContinue'
    }
    if (-not $NoRecurse) {
        $scanParams.Recurse = $true
    }

    $fileScanErrors = @()
    $folderScanErrors = @()
    $rawFileItems = @(Get-ChildItem @scanParams -File -ErrorVariable +fileScanErrors)

    $reparseFiles = @($rawFileItems | Where-Object { Test-IsReparsePoint -Item $_ })
    $fileItems = @($rawFileItems | Where-Object { -not (Test-IsReparsePoint -Item $_) })
    foreach ($r in $reparseFiles) {
        Write-Log ("{0}: Reparse-point file skipped: '{1}'" -f $Description, $r.FullName)
    }
    $scan.ReparseSkipCount += $reparseFiles.Count

    if ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
        $fileItems = @(
            $fileItems | Where-Object {
                Test-NameMatchesPatterns -Name $_.Name -Patterns $IncludePatterns
            }
        )
        $scan.SkipDirectoryDeletion = $true
    }

    $folderItems = @()
    if (-not $scan.SkipDirectoryDeletion) {
        $rawFolderItems = @(Get-ChildItem @scanParams -Directory -ErrorVariable +folderScanErrors)
        $reparseFolders = @($rawFolderItems | Where-Object { Test-IsReparsePoint -Item $_ })
        $folderItems = @($rawFolderItems | Where-Object { -not (Test-IsReparsePoint -Item $_) })
        foreach ($r in $reparseFolders) {
            $linkTarget = $null
            try { $linkTarget = (Get-Item -LiteralPath $r.FullName -Force -ErrorAction Stop).Target } catch { }
            $targetText = if ($linkTarget) { " -> $linkTarget" } else { "" }
            Write-Log ("{0}: Reparse-point directory skipped: '{1}'{2}" -f $Description, $r.FullName, $targetText)
        }
        $scan.ReparseSkipCount += $reparseFolders.Count
    }

    $scanErrors = @($fileScanErrors + $folderScanErrors)
    foreach ($scanError in $scanErrors) {
        Write-Log ("{0}: Scan issue at '{1}': {2}" -f $Description, $scanError.TargetObject, $scanError.Exception.Message)
    }

    $scan.FileItems   = $fileItems
    $scan.FolderItems = $folderItems
    $scan.SizeBytes   = [long](($fileItems | Measure-Object -Property Length -Sum).Sum)
    $scan.ScanErrors  = $scanErrors

    if ($DetailedLog) {
        $limit = [Math]::Max(1, $DetailedLogLimit)
        $logLines = [System.Collections.Generic.List[string]]::new()
        $logLines.Add("${Description}: Entries in '$Path' (up to $limit):") | Out-Null
        $loggedCount = 0
        foreach ($item in $fileItems) {
            if ($loggedCount -ge $limit) { break }
            $logLines.Add("    $($item.FullName)") | Out-Null
            $loggedCount++
        }
        foreach ($item in $folderItems) {
            if ($loggedCount -ge $limit) { break }
            $logLines.Add("    $($item.FullName)") | Out-Null
            $loggedCount++
        }
        $totalItems = $fileItems.Count + $folderItems.Count
        $remaining = $totalItems - $loggedCount
        if ($remaining -gt 0) {
            $logLines.Add("    ... and $remaining more entries (log limit reached).") | Out-Null
        }
        Write-LogBatch -Messages $logLines
    }
    else {
        Write-Log ("{0}: {1} files, {2} folders, {3} total." -f $Description, $fileItems.Count, $folderItems.Count, (Format-Bytes -Bytes $scan.SizeBytes))
    }

    if ($fileItems.Count -eq 0 -and $folderItems.Count -eq 0) {
        if ($scanErrors.Count -gt 0) {
            Write-Log "${Description}: Scan failed before any removable entries were identified."
            $scan.PreResolvedResult = 'Failed'
            $scan.PreResolvedNote = Get-TargetIssueNote -BusyCount 0 -OtherFailureCount 0 -ScanErrorCount $scanErrors.Count -ReparseSkipCount $scan.ReparseSkipCount
        }
        else {
            Write-Log "${Description}: Nothing to remove."
            $scan.PreResolvedResult = 'NothingToRemove'
            $scan.PreResolvedNote = if ($scan.ReparseSkipCount -gt 0) {
                Get-TargetIssueNote -BusyCount 0 -OtherFailureCount 0 -ScanErrorCount 0 -ReparseSkipCount $scan.ReparseSkipCount
            } else {
                'Nothing to remove'
            }
        }
        $stopwatch.Stop()
        $scan.ScanDuration = $stopwatch.Elapsed
        return $scan
    }

    Write-Ui ("  Found {0} files and {1} folders (~{2})." -f $fileItems.Count, $folderItems.Count, (Format-Bytes -Bytes $scan.SizeBytes)) -Color Gray
    if ($scan.ReparseSkipCount -gt 0) {
        Write-Ui ("  Skipping {0} reparse point(s); see log." -f $scan.ReparseSkipCount) -Color Yellow -VerboseOnly
    }

    $stopwatch.Stop()
    $scan.ScanDuration = $stopwatch.Elapsed
    return $scan
}

function Invoke-FolderDeletion {
    param(
        [Parameter(Mandatory)][pscustomobject]$Scan
    )

    $stats = [pscustomobject]@{
        Description = $Scan.Description
        Path        = $Scan.Path
        Files       = $Scan.FileItems.Count
        Folders     = $Scan.FolderItems.Count
        SizeBytes   = $Scan.SizeBytes
        FreedBytes  = 0
        Result      = if ($Scan.Simulate) { "WhatIf" } else { "Pending" }
        Duration    = $Scan.ScanDuration
        Notes       = ""
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Scan.PreResolvedResult) {
            $stats.Result = $Scan.PreResolvedResult
            $stats.Notes  = $Scan.PreResolvedNote
            return
        }

        if ($Scan.Simulate) {
            Write-Log "$($Scan.Description): WhatIf - no deletion performed."
            if ($Scan.ScanErrors.Count -gt 0 -or $Scan.ReparseSkipCount -gt 0) {
                $stats.Result = "Partial"
                $stats.Notes = Get-TargetIssueNote -BusyCount 0 -OtherFailureCount 0 -ScanErrorCount $Scan.ScanErrors.Count -ReparseSkipCount $Scan.ReparseSkipCount
            }
            return
        }

        $toDelete = @($Scan.FileItems + ($Scan.FolderItems | Sort-Object FullName -Descending))
        $totalCount = $toDelete.Count

        $useProgress = (-not $Scan.SilentMode) -and ($totalCount -ge 100)
        if (-not $Scan.SilentMode) {
            if ($useProgress) {
                Write-Ui "  Deleting..." -Color DarkGray
            }
            else {
                Write-Ui ("  Deleting {0} entries..." -f $totalCount) -Color DarkGray
            }
        }

        $processed = 0
        $failedEntries = [System.Collections.Generic.List[pscustomobject]]::new()
        $busyCount = 0
        $otherFailureCount = 0
        $progressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        foreach ($entry in $toDelete) {
            $processed++
            if ($useProgress) {
                $percent = if ($totalCount -eq 0) { 100 } else { [math]::Round(($processed / $totalCount) * 100, 0) }
                $shouldUpdate = $processed -eq 1 -or $processed -eq $totalCount -or $processed % 200 -eq 0 -or $progressStopwatch.ElapsedMilliseconds -ge 250
                if ($shouldUpdate) {
                    $shortName = Split-Path -Leaf $entry.FullName
                    if ($shortName.Length -gt 20) { $shortName = $shortName.Substring(0, 17) + '...' }
                    Show-AsciiProgress -Percent $percent -Activity $Scan.Description -Status ("{0}/{1} {2}" -f $processed, $totalCount, $shortName) -SilentMode:$Scan.SilentMode
                    $progressStopwatch.Restart()
                }
            }
            try {
                $removeParams = @{
                    LiteralPath = $entry.FullName
                    Force       = $true
                    ErrorAction = 'Stop'
                    Confirm     = $false
                }
                if ($entry.PSIsContainer) {
                    $removeParams.Recurse = $true
                }
                Remove-Item @removeParams
                if (-not $entry.PSIsContainer -and $entry.PSObject.Properties.Name -contains 'Length' -and $entry.Length) {
                    $stats.FreedBytes += [long]$entry.Length
                }
            }
            catch {
                $failureKind = Get-DeleteFailureKind -Exception $_.Exception -Message $_.Exception.Message
                $failedEntries.Add([pscustomobject]@{
                        Path   = $entry.FullName
                        Reason = $_.Exception.Message
                    }) | Out-Null
                Write-Log "$($Scan.Description): Failed to delete '$($entry.FullName)': $($_.Exception.Message)"
                if ($failureKind -eq 'Busy') {
                    $busyCount++
                }
                else {
                    $otherFailureCount++
                }
            }
        }
        if ($failedEntries.Count -gt 0 -or $Scan.ScanErrors.Count -gt 0 -or $Scan.ReparseSkipCount -gt 0) {
            $issueNote = Get-TargetIssueNote -BusyCount $busyCount -OtherFailureCount $otherFailureCount -ScanErrorCount $Scan.ScanErrors.Count -ReparseSkipCount $Scan.ReparseSkipCount
            if ($failedEntries.Count -gt 0 -or $Scan.ScanErrors.Count -gt 0) {
                Write-Log ("{0}: Completed with warnings - {1}" -f $Scan.Description, $issueNote)
                $stats.Result = "Partial"
            }
            else {
                Write-Log ("{0}: Files deleted successfully ({1})." -f $Scan.Description, $issueNote)
                $stats.Result = "Cleaned"
            }
            $stats.Notes = $issueNote
        }
        else {
            Write-Log "$($Scan.Description): Files deleted successfully."
            $stats.Result = "Cleaned"
        }
    }
    catch {
        Write-Ui "Failed to delete some files in $($Scan.Description)." -Color Red
        Write-Log "$($Scan.Description): Failed - $($_.Exception.Message)"
        $stats.Result = "Failed"
        $stats.Notes = $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
        $stats.Duration = $Scan.ScanDuration + $stopwatch.Elapsed
        $script:RunStats.Add($stats)
        Write-TargetSummary -Stats $stats
    }
}

function Clear-Folder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [switch]$Simulate,
        [switch]$DetailedLog,
        [switch]$SilentMode,
        [int]$DetailedLogLimit = 5000,
        [string[]]$IncludePatterns,
        [switch]$NoRecurse,
        [switch]$SkipDirectoryDeletion,
        [string[]]$AllowedRoots = @($script:AllowedCleanupRoots)
    )

    $scan = Invoke-FolderScan -Path $Path -Description $Description -Simulate:$Simulate -DetailedLog:$DetailedLog -SilentMode:$SilentMode -DetailedLogLimit $DetailedLogLimit -IncludePatterns $IncludePatterns -NoRecurse:$NoRecurse -SkipDirectoryDeletion:$SkipDirectoryDeletion -AllowedRoots $AllowedRoots
    Invoke-FolderDeletion -Scan $scan
}

function Show-CompletionBanner {
    param(
        [long]$FreedBytes,
        [long]$PotentialBytes,
        [timespan]$TotalDuration,
        [int]$WarningCount,
        [switch]$Simulate
    )
    $spaceLabel = if ($Simulate) {
        if ($PotentialBytes -gt 0) { "could free $(Format-Bytes -Bytes $PotentialBytes)" } else { "no reclaimable files found" }
    }
    else {
        if ($FreedBytes -gt 0) { "freed $(Format-Bytes -Bytes $FreedBytes)" } else { "freed 0 MB" }
    }
    $durationLabel = "{0:N1}s" -f $TotalDuration.TotalSeconds
    $warnLabel = if ($WarningCount -gt 0) { "$WarningCount warning(s)" } else { "none" }
    $bannerColor = if ($WarningCount -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
    $title = if ($Simulate) { "[SIM] Simulation complete" } else { "[OK] Cleanup complete" }
    Write-Ui ""
    Write-Rule -Char '=' -Color DarkGray
    Write-Ui (" {0}" -f $title) -Color $bannerColor
    Write-KeyValue -Key "Result" -Value $spaceLabel -ValueColor Gray
    Write-KeyValue -Key "Duration" -Value $durationLabel -ValueColor Gray
    Write-KeyValue -Key "Warnings" -Value $warnLabel -ValueColor $(if ($WarningCount -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Rule -Char '=' -Color DarkGray
}

function Start-ElevatedRelaunch {
    param([Parameter(Mandatory)][pscustomobject]$Options)

    if (Test-IsAdministrator) { return $true }
    Write-Ui "Requesting administrator privileges..." -Color Yellow
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $elevationOptionsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("TempCleaner_options_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $Options | ConvertTo-Json -Depth 6 | Set-Content -Path $elevationOptionsPath -Encoding UTF8

    $quotedScriptPath = '"{0}"' -f $PSCommandPath.Replace('"', '""')
    $quotedOptionsPath = '"{0}"' -f $elevationOptionsPath.Replace('"', '""')
    $launchArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $quotedScriptPath,
        '-OptionsImportPath',
        $quotedOptionsPath
    )
    try {
        Start-Process -FilePath $exe -ArgumentList $launchArgs -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $elevationOptionsPath) {
            Remove-Item -LiteralPath $elevationOptionsPath -Force -ErrorAction SilentlyContinue
        }
        Write-Ui "Elevation was canceled or unavailable." -Color Yellow
        return $false
    }
}

function Invoke-TempCleaner {
    $script:RunStats.Clear()

    $defaultOptions = New-DefaultOptions
    $cliOverrides = Get-OptionOverridesFromBoundParameters -BoundParameters $script:CliBoundParameters

    $resolvedConfigPath = if ($script:CliBoundParameters.ContainsKey('ConfigPath') -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        [Environment]::ExpandEnvironmentVariables($ConfigPath)
    }
    else {
        $script:DefaultConfigPath
    }

    $configStatus = [pscustomobject]@{
        Path    = $resolvedConfigPath
        Loaded  = $false
        Message = ''
    }

    $configOptions = $null
    $configParseFailed = $false
    if (-not [string]::IsNullOrWhiteSpace($resolvedConfigPath) -and (Test-Path -LiteralPath $resolvedConfigPath)) {
        try {
            $configOptions = Read-OptionsFile -Path $resolvedConfigPath
            $configStatus.Loaded = $true
            $configStatus.Message = 'Loaded'
        }
        catch {
            $configStatus.Message = $_.Exception.Message
            $configParseFailed = $true
            Write-LogPending "Config parse failure at '${resolvedConfigPath}': $($_.Exception.Message)"
        }
    }
    elseif ($script:CliBoundParameters.ContainsKey('ConfigPath')) {
        $configStatus.Message = 'Config file not found'
    }
    else {
        $configStatus.Message = 'Not found'
    }

    $importOptions = $null
    $importStatusMessage = ''
    $hasImportedOptions = -not [string]::IsNullOrWhiteSpace($OptionsImportPath)
    if ($hasImportedOptions) {
        if (Test-Path -LiteralPath $OptionsImportPath) {
            try {
                $importOptions = Read-OptionsFile -Path $OptionsImportPath
                $importStatusMessage = 'Loaded'
            }
            catch {
                $importStatusMessage = $_.Exception.Message
            }
            finally {
                Remove-Item -LiteralPath $OptionsImportPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $importStatusMessage = 'Handoff file not found'
        }
    }

    $configDefaults = Resolve-Options -DefaultOptions $defaultOptions -ConfigOptions $configOptions -CliOverrides ([pscustomobject]@{}) -ImportOptions $null
    $options = Resolve-Options -DefaultOptions $defaultOptions -ConfigOptions $configOptions -CliOverrides $cliOverrides -ImportOptions $importOptions

    if ($configParseFailed) {
        Write-Ui ("Config file could not be parsed: {0}" -f $resolvedConfigPath) -Color Red
        Write-Ui ("  {0}" -f $configStatus.Message) -Color Red
        if ($options.Silent -or $hasImportedOptions) {
            Write-LogPending "Continuing with default settings (silent or handoff mode)."
        }
        else {
            if (-not (Get-YesNoResponse "Continue with default settings?" $false)) {
                Write-Ui "Aborted by user due to config parse failure." -Color Yellow
                return 1
            }
            Write-LogPending "User confirmed continuing with default settings after config parse failure."
        }
    }

    if ($options.Silent -or $hasImportedOptions) {
        if ($options.Preset -in @('Basic', 'Full')) {
            Set-PresetOptions -Name $options.Preset -Options $options
            $options = Restore-ExplicitOptionOverrides -Options $options -CliOverrides $cliOverrides -ImportOptions $importOptions
            $options = Get-NormalizedOptions -Options $options -FallbackPreset $defaultOptions.Preset
        }
    }

    if (-not $options.Silent -and -not $hasImportedOptions) {
        $options = Invoke-ModeMenu -Options $options -ConfigDefaults $configDefaults -SettingsPath $resolvedConfigPath
        $options = Get-NormalizedOptions -Options $options -FallbackPreset $defaultOptions.Preset
        $configDefaults = Get-NormalizedOptions -Options $configDefaults -FallbackPreset $defaultOptions.Preset
    }

    $script:IsSilent = $options.Silent

    $targets = Get-RunTargets -Options $options
    $thumbnailCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $script:AllowedCleanupRoots = @($targets | ForEach-Object { $_.Path })

    $isAdmin = Test-IsAdministrator
    $executionPlan = Get-ExecutionPlan -IsAdmin:$isAdmin -Options $options -HasImportedOptions:$hasImportedOptions
    if ($executionPlan.ShouldAttemptElevation) {
        if (Start-ElevatedRelaunch -Options $options) {
            return 0
        }
        $executionPlan = Get-ExecutionPlan -IsAdmin:$false -Options $options -HasImportedOptions:$true
        Write-Ui "Continuing without elevation. System targets will be skipped." -Color Yellow
    }

    $runSystemTargets = $executionPlan.RunSystemTargets

    if (-not (Test-Path -LiteralPath $script:LogRoot)) {
        New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    }

    $rotationResult = Invoke-LogRotation -LogRoot $script:LogRoot -KeepCount $options.LogRetentionCount -MaxAgeDays $options.LogRetentionDays

    $logFile = Join-Path $script:LogRoot ("cleanup_{0}.log" -f $script:RunTimestamp)
    $script:ActiveLogFile = $logFile
    Set-Content -LiteralPath $logFile -Value @() -Encoding UTF8

    Write-Log ("Log rotation: deleted {0}, kept {1} (retention: count={2}, days={3})" -f $rotationResult.Deleted, $rotationResult.Kept, $options.LogRetentionCount, $options.LogRetentionDays)
    if ($rotationResult.Deleted -gt 0) {
        Write-Ui ("Rotated logs: removed {0} old file(s)." -f $rotationResult.Deleted) -Color DarkGray -VerboseOnly
    }
    Write-Log "Cleanup started at $(Get-Date)"
    Write-Log "Running as user: $env:USERNAME"
    Write-Log "Config path: $resolvedConfigPath"
    Write-Log "Config status: $($configStatus.Message)"
    if ($hasImportedOptions) {
        Write-Log "Relaunch handoff: $importStatusMessage"
    }
    Write-Log "Privileges: $(if ($isAdmin) { 'Administrator' } else { 'Standard user' })"
    if (-not $runSystemTargets -and $executionPlan.SystemTargetSkipReason) {
        Write-Log "System targets skipped: $($executionPlan.SystemTargetSkipReason)"
    }
    Write-Log "Options: $(($options | ConvertTo-Json -Depth 3))"
    Write-Log "----------------------------------------"

    Show-Header
    if (-not $configParseFailed -and $configStatus.Message -and $configStatus.Message -notin @('Loaded', 'Not found')) {
        Write-Ui "Config warning: $($configStatus.Message)" -Color Yellow
    }

    if (-not $options.SkipUpdateCheck) {
        Invoke-UpdateCheck -Options $options
    }
    else {
        Write-Log "Update check skipped."
    }

    Write-Ui ("Cleanup started at {0}" -f (Get-Date)) -Color DarkGray -VerboseOnly
    if (-not $options.Silent) {
        $skipPlanConfirm = $hasImportedOptions
        $approved = Show-RunPlan -Options $options -Targets $targets -RunSystemTargets:$runSystemTargets -IsAdmin:$isAdmin -SystemTargetSkipReason $executionPlan.SystemTargetSkipReason -SkipConfirmation:$skipPlanConfirm
        if (-not $approved) {
            Write-Ui ""
            Write-Ui "Cleanup canceled before execution." -Color Yellow
            Write-Log "Cleanup canceled before execution."
            Write-Ui "Press any key to exit..."
            [void][System.Console]::ReadKey($true)
            return 0
        }
        Write-Section -Title "Cleaning Targets"
    }

    $scans = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        if ($t.RequiresAdmin -and -not $runSystemTargets) {
            Write-Log ("{0}: Skipped - {1}" -f $t.Desc, $executionPlan.SystemTargetSkipReason)
            $skipScan = New-FolderScanResult -Description $t.Desc -Path $t.Path
            $skipScan.PreResolvedResult = 'Skipped'
            $skipScan.PreResolvedNote = $executionPlan.SystemTargetSkipReason
            $skipScan.SilentMode = [bool]$options.Silent
            $skipScan.Simulate = [bool]$options.WhatIf
            $scans.Add($skipScan) | Out-Null
            continue
        }
        $scan = Invoke-FolderScan -Path $t.Path -Description $t.Desc -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -DetailedLogLimit $options.DetailedLogLimit -SilentMode:$options.Silent -AllowedRoots $script:AllowedCleanupRoots
        $scans.Add($scan) | Out-Null
    }

    if (-not $options.Silent -and $scans.Count -gt 0) {
        $proceed = Show-DeletionPreview -ScanResults @($scans) -Simulate:$options.WhatIf
        if (-not $proceed) {
            Write-Ui ""
            Write-Ui "Cleanup canceled at deletion preview." -Color Yellow
            Write-Log "Cleanup canceled at deletion preview."
            Write-Ui "Press any key to exit..."
            [void][System.Console]::ReadKey($true)
            return 0
        }
    }

    foreach ($scan in $scans) {
        Invoke-FolderDeletion -Scan $scan
    }

    Write-Ui ""
    $cleanThumbs = $false
    if ($options.IncludeThumbnails) {
        $cleanThumbs = $true
    }
    elseif ($options.SkipThumbnails) {
        Write-Log "Thumbnail Cache: Skipped by preference."
        Write-Ui "Thumbnail cache skipped." -Color DarkGray -VerboseOnly
    }
    elseif (-not $options.Silent) {
        $cleanThumbs = Get-YesNoResponse "Clear Explorer thumbnail cache? (Explorer may restart)" $false
    }

    if ($cleanThumbs) {
        Write-Ui ""
        $restartExplorer = $false
        try {
            if ($options.WhatIf) {
                Write-Ui "WhatIf: would stop Explorer..." -Color Cyan
                Write-Log "Thumbnail Cache: WhatIf - Explorer not stopped."
            }
            else {
                $explorerRunning = @(Get-Process explorer -ErrorAction SilentlyContinue).Count -gt 0
                if ($explorerRunning) {
                    Write-Ui "Stopping Explorer..." -Color DarkGray
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    $restartExplorer = $true
                    Write-Log "Thumbnail Cache: Explorer stopped."
                }
                else {
                    Write-Log "Thumbnail Cache: Explorer was not running."
                }
            }

            Clear-Folder -Path $thumbnailCachePath -Description "Thumbnail Cache (thumbcache*.db)" -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -DetailedLogLimit $options.DetailedLogLimit -SilentMode:$options.Silent -IncludePatterns @('thumbcache*.db') -NoRecurse -SkipDirectoryDeletion -AllowedRoots @($script:AllowedCleanupRoots + $thumbnailCachePath)
        }
        finally {
            if ($options.WhatIf) {
                Write-Ui "WhatIf: would restart Explorer..." -Color Cyan
                Write-Log "Thumbnail Cache: WhatIf - Explorer not restarted."
            }
            elseif ($restartExplorer) {
                Write-Ui "Restarting Explorer..." -Color DarkGray
                try {
                    Start-Process explorer.exe | Out-Null
                    Write-Log "Thumbnail Cache: Explorer restarted."
                }
                catch {
                    Write-Ui "Explorer restart failed. See log for details." -Color Yellow
                    Write-Log "Thumbnail Cache: Failed to restart Explorer: $($_.Exception.Message)"
                }
            }
        }
    }

    $freedBytes = 0
    $estimatedBytes = 0
    $totalDuration = [timespan]::Zero
    $warningCount = 0
    if ($script:RunStats.Count -gt 0) {
        $freedBytes = ($script:RunStats | Measure-Object -Property FreedBytes -Sum).Sum
        $estimatedBytes = ($script:RunStats | Measure-Object -Property SizeBytes -Sum).Sum
        $totalSeconds = ($script:RunStats | ForEach-Object { $_.Duration.TotalSeconds } | Measure-Object -Sum).Sum
        $totalDuration = [timespan]::FromSeconds($totalSeconds)
        $warningCount = ($script:RunStats | Where-Object { $_.Result -in @('Partial', 'Failed') }).Count
        Show-RunSummary -Stats $script:RunStats -FreedBytes $freedBytes -EstimatedBytes $estimatedBytes -Simulate:$options.WhatIf
        if (-not $script:IsSilent -and $VerbosePreference -ne 'SilentlyContinue') {
            $script:RunStats |
                Select-Object Description, Result, Files, Folders, @{Name = "Size"; Expression = { Format-Bytes -Bytes $_.SizeBytes } } |
                Format-Table -AutoSize
        }
    }

    Write-Log "Cleanup completed at $(Get-Date)"
    Write-Ui ""
    Write-Ui ("Cleanup completed. Log: {0}" -f $logFile)

    if ($script:RunStats.Count -gt 0) {
        Show-CompletionBanner -FreedBytes $freedBytes -PotentialBytes $estimatedBytes -TotalDuration $totalDuration -WarningCount $warningCount -Simulate:$options.WhatIf
    }

    if (-not $options.DisableNotifications -and $script:RunStats.Count -gt 0) {
        if ($options.WhatIf) {
            $msg = if ($estimatedBytes -gt 0) { "Could free $(Format-Bytes -Bytes $estimatedBytes)" } else { "Simulation finished." }
        }
        else {
            $msg = if ($freedBytes -gt 0) { "Freed $(Format-Bytes -Bytes $freedBytes)" } else { "Cleanup run finished." }
        }
        Send-Notification -Title "TempCleaner" -Message $msg -SilentMode:$options.Silent
    }

    if (-not $options.Silent) {
        Write-Ui "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }

    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-TempCleaner)
}
