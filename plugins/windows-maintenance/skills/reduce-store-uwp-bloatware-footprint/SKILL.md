---
name: reduce-store-uwp-bloatware-footprint
description: List, categorize, and remove pre-installed Microsoft Store/UWP bloatware apps on Windows. Shows safe-to-remove vs potential removals, manages a whitelist of kept apps, and interactively removes selected apps.
license: Apache-2.0
compatibility: Requires Windows with PowerShell and permission to remove Appx/UWP packages.
disable-model-invocation: true
allowed-tools: Bash(powershell.exe *)
---

# Reduce Store/UWP Bloatware Footprint

Remove pre-installed Microsoft Store and UWP bloatware apps from Windows.

## Step 1: Gather installed apps

Run this PowerShell command to get all installed UWP apps:

```
powershell.exe -NoProfile -Command "Get-AppxPackage | Select-Object Name | Sort-Object Name | Format-Table -AutoSize"
```

## Step 2: Categorize apps into three tables

From the full list, filter out system/framework packages (anything that is clearly a runtime, framework, codec, shell component, or system infrastructure). Then categorize the remaining user-facing apps into three markdown tables:

### Table 1: Safe to Remove

These are apps that are universally considered bloatware and have no system dependencies. Include apps like:

- `Microsoft.BingNews` — Bing News
- `Microsoft.BingWeather` — Bing Weather
- `Microsoft.BingSearch` — Bing Search
- `Microsoft.MicrosoftSolitaireCollection` — Solitaire
- `Microsoft.MicrosoftJournal` — Journal
- `Microsoft.Whiteboard` — Whiteboard
- `Microsoft.WindowsMaps` — Maps
- `Microsoft.People` — People
- `Microsoft.PowerAutomateDesktop` — Power Automate
- `Microsoft.Edge.GameAssist` — Edge Game Assist
- `Microsoft.ZuneVideo` — Movies & TV
- `Clipchamp.Clipchamp` — Clipchamp video editor
- `MicrosoftCorporationII.MicrosoftFamily` — Microsoft Family
- `MicrosoftCorporationII.QuickAssist` — Quick Assist
- `Microsoft.Todos` — Microsoft To Do
- `Microsoft.MicrosoftStickyNotes` — Sticky Notes
- `MicrosoftWindows.Client.WebExperience` — Widgets news feed

Also include any other third-party Store apps or Microsoft apps that are clearly non-essential bloatware (e.g. gaming promos, social apps, trial software). Use your judgment — if it's a pre-installed app the user didn't ask for and it's not a system component, it belongs here.

### Table 2: Potential Removals (use caution)

Apps that *could* be removed but may affect functionality some users rely on. Examples:

- `Microsoft.YourPhone` — Phone Link (cross-device features)
- `Microsoft.GamingApp` — Xbox/Gaming hub (needed for Game Pass)
- `Microsoft.ZuneMusic` — Groove Music / media player
- `Microsoft.OutlookForWindows` — Outlook (if user prefers browser mail)
- `MSTeams` — Teams (if user doesn't use it)
- `Microsoft.Windows.DevHome` — Dev Home
- `MicrosoftWindows.CrossDevice` — Cross-device experience

For each app in this table, include a brief note explaining what might break or be lost if removed.

### Table 3: Whitelist (explicitly kept)

These apps have been marked as "keep" by the user. They will NOT be removed even if they appear bloat-like:

| Package Name | Common Name | Reason Kept |
|---|---|---|
| `Microsoft.WindowsSoundRecorder` | Audio Recorder | User uses it |
| `Microsoft.WindowsCamera` | Camera | User uses it |
| `Microsoft.SurfaceHub` | Surface Hub | Surface laptop support |
| `Microsoft.SurfaceAppProxy` | Surface App Proxy | Surface laptop support |
| `Microsoft.SurfaceDiagnostics` | Surface Diagnostics | Surface laptop support |
| `Microsoft.WindowsFeedbackHub` | Feedback Hub | User wants to keep |
| `Microsoft.GetHelp` | Get Help | User wants to keep |
| `Microsoft.MicrosoftOfficeHub` | Office Hub | User wants to keep |

## Step 3: Ask about the whitelist

Use AskUserQuestion to ask the user:

> Here's your current whitelist of protected apps (these will NOT be removed):
>
> [display the whitelist table]
>
> Would you like to change this whitelist? You can:
> - **Add** apps to protect them from removal
> - **Remove** apps from the whitelist so they can be uninstalled
> - **Keep as-is** to proceed
>
> Reply with changes or "keep as-is".

If the user makes changes, update the whitelist accordingly before proceeding.

## Step 4: Present the removal tables

Display Tables 1 and 2 to the user. Format each table with columns:

| Package Name | Common Name | Status |
|---|---|---|

Where Status is either "Installed" or "Already removed" based on the scan from Step 1.

Only show apps that are currently **Installed** — skip ones already removed.

## Step 5: Ask what to remove

Use AskUserQuestion to ask the user which apps to remove:

> Which apps would you like to remove?
> - **"all safe"** — Remove everything in the Safe to Remove table
> - **"all"** — Remove everything in both tables
> - **Pick specific apps** — List the names or numbers you want removed
> - **"none"** — Cancel

## Step 6: Execute removal

For each selected app, run:

```
powershell.exe -NoProfile -Command "Get-AppxPackage '<PackageName>' | Remove-AppxPackage"
```

Report success/failure for each app.

## Step 7: Verify

Run the full app list again and confirm the selected apps are no longer present:

```
powershell.exe -NoProfile -Command "Get-AppxPackage | Select-Object Name | Sort-Object Name | Format-Table -AutoSize"
```

Summarize what was removed and what remains.

## Important Notes

- All removals are **reversible** — apps can be reinstalled from the Microsoft Store.
- Never remove system framework packages (UI.Xaml, VCLibs, .NET Native, WinAppRuntime, etc.).
- Never remove shell components (ShellExperienceHost, StartMenuExperienceHost, LockApp, etc.).
- When in doubt about an app, put it in "Potential Removals" not "Safe to Remove".
