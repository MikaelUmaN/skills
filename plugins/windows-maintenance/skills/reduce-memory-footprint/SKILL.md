---
name: reduce-memory-footprint
description: Scan Windows memory usage, identify bloat, and interactively clean up services, startup apps, and processes. Use when the machine feels slow or memory-constrained.
license: Apache-2.0
compatibility: Requires Windows with PowerShell; several cleanup actions require administrator elevation.
disable-model-invocation: true
user-invocable: true
---

# Reduce Memory Footprint

> **Bundled scripts:** the `.ps1` files this skill runs live in a `scripts/` subdirectory beside this SKILL.md. Wherever a command below shows `<skill-dir>`, substitute the absolute path of the directory containing this SKILL.md (you are given this skill's location when it loads). Do not hardcode an absolute user path.

Follow this procedure exactly when invoked.

## Encoded Preferences & Exceptions

### Protected (NEVER touch)
- **WSL / vmmemWSL** — allowed to use significant memory; this is expected
- **GlobalProtect (PanGPA, PanGPS)** — work VPN; its webviews (~242 MB) cannot be killed
- **VS Code** — favoured app
- **OneNote** — favoured app (suggest closing only if idle and memory is critical)
- **1Password** — favoured app
- **OneDrive** — keep running, must stay in startup

### Always recommend disabling (services)
| Service | Why |
|---------|-----|
| `SysMain` (Superfetch) | Wasteful prefetching on SSD systems |
| `DiagTrack` (Telemetry) | Connected User Experiences telemetry |
| `PhoneSvc` | Phone Link telephony service |
| `RtkAudioUniversalService` | Realtek audio tray service — audio works without it; set to Disabled |

### CrossDeviceService — UWP app removal (NOT a Windows service)
**Important:** CrossDeviceService is a UWP app ("Cross Device Experience Host"), not a traditional Windows service. Disabling `PhoneSvc` does NOT stop it — it has its own startup mechanism via the Microsoft Store app framework.

**Removal procedure (use `-RemoveCrossDeviceApp` flag):**
1. Disable "Mobile Devices" startup entry via registry
2. Uninstall AppxPackage: `Get-AppxPackage *CrossDevice* -AllUsers | Remove-AppxPackage -AllUsers`
3. Remove provisioned package: `Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like "*CrossDevice*"} | Remove-AppxProvisionedPackage -Online`
4. Disable scheduled tasks under `\Microsoft\Windows\CrossDevice\`
5. Kill the running process

**Saves ~100-120 MB. Survives reboots. May be reinstalled by major Windows Updates (~2x/year).**

### Always recommend disabling (UI / registry)
| Setting | Registry | Value |
|---------|----------|-------|
| Widgets | `HKCU:\...\Explorer\Advanced\TaskbarDa` | `0` |
| Copilot button | `HKCU:\...\Explorer\Advanced\ShowCopilotButton` | `0` |
| Copilot policy | `HKCU:\...\Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot` | `1` |
| Bing in Start | `HKCU:\...\Search\BingSearchEnabled` | `0` |
| Search box (taskbar) | `HKCU:\...\Search\SearchboxTaskbarMode` | `0` (hidden) |
| Web search policy | `HKLM:\...\Policies\Microsoft\Windows\Windows Search\DisableWebSearch` | `1` |

### Background Apps — deny-by-default policy
Deny background access for all UWP apps except an allowlist. Do NOT use `GlobalUserDisabled` (breaks shell).
Instead, set `Disabled=1` + `DisabledByUser=1` per-app under `HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\<PackageFamilyName>`.

**Allowlist (never deny):**
- Shell infrastructure: `Microsoft.Windows.ShellExperienceHost_*`, `Microsoft.Windows.StartMenuExperienceHost_*`, `windows.immersivecontrolpanel_*`, `Microsoft.AAD.BrokerPlugin_*`, `Microsoft.Windows.CloudExperienceHost_*`, `MicrosoftWindows.Client.CBS_*`, `Microsoft.WindowsAppRuntime.*`, `Microsoft.VCLibs.*`, `Microsoft.UI.Xaml.*`, `Microsoft.NET.Native.*`, `Microsoft.Services.Store.Engagement_*`
- Protected apps: `AgileBits.1Password_*`, `Microsoft.OneDriveSync_*`, `Microsoft.VisualStudioCode*`, `MicrosoftCorporationII.WindowsSubsystemForLinux_*`, `CanonicalGroupLimited.Ubuntu_*`, `Microsoft.WindowsTerminal_*`, `Microsoft.DesktopAppInstaller_*`
- Auth/enrollment: `Microsoft.CompanyPortal_*`, `Microsoft.Windows.OOBENetworkCaptivePortal_*`, `Microsoft.Windows.OOBENetworkConnectionFlow_*`
- Core frameworks: `Microsoft.WindowsStore_*`, `Microsoft.StorePurchaseApp_*`
- Basic utilities: `Microsoft.WindowsCalculator_*`, `Microsoft.WindowsNotepad_*`, `Microsoft.WindowsCamera_*`, `Microsoft.Paint_*`, `Microsoft.ScreenSketch_*`, `Microsoft.Windows.Photos_*`

### Per-User Services — disable templates
Disable per-user service templates so Phone Link ecosystem and unnecessary CDP services cannot respawn:
| Template | Purpose |
|----------|---------|
| `cbdhsvc` | Clipboard User Service (Phone Link clipboard sync) |
| `CDPUserSvc` | Connected Devices Platform (used by Phone Link) |
| `DevicesFlowUserSvc` | Devices Flow (Phone Link pairing) |
| `MessagingService` | SMS/MMS messaging (Phone Link) |

Set `Start=4` at `HKLM:\SYSTEM\CurrentControlSet\Services\<template>` to prevent new instances.

### Scheduled Tasks — disable non-essential
- Disable `BraveSoftware\*` updater tasks (Brave updates via its own mechanism when opened)
- Flag any other non-Microsoft tasks for user review

### Vendor/OEM Services — right-size startup type
| Service | Action | Reason |
|---------|--------|--------|
| `DolbyDAXAPI` | Set Manual | Audio enhancement — loads on demand, no need for Automatic |
| `IntelGraphicsSoftwareService` | Set Manual | Intel graphics helper — loads on demand |
| `cplspcon` | Leave alone | Intel display audio — hardware-critical |
| `IntelAudioService` | Leave alone | Intel audio — hardware-critical |

### Search Webview Elimination — KNOWN LIMITATIONS (updated 2026-04)
**Reality:** SearchHost.exe is a shell-integrated UWP app launched by explorer.exe, NOT a service. Disabling WSearch only kills the indexing engine. SearchHost + its WebView2 children (~350-500 MB) **persist after reboot** even with ALL of the following applied:
- WSearch service Disabled
- SearchboxTaskbarMode = 0
- BingSearchEnabled = 0
- DisableWebSearch = 1
- All cloud/dynamic search settings = 0

**Why:** The Start Menu depends on SearchHost for its search UI. Windows respawns it automatically. This is **the cost of having a Start Menu on Windows 11**.

**On Windows 11 Home there is NO clean way to eliminate SearchHost.** Options that exist (all with serious caveats):
1. **Rename SearchHost.exe** (takeown + rename to .bak): Works until a cumulative Windows Update restores it. Breaks Start menu search entirely.
2. **FeatureManagement registry key** (`HKLM\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260` EnabledState=1): Undocumented, may be reset by updates. Effect unclear.
3. **Group Policy "Fully disable Search UI"**: Only available on Pro/Enterprise. Registry equivalent (`DisableSearch=1`) unconfirmed to actually stop the process on Home.

**Current policy:** Apply all the registry/policy settings below (they reduce web traffic and content loading even if they don't kill the process), but **do NOT promise MB savings from SearchHost elimination** and **do NOT recommend renaming the exe** (breaks search, undone by updates).

**Settings still worth applying** (reduce web traffic, not process memory):
- `SearchboxTaskbarMode = 0` — hides search box from taskbar
- `DisableWebSearch = 1` — prevents web queries
- `BingSearchEnabled = 0` — disables Bing integration
- `WSearch = Disabled` — stops background indexing (saves CPU/disk, not SearchHost memory)

**Explorer restart**: The cleanup script restarts explorer.exe after applying taskbar registry changes, causing a brief (~2 second) taskbar flicker. This avoids requiring a full reboot.

### Irreducible Shell Baseline (updated 2026-04) — NEVER promise savings here
These processes are baked into the Windows 11 shell and **cannot be cleanly eliminated**. Do NOT recommend killing, renaming, or disabling them. Do NOT include them in "estimated MB savings."

| Process | Typical MB | Why it's untouchable |
|---------|-----------|----------------------|
| `SearchHost.exe` + WebView2 children | 350-500 | Shell-integrated UWP; Start Menu depends on it. No clean disable on Win11 Home. See "Search Webview Elimination" section. |
| `TextInputHost.exe` | 150-200 | Windows Input Experience — handles emoji panel (Win+.), touch keyboard, and input for XAML/UWP apps. Disabling via `IsInputAppPreloadEnabled=0` only prevents preload; it respawns on demand. Renaming/deleting **breaks terminal input and emoji panel**. |
| `StartMenuExperienceHost.exe` | 100-170 | Start Menu itself. Killing it crashes the Start Menu. |
| `ShellExperienceHost.exe` | 80-100 | Action Center, notifications, taskbar widgets host. Core shell. |
| `ShellHost.exe` | 100-150 | Shell infrastructure. |
| `dwm.exe` (Desktop Window Manager) | 100-160 | Compositing engine. Cannot be disabled. |
| `explorer.exe` | 150-250 | Windows shell. Killing it removes the taskbar. |

**When the scan shows these, report them as "shell baseline — no action possible" rather than suggesting they can be killed.**

### Startup — minimal policy
- **Keep:** OneDrive, SecurityHealth, GlobalProtect
- **Remove:** RtkAudUService (Realtek audio tray — removed from HKLM\Run, audio unaffected)
- **Flag everything else** for user approval before removing

### Defender exclusions (require admin)
**Include:**
- WSL package paths (`CanonicalGroupLimited.Ubuntu_*`, `MicrosoftCorporationII.WindowsSubsystemForLinux_*`)
- WSL temp: `AppData\Local\Temp\wsl`
- WSL processes: `vmmem`, `wslservice.exe`, `wsl.exe`, `wslhost.exe`
- `.dotnet`, `.nuget` caches
- `~/dev` folder

**NEVER exclude (supply-chain risk):**
- `node_modules`
- npm caches
- Any JavaScript-related folders

## Procedure

### Phase 1: Scan
Run the scan script from this skill's folder:
```
powershell -ExecutionPolicy Bypass -File "<skill-dir>\scripts\scan-memory.ps1"
```
Use the `powershell -File - <<'PS1'` heredoc pattern from bash to avoid `$_` interpolation issues.

### Phase 2: Analyze
Compare scan output against the preferences above. Group recommendations into categories:
1. **Services to disable** (with current status + estimated MB savings)
2. **UI bloat to disable** (Widgets, Copilot, Bing — with webview MB savings)
3. **Startup apps to remove** (anything beyond OneDrive + SecurityHealth)
4. **Processes to kill now** (non-protected, high-memory, non-essential — **exclude irreducible shell baseline**)
5. **Defender exclusions to add** (only if not already present)
6. **Webview analysis** (grouped by root parent, with MB totals)
7. **CrossDeviceService UWP removal** (if CrossDeviceService.exe is running)
8. **Shell baseline report** — list irreducible processes with their MB and mark as "no action possible"

**IMPORTANT:** When all actionable items are already applied, be honest. Do not suggest killing shell processes (SearchHost, TextInputHost, StartMenuExperienceHost, etc.) as if they can be permanently eliminated. Report them as irreducible baseline.

### Phase 3: Present
Show a findings table to the user with:
- Category, item, current state, recommended action, estimated MB savings

### Phase 4: Ask Approval
Use the interactive prompt to list each change group. Let the user approve or reject each group independently. Respect "no" — do not re-ask.

### Phase 5: Execute
All changes go through the parameterized `apply-cleanup.ps1` script, which requires admin elevation.

Available flags (combine as needed based on user approval):
- `-DisableServices` — permanently disable SysMain, DiagTrack, PhoneSvc + kill their processes
- `-RemoveCrossDeviceApp` — uninstall Cross Device Experience Host UWP app + provisioned package + disable scheduled tasks + kill process (admin). This is the correct way to eliminate CrossDeviceService — it's a UWP app, not a Windows service.
- `-DisableStartup` — remove RtkAudUService (and any future flagged items) from HKLM\Run
- `-DisableSearchWebviews` — hide taskbar search box, disable WSearch indexing service, apply web/cloud search policies, restart explorer. **Note: this reduces web traffic and CPU from indexing but does NOT eliminate SearchHost.exe or its webviews** — those are shell-integrated and respawn after reboot. Do not promise MB savings from this flag for SearchHost.
- `-KillProcesses` — kill non-essential bloat processes (PhoneExperienceHost, MicrosoftStartFeedProvider, backgroundTaskHost, etc.)
- `-DisableUI` — disable Widgets, Copilot, Bing in Start, feed scheduled tasks
- `-DenyBackgroundApps` — deny background access for all non-allowlisted UWP apps (no admin required)
- `-DisablePerUserServices` — disable per-user service templates (cbdhsvc, CDPUserSvc, etc.) and kill PhoneExperienceHost (admin)
- `-DisableScheduledTasks` — disable BraveSoftware updater tasks and other non-essential scheduled tasks (admin)
- `-SetVendorServicesManual` — set DolbyDAXAPI and IntelGraphicsSoftwareService to Manual (admin)

Launch elevated with only the approved flags. Write the script file first, then elevate:
```
powershell -ExecutionPolicy Bypass -File - <<'PS1'
Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File <skill-dir>\scripts\apply-cleanup.ps1 -DisableServices -DisableStartup -DisableSearchWebviews -KillProcesses' -Wait
PS1
```

**IMPORTANT**: Use the `powershell -File - <<'PS1'` heredoc pattern from bash to avoid `$` interpolation issues when calling PowerShell from bash.

### Phase 6: Final Report
Re-run `scan-memory.ps1`, then show:
- Before/after memory comparison (total used, free)
- Table of all services checked with current status
- Table of startup apps with status
- Webview summary grouped by parent
