## 🧹 TempCleaner v0.3.0 – PowerShell Edition

A modern PowerShell-based cleaner with interactive presets, per-run logs, and a friendlier UI.  
Fast, offline, and still telemetry-free — unzip it, run `Run-TempCleaner.bat`, and you’re good to go.

---

### ✨ Features

- 🧠 **Preset-driven UX**
  - `Basic`, `Full`, or `Custom` modes
  - Guided interactive menu
  - Remembers your last-used preset for future runs

- 🕒 **Per-run logging**
  - Each run writes a timestamped log under `logs/`
  - Includes a summary of estimated space freed
  - Easy to audit what happened and when

- 🧮 **Visual feedback**
  - Live ASCII progress bars for each cleanup target
  - Color-coded end summary:
    - ✅ Cleaned
    - ⚠️ Skipped
    - 🔒 Locked

- 🔐 **Safety-first**
  - Full `-WhatIf` support for safe dry-runs
  - Strict protection against root paths
  - Optional thumbnail cleanup; Explorer is only restarted when needed

- 🔔 **Quality-of-life extras**
  - Desktop notifications on completion
  - Update-check hook (optional)
  - Silent automation switches
  - Launcher BAT that uses `ExecutionPolicy Bypass` so you don’t have to change system-wide settings

---

### ⚙️ Configuration

On first interactive run:

- Pick your preset (`Basic` / `Full` / `Custom`)
- TempCleaner saves it to `TempCleaner.config.json`

You can:

- Edit `TempCleaner.config.json` manually, **or**
- Pass switches such as:
  - `-DetailedLog`
  - `-SkipThumbnails`
  - `-Silent`

---

### 📁 Quick-start files

| File                     | Purpose                                                   |
|--------------------------|-----------------------------------------------------------|
| `TempCleaner.ps1`        | Main PowerShell script                                   |
| `Run-TempCleaner.bat`    | Launch helper (PowerShell with `ExecutionPolicy Bypass`) |
| `logs/cleanup_*.log`     | Timestamped run history                                   |

---

### 🧼 Cleaned locations

| Target                                           | Description           |
|--------------------------------------------------|-----------------------|
| `%TEMP%`                                         | User temp files       |
| `C:\Windows\Temp`                                | System temp files     |
| `C:\Windows\SoftwareDistribution\Download`       | Windows Update cache  |
| `C:\Windows\Minidump`                            | Memory dumps          |
| `%LOCALAPPDATA%\Microsoft\Windows\INetCache`     | Edge/IE cache         |
| *(Optional)* `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | Thumbnail cache |

---

### 🪟 Usage

#### Interactive setup

1. Extract the ZIP so the BAT and PS1 are in the same folder.
2. Double-click `Run-TempCleaner.bat`.
3. Choose **Basic / Full / Custom** and optionally save as default.
4. Review the on-screen summary (log path is printed at the end).

#### Silent / scheduled

```bat
:: Safe dry-run
Run-TempCleaner.bat -Silent -WhatIf

:: Real cleanup
Run-TempCleaner.bat -Silent
````

You can also call PowerShell directly if your policy allows:

```powershell
pwsh.exe -File .\TempCleaner.ps1 -Silent -WhatIf
```

---

### 🧱 Safety

* Refuses to operate on root paths (`C:\`, `D:\`, `\`, etc.)
* Only deletes within predefined temp/cache directories
* Honors PowerShell `-WhatIf` for simulations and logs every action
* Fully offline by default: no installers, no telemetry; only an optional version-check JSON

---

### 🗓️ Version history

| Version | Changes                                                                                  |
| ------: | ---------------------------------------------------------------------------------------- |
|    v0.1 | Initial prototype – basic temp file cleanup                                              |
|  v0.2.0 | Configurable batch script with silent/detailed flags and stronger safety checks          |
|  v0.3.0 | PowerShell edition with presets, per-run log folder, progress UI, launcher BAT, and more |
