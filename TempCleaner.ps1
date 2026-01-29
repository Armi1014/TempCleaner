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
param()

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogRoot = Join-Path $script:AppRoot 'logs'
$script:ConfigPath = Join-Path $script:AppRoot 'TempCleaner.config.json'
$script:RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Version = [version]'0.3.0'
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

function Show-Header {
    Write-Ui ("TempCleaner v{0}" -f $script:Version) -Color Cyan
    Write-Ui ""
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Settings {
    param([string]$Path)
    $defaults = [ordered]@{
        DetailedLog          = $false
        SkipThumbnails       = $true
        IncludeThumbnails    = $false
        WhatIf               = $false
        Silent               = $false
        DisableNotifications = $false
        Preset               = "Basic"
        UpdateFeed           = $script:DefaultUpdateFeed
        SkipUpdateCheck      = $false
    }
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
            foreach ($key in $defaults.Keys) {
                if ($json.PSObject.Properties.Name -contains $key) {
                    $defaults[$key] = $json.$key
                }
            }
        }
        catch {
            Write-Warning "Failed to load settings file. Using defaults."
        }
    }
    return [pscustomobject]$defaults
}

function Save-Settings {
    param(
        [Parameter(Mandatory)][pscustomobject]$Settings,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $Settings | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
        Write-Ui "Saved defaults to $Path" -Color DarkGray
    }
    catch {
        Write-Warning "Unable to persist settings: $($_.Exception.Message)"
    }
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
            Write-Ui "Unknown preset '$Name'. Falling back to saved defaults." -Color Yellow
        }
    }
}

function Copy-Options {
    param(
        [Parameter(Mandatory)][pscustomobject]$Source,
        [Parameter(Mandatory)][pscustomobject]$Target
    )
    foreach ($prop in $Source.PSObject.Properties) {
        $Target.$($prop.Name) = $prop.Value
    }
}

function Test-OptionsChanged {
    param(
        [Parameter(Mandatory)][pscustomobject]$Current,
        [Parameter(Mandatory)][pscustomobject]$Saved
    )
    foreach ($prop in $Saved.PSObject.Properties) {
        $name = $prop.Name
        if ($Current.PSObject.Properties.Name -notcontains $name) { continue }
        if ($Current.$name -ne $prop.Value) { return $true }
    }
    return $false
}

function Invoke-ModeMenu {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options,
        [Parameter(Mandatory)][pscustomobject]$SavedOptions
    )
    $presetTable = @(
        [pscustomobject]@{ Id = 1; Name = "Basic";  Description = "Fast cleanup (skip thumbnails)." },
        [pscustomobject]@{ Id = 2; Name = "Full";   Description = "Everything + thumbnails + detailed log." },
        [pscustomobject]@{ Id = 3; Name = "Custom"; Description = "Pick options one by one." },
        [pscustomobject]@{ Id = 4; Name = "Saved";  Description = "Use saved defaults ($($SavedOptions.Preset))." }
    )

    Write-Ui ""
    Write-Ui "Cleanup mode" -Color Cyan
    foreach ($row in $presetTable) {
        $label = "{0}. {1,-6} {2}" -f $row.Id, $row.Name, $row.Description
        $color = switch ($row.Name) {
            'Basic' { 'Green' }
            'Full' { 'Yellow' }
            'Custom' { 'Cyan' }
            'Saved' { 'DarkGray' }
            default { 'White' }
        }
        Write-Ui ("  {0}" -f $label) -Color $color
    }
    Write-Ui ""
    Write-Ui "Press Enter to use Saved." -Color DarkGray

    do {
        $choice = Read-Host "Select 1-4 (default: 4)"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = '4'
        }
    } until ($choice -match '^[1-4]$')

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
        '4' { Copy-Options -Source $SavedOptions -Target $Options }
    }
    $remember = $false
    if (Test-OptionsChanged -Current $Options -Saved $SavedOptions) {
        $remember = Get-YesNoResponse "Remember this selection as default?" $false
    }
    return [pscustomobject]@{
        Options      = $Options
        SaveDefaults = $remember
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
    $width = 30
    $fillBlocks = [math]::Floor(($Percent / 100) * $width)
    if ($fillBlocks -lt 0) { $fillBlocks = 0 }
    if ($fillBlocks -gt $width) { $fillBlocks = $width }
    $bar = ('#' * $fillBlocks).PadRight($width, '-')
    $activityLabel = if ($Activity.Length -gt 25) { $Activity.Substring(0, 25) } else { $Activity }
    $line = "`r{0,-25} [{1}] {2,3}%" -f $activityLabel, $bar, [math]::Min([math]::Max($Percent, 0), 100)
    if ($Status) {
        $line += " $Status"
    }
    Write-Host $line -NoNewline
    if ($Percent -ge 100) {
        Write-Host ""
    }
}

function Write-TargetSummary {
    param([pscustomobject]$Stats)
    $bytesToShow = if ($Stats.Result -eq 'WhatIf') { $Stats.SizeBytes } elseif ($Stats.FreedBytes -gt 0) { $Stats.FreedBytes } else { $Stats.SizeBytes }
    $size = Format-Bytes -Bytes $bytesToShow
    $duration = "{0:N1}s" -f $Stats.Duration.TotalSeconds
    $notes = if ($Stats.Notes) { " · $($Stats.Notes)" } else { "" }
    switch ($Stats.Result) {
        'Cleaned' { $icon = '[OK]'; $color = 'Green' }
        'WhatIf' { $icon = '[SIM]'; $color = 'Cyan' }
        'Partial' { $icon = '[WARN]'; $color = 'Yellow' }
        'Skipped' { $icon = '[SKIP]'; $color = 'Yellow' }
        'Failed' { $icon = '[ERR]'; $color = 'Red' }
        default { $icon = '[--]'; $color = 'Gray' }
    }
    Write-Ui ("{0} {1} | {2} files | {3} folders | {4} | {5}{6}" -f $icon, $Stats.Description, $Stats.Files, $Stats.Folders, $size, $duration, $notes) -Color $color
}

function Invoke-UpdateCheck {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    if ($Options.SkipUpdateCheck) { return }
    if (-not $Options.UpdateFeed) { return }
    try {
        $irmParams = @{
            Uri         = $Options.UpdateFeed
            ErrorAction = 'Stop'
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
        [switch]$SilentMode
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

        $dangerous = @('\', 'C:\', 'C:')
        if ($dangerous -contains $Path.Trim()) {
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
        Write-Ui ("Cleaning {0}..." -f $Description) -Color Cyan
        Write-Ui ("  {0}" -f $Path) -Color DarkGray -VerboseOnly

        $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
        $fileItems = @($items | Where-Object { -not $_.PSIsContainer })
        $folderItems = @($items | Where-Object { $_.PSIsContainer })

        $stats.Files = $fileItems.Count
        $stats.Folders = $folderItems.Count
        $stats.SizeBytes = ($fileItems | Measure-Object -Property Length -Sum).Sum
        $stats.FreedBytes = if ($Simulate) { 0 } else { $stats.SizeBytes }

        if ($DetailedLog) {
            Write-Log "${Description}: Files in '$Path':"
            foreach ($item in $items) {
                Write-Log "    $($item.FullName)"
            }
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

        Write-Ui ("  {0} files, {1} folders (~{2})." -f $stats.Files, $stats.Folders, (Format-Bytes -Bytes $stats.SizeBytes)) -Color DarkGray -VerboseOnly

        if ($Simulate) {
            Write-Log "${Description}: WhatIf - no deletion performed."
            return
        }

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
                Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
                $failedEntries.Add([pscustomobject]@{
                        Path   = $entry.FullName
                        Reason = $_.Exception.Message
                    }) | Out-Null
                Write-Log "${Description}: Failed to delete '$($entry.FullName)': $($_.Exception.Message)"
                if (-not $entry.PSIsContainer -and $entry.PSObject.Properties.Name -contains 'Length' -and $entry.Length) {
                    $stats.FreedBytes = [math]::Max(0, $stats.FreedBytes - [long]$entry.Length)
                }
            }
        }
        Show-AsciiProgress -Percent 100 -Activity $Description -Status ("{0}/{1}" -f $processed, $totalCount) -SilentMode:$SilentMode

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
        [timespan]$TotalDuration,
        [int]$WarningCount
    )
    $freedLabel = if ($FreedBytes -gt 0) { Format-Bytes -Bytes $FreedBytes } else { "0 MB" }
    $durationLabel = "{0:N1}s" -f $TotalDuration.TotalSeconds
    $warnLabel = if ($WarningCount -gt 0) { "$WarningCount warning(s)" } else { "no warnings" }
    $line = "-------------------------------"
    Write-Ui ""
    Write-Ui $line -Color DarkGray
    Write-Ui ("[OK] Cleanup complete  -  {0}  -  {1}  -  {2}" -f $freedLabel, $durationLabel, $warnLabel) -Color Green
    Write-Ui $line -Color DarkGray
}

function Ensure-Admin {
    if (Test-IsAdministrator) { return }
    Write-Ui "Requesting administrator privileges..." -Color Yellow
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $args = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    Start-Process -FilePath $exe -ArgumentList $args -Verb RunAs
    exit
}

Ensure-Admin

$settings = Get-Settings -Path $script:ConfigPath

$options = [pscustomobject]@{
    DetailedLog          = $settings.DetailedLog
    SkipThumbnails       = $settings.SkipThumbnails
    IncludeThumbnails    = $settings.IncludeThumbnails
    WhatIf               = $settings.WhatIf
    Silent               = $settings.Silent
    DisableNotifications = $settings.DisableNotifications
    Preset               = $settings.Preset
    UpdateFeed           = $settings.UpdateFeed
    SkipUpdateCheck      = $settings.SkipUpdateCheck
}

if ($options.SkipThumbnails -and $options.IncludeThumbnails) {
    $options.IncludeThumbnails = $false
    $options.SkipThumbnails = $true
}

if (-not $options.Silent) {
    $menuResult = Invoke-ModeMenu -Options $options -SavedOptions $settings
    $options = $menuResult.Options
    if ($menuResult.SaveDefaults) {
        Save-Settings -Settings $options -Path $script:ConfigPath
    }
}

$script:IsSilent = $options.Silent

if (-not (Test-IsAdministrator)) {
    Write-Ui "Administrator privileges are recommended to clean system locations." -Color Yellow
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
Write-Log "Options: $(($options | ConvertTo-Json -Depth 3))"
Write-Log "----------------------------------------"

Write-Ui ("Cleanup started at {0}" -f (Get-Date)) -Color DarkGray -VerboseOnly
if (-not $options.Silent) {
    $thumbLabel = if ($options.IncludeThumbnails) { "include" } elseif ($options.SkipThumbnails) { "skip" } else { "prompt" }
    $logLabel = if ($options.DetailedLog) { "detailed" } else { "standard" }
    $runLabel = if ($options.WhatIf) { "dry run" } else { "live" }
    Write-Ui ("Mode: {0} | Thumbnails: {1} | Log: {2} | Run: {3}" -f $options.Preset, $thumbLabel, $logLabel, $runLabel) -Color DarkGray
}

$targets = @(
    @{ Path = $env:TEMP;                                     Desc = "User Temp Files" },
    @{ Path = "C:\Windows\Temp";                             Desc = "System Temp Files" },
    @{ Path = "C:\Windows\SoftwareDistribution\Download";    Desc = "Windows Update Cache" },
    @{ Path = "C:\Windows\Minidump";                         Desc = "Memory Dumps" },
    @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Desc = "Edge/IE Cache" }
)

foreach ($t in $targets) {
    Clear-Folder -Path $t.Path -Description $t.Desc -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -SilentMode:$options.Silent
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
    $clearThumbs = Read-Host "Clear the Explorer thumbnail cache? (Y/N) [May restart Explorer]"
    if ($clearThumbs -match '^[Yy]') {
        $cleanThumbs = $true
    }
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

    Clear-Folder -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Description "Thumbnail Cache" -Simulate:$options.WhatIf -DetailedLog:$options.DetailedLog -SilentMode:$options.Silent

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
    $totalSeconds = ($script:RunStats | ForEach-Object { $_.Duration.TotalSeconds } | Measure-Object -Sum).Sum
    $totalDuration = [timespan]::FromSeconds($totalSeconds)
    $warningCount = ($script:RunStats | Where-Object { $_.Result -in @('Partial','Failed') }).Count
    if ($freedBytes -gt 0) {
        Write-Ui ("Total freed: {0}" -f (Format-Bytes -Bytes $freedBytes)) -Color Green
    }

    if (-not $script:IsSilent -and $VerbosePreference -ne 'SilentlyContinue') {
        Write-Ui ""
        Write-Ui "Summary" -Color Cyan
        $script:RunStats |
            Select-Object Description, Result, Files, Folders, @{Name="Size";Expression={ Format-Bytes -Bytes $_.SizeBytes }} |
            Format-Table -AutoSize
    }
}

Write-Log "Cleanup completed at $(Get-Date)"
Write-Ui ""
Write-Ui ("Cleanup completed. Log: {0}" -f $LogFile)

if (-not $options.DisableNotifications -and $script:RunStats.Count -gt 0) {
    $msg = if ($freedBytes -gt 0) { "Freed $(Format-Bytes -Bytes $freedBytes)" } else { "Cleanup run finished." }
    Send-Notification -Title "TempCleaner" -Message $msg -SilentMode:$options.Silent
    Show-CompletionBanner -FreedBytes $freedBytes -TotalDuration $totalDuration -WarningCount $warningCount
}

if (-not $options.Silent) {
    Write-Ui "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
