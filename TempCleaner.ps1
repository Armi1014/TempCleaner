[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$DetailedLog,
    [switch]$SkipThumbnails,
    [switch]$IncludeThumbnails,
    [switch]$Silent,
    [switch]$DisableNotifications,
    [switch]$SkipUpdateCheck,
    [string]$Preset,
    [string]$LogFile,
    [string]$ConfigFile
)

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogRoot = Join-Path $script:AppRoot 'logs'
$script:ConfigPath = if ($ConfigFile) {
    if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile } else { Join-Path $script:AppRoot $ConfigFile }
} else {
    Join-Path $script:AppRoot 'TempCleaner.config.json'
}
$script:RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Version = [version]'0.3.0'
$script:DefaultUpdateFeed = "https://raw.githubusercontent.com/ardai/TempCleaner/main/version.json"
$script:RunStats = [System.Collections.Generic.List[pscustomobject]]::new()
$script:ActiveLogFile = $null

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
    $banner = @(
        "=====================================",
        "   TempCleaner - PowerShell Edition  ",
        "   Version $($script:Version.ToString())",
        "====================================="
    )
    foreach ($line in $banner) {
        Write-Host $line -ForegroundColor Cyan
    }
    Write-Host ""
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
        Write-Host "Saved defaults to $Path" -ForegroundColor DarkGreen
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
        Write-Host "Please enter Y or N." -ForegroundColor Yellow
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
        }
        'full' {
            $Options.DetailedLog = $true
            $Options.SkipThumbnails = $false
            $Options.IncludeThumbnails = $true
            $Options.DisableNotifications = $false
        }
        'custom' { }
        default {
            Write-Host "Unknown preset '$Name'. Falling back to saved defaults." -ForegroundColor Yellow
        }
    }
}

function Invoke-ModeMenu {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    $presetTable = @(
        [pscustomobject]@{ Id = 1; Name = "Basic";  Description = "Fast cleanup, skips thumbnail cache, concise logging." },
        [pscustomobject]@{ Id = 2; Name = "Full";   Description = "Cleans everything (incl. thumbnails) with detailed logging." },
        [pscustomobject]@{ Id = 3; Name = "Custom"; Description = "Answer prompts to build your own mix of options." },
        [pscustomobject]@{ Id = 4; Name = "Saved";  Description = "Use saved defaults (`"$($Options.Preset)`")." }
    )

    Write-Host ""
    Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           Cleanup Mode Selection           ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan

    foreach ($row in $presetTable) {
        $label = "{0}. {1,-6} {2}" -f $row.Id, $row.Name, $row.Description
        $color = switch ($row.Name) {
            'Basic' { 'Green' }
            'Full' { 'Yellow' }
            'Custom' { 'Cyan' }
            'Saved' { 'Gray' }
            default { 'White' }
        }
        Write-Host ("  {0}" -f $label) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Tip: Press Enter to reuse the saved defaults." -ForegroundColor DarkGray

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
            Write-Host ""
            Write-Host "--- Custom Mode ---" -ForegroundColor Cyan
            $Options.DetailedLog = Get-YesNoResponse "Enable detailed logging?"
            $Options.IncludeThumbnails = Get-YesNoResponse "Always clean thumbnail cache?" $false
            $Options.SkipThumbnails = -not $Options.IncludeThumbnails
            $Options.DisableNotifications = -not (Get-YesNoResponse "Show desktop notification when finished?" $true)
            $Options.Preset = 'Custom'
        }
        '4' { Write-Host "Using saved defaults ($($Options.Preset))." -ForegroundColor DarkGray }
    }
    $remember = Get-YesNoResponse "Remember this selection as default?" $false
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
    $size = Format-Bytes -Bytes $Stats.SizeBytes
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
    Write-Host ("{0} {1} | {2} files | {3} folders | {4} | {5}{6}" -f $icon, $Stats.Description, $Stats.Files, $Stats.Folders, $size, $duration, $notes) -ForegroundColor $color
}

function Invoke-UpdateCheck {
    param(
        [Parameter(Mandatory)][pscustomobject]$Options
    )
    if ($Options.SkipUpdateCheck) { return }
    if (-not $Options.UpdateFeed) { return }
    try {
        $response = Invoke-RestMethod -Uri $Options.UpdateFeed -UseBasicParsing -ErrorAction Stop
        if ($response.version) {
            $remoteVersion = [version]$response.version
            if ($remoteVersion -gt $script:Version) {
                Write-Host ("Update available! Current {0}, Latest {1}" -f $script:Version, $remoteVersion) -ForegroundColor Yellow
                if ($response.releaseNotes) {
                    Write-Host "Release notes: $($response.releaseNotes)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "You are running the latest version." -ForegroundColor DarkGreen
            }
        }
    }
    catch {
        Write-Log "Update check failed: $($_.Exception.Message)"
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
            Write-Host "Skipping $Description (empty path)." -ForegroundColor Yellow
            Write-Log "${Description}: Skipped (empty path)."
            $stats.Result = "Skipped"
            $stats.Notes = "Empty path"
            return
        }

        $dangerous = @('\', 'C:\', 'C:')
        if ($dangerous -contains $Path.Trim()) {
            Write-Host "Skipping $Description (dangerous path: $Path)." -ForegroundColor Red
            Write-Log "${Description}: Skipped dangerous path '$Path'."
            $stats.Result = "Skipped"
            $stats.Notes = "Dangerous path"
            return
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "$Description -> folder does not exist, skipping." -ForegroundColor Yellow
            Write-Log "${Description}: '$Path' does not exist."
            $stats.Result = "Skipped"
            $stats.Notes = "Missing"
            return
        }

        Write-Host ""
        Write-Host ("[+] {0}" -f $Description) -ForegroundColor Cyan
        Write-Host ("    {0}" -f $Path)

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
            Write-Host "    Nothing to remove." -ForegroundColor Yellow
            Write-Log "${Description}: Nothing to remove."
            $stats.Result = if ($Simulate) { "WhatIf" } else { "Skipped" }
            $stats.Notes = "Nothing to remove"
            return
        }

        Write-Host ("    Found {0} files and {1} folders (~{2})." -f $stats.Files, $stats.Folders, (Format-Bytes -Bytes $stats.SizeBytes))

        if ($Simulate) {
            Write-Host "    WhatIf: would delete contents." -ForegroundColor Cyan
            Write-Log "${Description}: WhatIf - no deletion performed."
            return
        }

        $toDelete = @($fileItems + ($folderItems | Sort-Object FullName -Descending))
        $totalCount = $toDelete.Count
        $processed = 0
        $failedEntries = [System.Collections.Generic.List[pscustomobject]]::new()

        foreach ($entry in $toDelete) {
            $processed++
            $percent = if ($totalCount -eq 0) { 100 } else { [math]::Round(($processed / $totalCount) * 100, 0) }
            Show-AsciiProgress -Percent $percent -Activity $Description -Status $entry.Name -SilentMode:$SilentMode
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
        Show-AsciiProgress -Percent 100 -Activity $Description -Status "Completed" -SilentMode:$SilentMode

        if ($failedEntries.Count -gt 0) {
            Write-Host ("    Completed with warnings: {0} item(s) locked or in use." -f $failedEntries.Count) -ForegroundColor Yellow
            Write-Log "${Description}: Completed with warnings - $($failedEntries.Count) item(s) skipped."
            $stats.Result = "Partial"
            $stats.Notes = "{0} item(s) locked" -f $failedEntries.Count
        }
        else {
            Write-Host "    Done." -ForegroundColor Green
            Write-Log "${Description}: Files deleted successfully."
            $stats.Result = "Cleaned"
        }
    }
    catch {
        Write-Host "    Failed to delete some files." -ForegroundColor Red
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

if ($SkipThumbnails -and $IncludeThumbnails) {
    throw "Specify either -SkipThumbnails or -IncludeThumbnails, not both."
}

$settings = Get-Settings -Path $script:ConfigPath

$options = [pscustomobject]@{
    DetailedLog          = $settings.DetailedLog
    SkipThumbnails       = $settings.SkipThumbnails
    IncludeThumbnails    = $settings.IncludeThumbnails
    Silent               = $settings.Silent
    DisableNotifications = $settings.DisableNotifications
    Preset               = $settings.Preset
    UpdateFeed           = $settings.UpdateFeed
    SkipUpdateCheck      = $settings.SkipUpdateCheck
}

if ($PSBoundParameters.ContainsKey('DetailedLog')) { $options.DetailedLog = [bool]$DetailedLog }
if ($PSBoundParameters.ContainsKey('SkipThumbnails')) { $options.SkipThumbnails = [bool]$SkipThumbnails; if ($SkipThumbnails) { $options.IncludeThumbnails = $false } }
if ($PSBoundParameters.ContainsKey('IncludeThumbnails')) { $options.IncludeThumbnails = [bool]$IncludeThumbnails; if ($IncludeThumbnails) { $options.SkipThumbnails = $false } }
if ($PSBoundParameters.ContainsKey('Silent')) { $options.Silent = [bool]$Silent }
if ($DisableNotifications) { $options.DisableNotifications = $true }
if ($SkipUpdateCheck) { $options.SkipUpdateCheck = $true }
if ($PSBoundParameters.ContainsKey('Preset')) { Set-PresetOptions -Name $Preset -Options $options; $options.Preset = $Preset }

if (-not $options.Silent -and -not $PSBoundParameters.ContainsKey('Preset')) {
    $menuResult = Invoke-ModeMenu -Options $options
    $options = $menuResult.Options
    if ($menuResult.SaveDefaults) {
        Save-Settings -Settings $options -Path $script:ConfigPath
    }
}

if (-not $options.IncludeThumbnails -and -not $options.SkipThumbnails -and $options.Silent) {
    $options.SkipThumbnails = $true
}

if (-not (Test-IsAdministrator)) {
    Write-Warning "Administrator privileges are recommended to clean system locations."
}

if (-not (Test-Path -LiteralPath $script:LogRoot)) {
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
}

if (-not $LogFile) {
    $LogFile = Join-Path $script:LogRoot ("cleanup_{0}.log" -f $script:RunTimestamp)
}
elseif (-not [System.IO.Path]::IsPathRooted($LogFile)) {
    $LogFile = Join-Path $script:AppRoot $LogFile
}
$script:ActiveLogFile = $LogFile

Show-Header

if (-not $options.SkipUpdateCheck) {
    Invoke-UpdateCheck -Options $options
}

"Cleanup started at $(Get-Date)" | Set-Content -Path $LogFile
Write-Log "Running as user: $env:USERNAME"
Write-Log "Options: $(($options | ConvertTo-Json -Depth 3))"
Write-Log "----------------------------------------"

Write-Host "Cleanup started at $(Get-Date)"
Write-Host ""

$targets = @(
    @{ Path = $env:TEMP;                                     Desc = "User Temp Files" },
    @{ Path = "C:\Windows\Temp";                             Desc = "System Temp Files" },
    @{ Path = "C:\Windows\SoftwareDistribution\Download";    Desc = "Windows Update Cache" },
    @{ Path = "C:\Windows\Minidump";                         Desc = "Memory Dumps" },
    @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Desc = "Edge/IE Cache" }
)

foreach ($t in $targets) {
    Clear-Folder -Path $t.Path -Description $t.Desc -Simulate:$WhatIf -DetailedLog:$options.DetailedLog -SilentMode:$options.Silent
}

Write-Host ""
$cleanThumbs = $false
if ($options.IncludeThumbnails) {
    $cleanThumbs = $true
}
elseif ($options.SkipThumbnails) {
    Write-Log "Thumbnail Cache: Skipped by preference."
}
elseif (-not $options.Silent) {
    $clearThumbs = Read-Host "Do you want to clear the Explorer thumbnail cache? (Y/N) [Deletes cached preview images and may restart Explorer]"
    if ($clearThumbs -match '^[Yy]') {
        $cleanThumbs = $true
    }
}

if ($cleanThumbs) {
    Write-Host ""
    if ($WhatIf) {
        Write-Host "WhatIf: would stop Explorer..." -ForegroundColor Cyan
        Write-Log "Thumbnail Cache: WhatIf - Explorer not stopped."
    }
    else {
        Write-Host "Stopping Explorer..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }

    Clear-Folder -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Description "Thumbnail Cache" -Simulate:$WhatIf -DetailedLog:$options.DetailedLog -SilentMode:$options.Silent

    if ($WhatIf) {
        Write-Host "WhatIf: would restart Explorer..." -ForegroundColor Cyan
        Write-Log "Thumbnail Cache: WhatIf - Explorer not restarted."
    }
    else {
        Write-Host "Restarting Explorer..."
        Start-Process explorer.exe | Out-Null
    }
}

if ($script:RunStats.Count -gt 0) {
    Write-Host ""
    Write-Host "============= Summary =============" -ForegroundColor Cyan
    $script:RunStats |
        Select-Object Description, Result, Files, Folders, @{Name="Size";Expression={ Format-Bytes -Bytes $_.SizeBytes }} |
        Format-Table -AutoSize

    $freedBytes = ($script:RunStats | Measure-Object -Property FreedBytes -Sum).Sum
    if ($freedBytes -gt 0) {
        Write-Host ("Estimated space freed: {0}" -f (Format-Bytes -Bytes $freedBytes)) -ForegroundColor Green
    }
}

Write-Log "Cleanup completed at $(Get-Date)"
Write-Host ""
Write-Host ("Cleanup completed. Log: {0}" -f $LogFile)

if (-not $options.DisableNotifications) {
    $freedBytes = ($script:RunStats | Measure-Object -Property FreedBytes -Sum).Sum
    $msg = if ($freedBytes -gt 0) { "Freed $(Format-Bytes -Bytes $freedBytes)" } else { "Cleanup run finished." }
    Send-Notification -Title "TempCleaner" -Message $msg -SilentMode:$options.Silent
}

if (-not $options.Silent) {
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
