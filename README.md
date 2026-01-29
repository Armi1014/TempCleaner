## 🧹 TempCleaner v0.3.0 – PowerShell temp cleaner for Windows

Fast, offline, telemetry-free temp/cache cleaner for Windows.  
Unzip it, run `Run-TempCleaner.bat`, pick a preset, done.

- 🧠 **Presets**: `Basic`, `Full`, or `Custom` – remembers your last choice
- 📦 **Cleans**: user + system temp, Windows Update cache, minidumps, optional thumbnail cache
- 🧾 **Per-run logs**: timestamped logs in `logs/` + estimated space freed
- 📊 **UI**: interactive menu, progress bars, color-coded summary, desktop notification on finish
- 🛡️ **Admin-aware**: prompts for elevation to clean system locations when needed
- 🔐 **Safe by design**: no root paths, dry-run option in Custom mode, fully offline (optional update check only)

### ⚡ Quick start

1. Download and extract the ZIP.
2. Double-click `Run-TempCleaner.bat` (uses PowerShell 7 if installed, otherwise Windows PowerShell).
3. Approve the admin prompt if shown, then choose **Basic / Full / Custom** and confirm cleanup. (Logs are saved under `logs/`.)
