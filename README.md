# 🧹 TempCleaner – v0.2.0

A lightweight, configurable Windows batch script for safely cleaning temporary and cache files.  
Fast, offline, and entirely open-source — no installers, no telemetry, just a smart `.bat`.

---

## ✨ Features

- 🧩 **Configurable behavior** – toggle logging detail, folder deletion, thumbnail cache cleaning, and prompts  
- ⚙️ **Automation-ready** – supports `/silent` and `/detailed` command-line flags for scheduled or quick runs  
- 🔒 **Safe by design** – strict root-path protection to prevent accidental drive wipes  
- 🧾 **Smart logging** – concise by default, verbose mode available for debugging  
- 🧰 **No dependencies** – pure batch file, works out-of-the-box on Windows 10/11  

---

## 🧠 Configuration

Edit the top of the script to customize behavior:

```bat
set "DETAILED_LOG=0"   :: 1 = log every file, 0 = summary
set "ASK_THUMBS=1"     :: 1 = ask before cleaning Explorer thumbnails, 0 = skip
set "DELETE_DIRS=0"    :: 1 = also delete subfolders, 0 = keep folder structure
set "SILENT=0"         :: 1 = no prompts / no pause, 0 = interactive
````

### Command-line flags

| Flag        | Description                                            |
| ----------- | ------------------------------------------------------ |
| `/silent`   | Run without prompts or pause (good for Task Scheduler) |
| `/detailed` | Override and force detailed per-file logging           |

---

## 🧼 Cleaned locations

| Target                                                 | Description          |
| ------------------------------------------------------ | -------------------- |
| `%TEMP%`                                               | User temp files      |
| `C:\Windows\Temp`                                      | System temp files    |
| `C:\Windows\SoftwareDistribution\Download`             | Windows Update cache |
| `C:\Windows\Minidump`                                  | Memory dumps         |
| `%LOCALAPPDATA%\Microsoft\Windows\INetCache`           | Edge/IE cache        |
| (Optional) `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | Thumbnail cache      |

---

## 🪟 Usage

### Manual

1. Right-click `TempCleaner.bat` → **Run as administrator**
2. Follow prompts (if enabled)
3. Check `cleanup_log.txt` for results

### Silent (for automation)

```bash
TempCleaner.bat /silent
```

---

## 🧱 Safety

* Refuses to operate on root paths (`C:\`, `D:\`, `\`, etc.)
* Only deletes within clearly defined temp/cache folders
* All operations logged locally to `cleanup_log.txt`
* No internet access or external dependencies

---

## 🗓️ Version History

| Version    | Changes                                                                           |
| ---------- | --------------------------------------------------------------------------------- |
| **v0.1**   | Initial prototype – basic temp file cleanup                                       |
| **v0.2.0** | Added configuration, logging modes, silent automation, and stronger safety checks |

---

## 🧰 Planned (v0.3.0+)

* Optional PowerShell port (`TempCleaner.ps1`) for progress bars and size stats
* File size summaries per cleanup section
* Menu-based quick modes (basic / full / advanced)
