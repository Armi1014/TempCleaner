## 🧹 TempCleaner v0.6.0 – PowerShell temp cleaner for Windows

[![Pester](https://github.com/Armi1014/TempCleaner/actions/workflows/pester.yml/badge.svg)](https://github.com/Armi1014/TempCleaner/actions/workflows/pester.yml)

Fast, offline, telemetry-free temp/cache cleaner for Windows.  
Unzip it, run `Run-TempCleaner.bat` (launcher for `TempCleaner.ps1`), pick a preset, done.

TempCleaner is not batch-based. `Run-TempCleaner.bat` is only a launcher that finds PowerShell and forwards arguments; all cleanup logic lives in `TempCleaner.ps1`.

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

### Terminal preview

```text
============================================================
 TempCleaner v0.6.0
 Safe temp/cache cleanup for Windows
 Session: 2026-04-18 15:51:56
 Safety: Allowlisted targets only, roots blocked
============================================================

Choose a mode:
  1. Basic
  2. Full
  3. Custom
  4. Settings
  5. Exit

Run type: Dry run (simulation only)
Preset: Full
Targets: User Temp Files, Edge/IE Cache, DirectX Shader Cache
System targets: skipped - user-only mode
```

### Configuration

- TempCleaner reads `TempCleaner.config.json` from the app folder by default.
- Use `-ConfigPath <path>` to load a different config file.
- Precedence is: built-in defaults < config file < explicit CLI flags < elevation handoff.
- Update checks are disabled by default. To opt in, set `"SkipUpdateCheck": false` in the config file.
- Optional cleanup targets are stored in config and are disabled by default:
  - `IncludeDirectXShaderCache`
  - `IncludeDeliveryOptimizationCache`
  - `IncludeWindowsErrorReporting`
- Log retention is configurable with `LogRetentionCount` and `LogRetentionDays`.

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
  - `-LogRetentionCount <int>`
  - `-LogRetentionDays <int>`
  - `-ConfigPath <path>`
