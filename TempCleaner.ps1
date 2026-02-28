<#
.SYNOPSIS
  Cleans common Windows temp/cache folders with optional presets.
.DESCRIPTION
  Runs a safe cleanup pass for user/system temp locations, with per-run logs
  and optional thumbnail-cache cleanup. Interactive mode shows a simple menu.
.EXAMPLE
  .\TempCleaner.ps1
#>
[CmdletBinding()]
param(
    [string]$OptionsImportPath
)

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogRoot = Join-Path $script:AppRoot 'logs'
$script:RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Version = [version]'0.5.0'
$script:DefaultUpdateFeed = "https://raw.githubusercontent.com/ardai/TempCleaner/main/version.json"
$script:RunStats = [System.Collections.Generic.List[pscustomobject]]::new()
$script:ActiveLogFile = $null
$script:IsSilent = $false

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $script:ActiveLogFile) { return }
    $logDirectory = Split-Path -Parent $script:ActiveLogFile
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $script:ActiveLogFile -Value "[$timestamp] $Message"
}

function Write-LogBatch {
    param(
        [Parameter(Mandatory)][string[]]$Messages
    )
    if (-not $script:ActiveLogFile) { return }
    if (-not $Messages -or $Messages.Count -eq 0) { return }

    $logDirectory = Split-Path -Parent $script:ActiveLogFile
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

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
    Write-KeyValue -Key "Safety" -Value "Root paths blocked, admin required" -ValueColor DarkGray
    Write-Rule -Char '=' -Color DarkCyan
    Write-Ui ""
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        SkipUpdateCheck      = ConvertTo-SettingBool -Value $Options.SkipUpdateCheck -Default $false
        UpdateTimeoutSec     = [Math]::Max(1, (ConvertTo-SettingInt -Value $Options.UpdateTimeoutSec -Default 5))
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

function Invoke-ModeMenu {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    $presetTable = @(
        [pscustomobject]@{ Id = 1; Name = "Basic";  Description = "Fast cleanup (skip thumbnails)." },
        [pscustomobject]@{ Id = 2; Name = "Full";   Description = "Everything + thumbnails + detailed log." },
        [pscustomobject]@{ Id = 3; Name = "Custom"; Description = "Pick options one by one." }
    )

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
            $label = "{0,-6} {1}" -f $row.Name.ToUpperInvariant(), $row.Description
            $marker = if ($i -eq $ActiveIndex) { '>' } else { ' ' }
            $line = (" {0} [{1}] {2}" -f $marker, $row.Id, $label).PadRight($menuWidth)
            $color = switch ($row.Name) {
                'Basic' { 'Green' }
                'Full' { 'Yellow' }
                'Custom' { 'Cyan' }
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
                'NumPad1' { $selectedIndex = 0; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                'NumPad2' { $selectedIndex = 1; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
                'NumPad3' { $selectedIndex = 2; & $renderMenu -ActiveIndex $selectedIndex -MenuTop $menuTop }
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
        '1' { Set-PresetOptions -Name 'basic' -Options $Options; $Options.Preset = 'Basic' }
        '2' { Set-PresetOptions -Name 'full' -Options $Options; $Options.Preset = 'Full' }
        '3' {
            Write-Ui ""
            Write-Ui "Custom options" -Color Cyan
            $Options.DetailedLog = Get-YesNoResponse "Detailed log file?" $Options.DetailedLog
            $Options.IncludeThumbnails = Get-YesNoResponse "Clean thumbnail cache?" $Options.IncludeThumbnails
            $Options.SkipThumbnails = -not $Options.IncludeThumbnails
            $Options.WhatIf = Get-YesNoResponse "Dry run only (no deletions)?" $Options.WhatIf
            $Options.DisableNotifications = -not (Get-YesNoResponse "Show completion notification?" (-not $Options.DisableNotifications))
            $Options.Preset = 'Custom'
        }
    }
    return $Options
}

function Show-RunPlan {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][array]$Targets,
        [bool]$RunSystemTargets,
        [bool]$IsAdmin,
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
        $suffix = if ($target.RequiresAdmin -and -not $RunSystemTargets) { " (needs elevation)" } else { "" }
        Write-Ui ("  - [{0,-6}] {1}{2}" -f $tag, $target.Desc, $suffix) -Color $color
    }

    if ($SkipConfirmation) { return $true }
    return (Get-YesNoResponse "Start cleanup now?" $true)
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

    $cleanedCount = ($allStats | Where-Object { $_.Result -eq 'Cleaned' }).Count
    $simCount = ($allStats | Where-Object { $_.Result -eq 'WhatIf' }).Count
    $skippedCount = ($allStats | Where-Object { $_.Result -eq 'Skipped' }).Count
    $partialCount = ($allStats | Where-Object { $_.Result -eq 'Partial' }).Count
    $failedCount = ($allStats | Where-Object { $_.Result -eq 'Failed' }).Count

    Write-Section -Title "Run Summary"
    Write-KeyValue -Key "Targets" -Value ("{0} processed" -f $allStats.Count) -ValueColor Gray
    Write-KeyValue -Key "Cleaned" -Value ([string]$cleanedCount) -ValueColor Green
    Write-KeyValue -Key "Simulated" -Value ([string]$simCount) -ValueColor Cyan
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
    param([Parameter(Mandatory)][string]$Path)

    $trimmedPath = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) { return $true }
    if ($trimmedPath -in @('\', '/')) { return $true }

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($trimmedPath)
        $normalized = [System.IO.Path]::GetFullPath($expanded)
        $root = [System.IO.Path]::GetPathRoot($normalized)
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        if ($normalized.TrimEnd('\') -ieq $root.TrimEnd('\')) { return $true }
        if ($normalized -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?$') { return $true }
        return $false
    }
    catch {
        if ($trimmedPath -match '^[A-Za-z]:\\?$') { return $true }
        return $false
    }
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

function Add-SkippedTargetResult {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason
    )

    $stats = [pscustomobject]@{
        Description = $Description
        Path        = $Path
        Files       = 0
        Folders     = 0
        SizeBytes   = 0
        FreedBytes  = 0
        Result      = "Skipped"
        Duration    = [timespan]::Zero
        Notes       = $Reason
    }
    Write-Log ("{0}: Skipped - {1}" -f $Description, $Reason)
    $script:RunStats.Add($stats)
    Write-TargetSummary -Stats $stats
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
        [switch]$SkipDirectoryDeletion
    )

    $stats = [pscustomobject]@{
        Description = $Description
        Path        = $Path
        Files       = 0
        Folders     = 0
        SizeBytes   = 0
        FreedBytes  = 0
        Result      = if ($Simulate) { "WhatIf" } else { "Pending" }
        Duration    = [timespan]::Zero
        Notes       = ""
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Write-Ui "Skipping $Description (empty path)." -Color Yellow -VerboseOnly
            Write-Log "${Description}: Skipped (empty path)."
            $stats.Result = "Skipped"
            $stats.Notes = "Empty path"
            return
        }

        if (Test-IsDangerousPath -Path $Path) {
            Write-Ui "Skipping $Description (dangerous path: $Path)." -Color Red -VerboseOnly
            Write-Log "${Description}: Skipped dangerous path '$Path'."
            $stats.Result = "Skipped"
            $stats.Notes = "Dangerous path"
            return
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Ui "Skipping $Description (missing path)." -Color Yellow -VerboseOnly
            Write-Log "${Description}: '$Path' does not exist."
            $stats.Result = "Skipped"
            $stats.Notes = "Missing"
            return
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

        $fileItems = @(Get-ChildItem @scanParams -File)
        if ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
            $fileItems = @(
                $fileItems | Where-Object {
                    Test-NameMatchesPatterns -Name $_.Name -Patterns $IncludePatterns
                }
            )
            $SkipDirectoryDeletion = $true
        }

        $folderItems = @()
        if (-not $SkipDirectoryDeletion) {
            $folderItems = @(Get-ChildItem @scanParams -Directory)
        }

        $stats.Files = $fileItems.Count
        $stats.Folders = $folderItems.Count
        $stats.SizeBytes = ($fileItems | Measure-Object -Property Length -Sum).Sum
        $stats.FreedBytes = if ($Simulate) { 0 } else { $stats.SizeBytes }

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
            Write-Log ("{0}: {1} files, {2} folders, {3} total." -f $Description, $stats.Files, $stats.Folders, (Format-Bytes -Bytes $stats.SizeBytes))
        }

        if ($stats.Files -eq 0 -and $stats.Folders -eq 0) {
            Write-Log "${Description}: Nothing to remove."
            $stats.Result = if ($Simulate) { "WhatIf" } else { "Skipped" }
            $stats.Notes = "Nothing to remove"
            return
        }

        Write-Ui ("  Found {0} files and {1} folders (~{2})." -f $stats.Files, $stats.Folders, (Format-Bytes -Bytes $stats.SizeBytes)) -Color Gray

        if ($Simulate) {
            Write-Log "${Description}: WhatIf - no deletion performed."
            return
        }

        Write-Ui "  Deleting..." -Color DarkGray

        $toDelete = @($fileItems + ($folderItems | Sort-Object FullName -Descending))
        $totalCount = $toDelete.Count
        $processed = 0
        $failedEntries = [System.Collections.Generic.List[pscustomobject]]::new()
        $progressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        foreach ($entry in $toDelete) {
            $processed++
            $percent = if ($totalCount -eq 0) { 100 } else { [math]::Round(($processed / $totalCount) * 100, 0) }
            if (-not $SilentMode) {
                $shouldUpdate = $processed -eq 1 -or $processed -eq $totalCount -or $processed % 200 -eq 0 -or $progressStopwatch.ElapsedMilliseconds -ge 250
                if ($shouldUpdate) {
                    Show-AsciiProgress -Percent $percent -Activity $Description -Status ("{0}/{1}" -f $processed, $totalCount) -SilentMode:$SilentMode
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
            }
            catch {
                $failedEntries.Add([pscustomobject]@{
                        Path   = $entry.FullName
                        Reason = $_.Exception.Message
                    }) | Out-Null
                Write-Log "${Description}: Failed to delete '$($entry.FullName)': $($_.Exception.Message)"
                if (-not $entry.PSIsContainer -and $entry.PSObject.Properties.Name -contains 'Length' -and $entry.Length) {
                    $stats.FreedBytes = [math]::Max([long]0, ($stats.FreedBytes - [long]$entry.Length))
                }
            }
        }
        if ($failedEntries.Count -gt 0) {
            Write-Log "${Description}: Completed with warnings - $($failedEntries.Count) item(s) skipped."
            $stats.Result = "Partial"
            $stats.Notes = "{0} item(s) locked" -f $failedEntries.Count
        }
        else {
            Write-Log "${Description}: Files deleted successfully."
            $stats.Result = "Cleaned"
        }
    }
    catch {
        Write-Ui "Failed to delete some files in $Description." -Color Red
        Write-Log "${Description}: Failed - $($_.Exception.Message)"
        $stats.Result = "Failed"
        $stats.Notes = $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
        $stats.Duration = $stopwatch.Elapsed
        $script:RunStats.Add($stats)
        Write-TargetSummary -Stats $stats
    }
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

$settings = [pscustomobject]@{
    DetailedLog          = $false
    DetailedLogLimit     = 5000
    SkipThumbnails       = $true
    IncludeThumbnails    = $false
    WhatIf               = $false
    Silent               = $false
    DisableNotifications = $false
    Preset               = 'Basic'
    UpdateFeed           = $script:DefaultUpdateFeed
    SkipUpdateCheck      = $false
    UpdateTimeoutSec     = 5
}
$settings = Get-NormalizedOptions -Options $settings -FallbackPreset 'Basic'

$options = [pscustomobject]@{
    DetailedLog          = $settings.DetailedLog
    DetailedLogLimit     = $settings.DetailedLogLimit
    SkipThumbnails       = $settings.SkipThumbnails
    IncludeThumbnails    = $settings.IncludeThumbnails
    WhatIf               = $settings.WhatIf
    Silent               = $settings.Silent
    DisableNotifications = $settings.DisableNotifications
    Preset               = $settings.Preset
    UpdateFeed           = $settings.UpdateFeed
    SkipUpdateCheck      = $settings.SkipUpdateCheck
    UpdateTimeoutSec     = $settings.UpdateTimeoutSec
}

if ($OptionsImportPath) {
    if (Test-Path -LiteralPath $OptionsImportPath) {
        try {
            $imported = Get-Content -Path $OptionsImportPath -Raw | ConvertFrom-Json
            foreach ($prop in $options.PSObject.Properties.Name) {
                if ($imported.PSObject.Properties.Name -contains $prop) {
                    $options.$prop = $imported.$prop
                }
            }
        }
        catch {
            Write-Warning "Failed to load relaunch options. Falling back to built-in defaults."
        }
        finally {
            Remove-Item -LiteralPath $OptionsImportPath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Warning "Relaunch options file not found. Falling back to built-in defaults."
    }
}

$options = Get-NormalizedOptions -Options $options -FallbackPreset $settings.Preset

if (-not $options.Silent -and -not $OptionsImportPath) {
    $options = Invoke-ModeMenu -Options $options
    $options = Get-NormalizedOptions -Options $options -FallbackPreset $settings.Preset
}

$script:IsSilent = $options.Silent

$isAdmin = Test-IsAdministrator
$userTargets = @(
    @{ Path = $env:TEMP;                                       Desc = "User Temp Files";     RequiresAdmin = $false },
    @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Desc = "Edge/IE Cache";      RequiresAdmin = $false }
)
$systemTargets = @(
    @{ Path = "C:\Windows\Temp";                               Desc = "System Temp Files";    RequiresAdmin = $true },
    @{ Path = "C:\Windows\SoftwareDistribution\Download";      Desc = "Windows Update Cache"; RequiresAdmin = $true },
    @{ Path = "C:\Windows\Minidump";                           Desc = "Memory Dumps";         RequiresAdmin = $true }
)
$targets = @($userTargets + $systemTargets)

$runSystemTargets = $true
if (-not $isAdmin) {
    if (Start-ElevatedRelaunch -Options $options) {
        exit
    }
    Write-Ui "Administrator privileges are required. Cleanup canceled." -Color Red
    if (-not $options.Silent) {
        Write-Ui "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }
    exit 1
}

if (-not (Test-Path -LiteralPath $script:LogRoot)) {
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
}

$LogFile = Join-Path $script:LogRoot ("cleanup_{0}.log" -f $script:RunTimestamp)
$script:ActiveLogFile = $LogFile

Show-Header

if (-not $options.SkipUpdateCheck) {
    Invoke-UpdateCheck -Options $options
}

"Cleanup started at $(Get-Date)" | Set-Content -Path $LogFile
Write-Log "Running as user: $env:USERNAME"
Write-Log "Defaults persistence: disabled"
Write-Log "Options: $(($options | ConvertTo-Json -Depth 3))"
Write-Log "----------------------------------------"
Write-Ui ("Cleanup started at {0}" -f (Get-Date)) -Color DarkGray -VerboseOnly
if (-not $options.Silent) {
    $skipPlanConfirm = -not [string]::IsNullOrWhiteSpace($OptionsImportPath)
    $approved = Show-RunPlan -Options $options -Targets $targets -RunSystemTargets:$runSystemTargets -IsAdmin:$isAdmin -SkipConfirmation:$skipPlanConfirm
    if (-not $approved) {
        Write-Ui ""
        Write-Ui "Cleanup canceled before execution." -Color Yellow
        Write-Log "Cleanup canceled before execution."
        Write-Ui "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
        exit
    }
    Write-Section -Title "Cleaning Targets"
}

foreach ($t in $targets) {
    if ($t.RequiresAdmin -and -not $runSystemTargets) {
        Add-SkippedTargetResult -Description $t.Desc -Path $t.Path -Reason "Requires administrator privileges"
        continue
    }
    Clear-Folder -Path $t.Path -Description $t.Desc -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -DetailedLogLimit $options.DetailedLogLimit -SilentMode:$options.Silent
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
    if ($options.WhatIf) {
        Write-Ui "WhatIf: would stop Explorer..." -Color Cyan
        Write-Log "Thumbnail Cache: WhatIf - Explorer not stopped."
    }
    else {
        Write-Ui "Stopping Explorer..." -Color DarkGray
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }

    Clear-Folder -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Description "Thumbnail Cache (thumbcache*.db)" -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -DetailedLogLimit $options.DetailedLogLimit -SilentMode:$options.Silent -IncludePatterns @('thumbcache*.db') -NoRecurse -SkipDirectoryDeletion

    if ($options.WhatIf) {
        Write-Ui "WhatIf: would restart Explorer..." -Color Cyan
        Write-Log "Thumbnail Cache: WhatIf - Explorer not restarted."
    }
    else {
        Write-Ui "Restarting Explorer..." -Color DarkGray
        Start-Process explorer.exe | Out-Null
    }
}

if ($script:RunStats.Count -gt 0) {
    $freedBytes = ($script:RunStats | Measure-Object -Property FreedBytes -Sum).Sum
    $estimatedBytes = ($script:RunStats | Measure-Object -Property SizeBytes -Sum).Sum
    $totalSeconds = ($script:RunStats | ForEach-Object { $_.Duration.TotalSeconds } | Measure-Object -Sum).Sum
    $totalDuration = [timespan]::FromSeconds($totalSeconds)
    $warningCount = ($script:RunStats | Where-Object { $_.Result -in @('Partial','Failed') }).Count
    Show-RunSummary -Stats $script:RunStats -FreedBytes $freedBytes -EstimatedBytes $estimatedBytes -Simulate:$options.WhatIf
    if (-not $script:IsSilent -and $VerbosePreference -ne 'SilentlyContinue') {
        $script:RunStats |
            Select-Object Description, Result, Files, Folders, @{Name="Size";Expression={ Format-Bytes -Bytes $_.SizeBytes }} |
            Format-Table -AutoSize
    }
}

Write-Log "Cleanup completed at $(Get-Date)"
Write-Ui ""
Write-Ui ("Cleanup completed. Log: {0}" -f $LogFile)

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
