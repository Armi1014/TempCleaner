## 🧹 TempCleaner v0.5.0 – PowerShell temp cleaner for Windows

Fast, offline, telemetry-free temp/cache cleaner for Windows.  
Unzip it, run `Run-TempCleaner.bat` (launcher for `TempCleaner.ps1`), pick a preset, done.

- 🧠 **Presets**: `Basic`, `Full`, or `Custom`
- 📦 **Cleans**: user + system temp, Windows Update cache, minidumps, optional Explorer `thumbcache*.db`
- 🧰 **Optional targets**: DirectX shader cache, Delivery Optimization cache, and Windows Error Reporting queues/archives via the Settings menu
- 🧾 **Per-run logs**: timestamped logs in `logs/` + estimated space freed
- 📊 **UI**: interactive menu, progress bars, color-coded summary, desktop notification on finish
- 🛡️ **Safety-first**: allowlisted cleanup roots only, root paths blocked, and non-admin runs automatically fall back to user-only cleanup
- 🔐 **Safe by design**: no root paths, dry-run option in Custom mode, fully offline (optional update check only)

### ⚡ Quick start

1. Download and extract the ZIP.
2. Double-click `Run-TempCleaner.bat` (it launches `TempCleaner.ps1` with PowerShell 7 if installed, otherwise Windows PowerShell).
3. Pick **Basic / Full / Custom** and confirm cleanup. If elevation is available, system targets are included; otherwise TempCleaner still cleans user targets and clearly skips system targets.
4. Open **Settings** from the main menu if you want to persist optional cleanup targets for future **Full** or **Custom** runs.

### Configuration

- TempCleaner reads `TempCleaner.config.json` from the app folder by default.
- Use `-ConfigPath <path>` to load a different config file.
- Precedence is: built-in defaults < config file < explicit CLI flags < elevation handoff.
- Update checks are disabled by default. To opt in, set `"SkipUpdateCheck": false` in the config file.
- Optional cleanup targets are stored in config and are disabled by default:
  - `IncludeDirectXShaderCache`
  - `IncludeDeliveryOptimizationCache`
  - `IncludeWindowsErrorReporting`

### Automation

- Interactive mode still opens by default, even if you pass CLI flags or set config values.
- Use `-Silent` for scheduler/automation scenarios.
- `Basic` ignores optional targets even if they are enabled in settings.
- `Full` includes any optional targets enabled in settings.
- `Custom` asks about optional targets one by one, defaulting to the saved settings values for that run.
- Supported user-facing script parameters:
  - `-Preset Basic|Full|Custom`
  - `-WhatIf`
  - `-DetailedLog`
  - `-DetailedLogLimit <int>`
  - `-IncludeThumbnails`
  - `-SkipThumbnails`
  - `-Silent`
  - `-DisableNotifications`
  - `-SkipUpdateCheck`
  - `-UserOnly`
  - `-IncludeDirectXShaderCache`
  - `-IncludeDeliveryOptimizationCache`
  - `-IncludeWindowsErrorReporting`
  - `-ConfigPath <path>`
