## 🧹 TempCleaner v0.5.0 – PowerShell temp cleaner for Windows

Fast, offline, telemetry-free temp/cache cleaner for Windows.  
Unzip it, run `Run-TempCleaner.bat`, pick a preset, done.

- 🧠 **Presets**: `Basic`, `Full`, or `Custom`
- 📦 **Cleans**: user + system temp, Windows Update cache, minidumps, optional Explorer `thumbcache*.db`
- 🧾 **Per-run logs**: timestamped logs in `logs/` + estimated space freed
- 📊 **UI**: interactive menu, progress bars, color-coded summary, desktop notification on finish
- 🛡️ **Admin-required**: automatically requests elevation for full cleanup; if elevation is declined/unavailable, cleanup is canceled
- 🔐 **Safe by design**: no root paths, dry-run option in Custom mode, fully offline (optional update check only)

### ⚡ Quick start

1. Download and extract the ZIP.
2. Double-click `Run-TempCleaner.bat` (uses PowerShell 7 if installed, otherwise Windows PowerShell).
3. Accept the elevation prompt, then pick **Basic / Full / Custom** and confirm cleanup. (Logs are saved under `logs/`.)
