# ==========================================================
# Memory Scan Script — Collects system memory data
# Part of /reduce-memory-footprint skill
# ==========================================================

$ErrorActionPreference = "Continue"

# --- Total / Used / Free RAM ---
Write-Host "`n=== MEMORY OVERVIEW ===" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$usedGB  = $totalGB - $freeGB
Write-Host "Total: ${totalGB} GB | Used: ${usedGB} GB | Free: ${freeGB} GB"

# --- Top 30 processes grouped by name ---
Write-Host "`n=== TOP 30 PROCESSES (grouped by name, total MB) ===" -ForegroundColor Cyan
Get-Process |
    Group-Object Name |
    Sort-Object @{E={($_.Group | Measure-Object WorkingSet64 -Sum).Sum}} -Descending |
    Select-Object -First 30 Count, Name,
        @{N='TotalMB';E={[math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB,1)}} |
    Format-Table -AutoSize

# --- Top 20 individual processes by working set ---
Write-Host "=== TOP 20 INDIVIDUAL PROCESSES (by working set) ===" -ForegroundColor Cyan
Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 20 Name, Id,
        @{N='MB';E={[math]::Round($_.WorkingSet64/1MB,1)}},
        @{N='PM_MB';E={[math]::Round($_.PrivateMemorySize64/1MB,1)}} |
    Format-Table -AutoSize

# --- svchost service mapping (top 15 by memory) ---
Write-Host "=== TOP 15 SVCHOST PROCESSES (with services) ===" -ForegroundColor Cyan
$svcProcs = Get-Process svchost -ErrorAction SilentlyContinue |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 15
foreach ($p in $svcProcs) {
    $mb = [math]::Round($p.WorkingSet64/1MB, 1)
    $svcs = Get-CimInstance Win32_Service -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty DisplayName
    $svcList = ($svcs -join ', ')
    if (-not $svcList) { $svcList = '(no services found)' }
    Write-Output "  PID $($p.Id) [$mb MB]: $svcList"
}

# --- Webview parent chain tracing ---
Write-Host "`n=== MSEDGEWEBVIEW2 PARENT CHAINS ===" -ForegroundColor Cyan
$allProcs = Get-CimInstance Win32_Process
$procMap = @{}
foreach ($p in $allProcs) { $procMap[[int]$p.ProcessId] = $p }

$webviews = @($allProcs | Where-Object { $_.Name -eq "msedgewebview2.exe" })
if ($webviews.Count -eq 0) {
    Write-Host "  No msedgewebview2.exe processes found."
} else {
    # Group by root parent
    $groups = @{}
    foreach ($wv in $webviews) {
        $current = $wv
        $rootParent = "UNKNOWN"
        for ($i = 0; $i -lt 20; $i++) {
            $ppid = [int]$current.ParentProcessId
            if ($procMap.ContainsKey($ppid) -and $procMap[$ppid].Name -ne "msedgewebview2.exe") {
                $rootParent = $procMap[$ppid].Name
                break
            } elseif ($procMap.ContainsKey($ppid)) {
                $current = $procMap[$ppid]
            } else {
                $rootParent = "DEAD($ppid)"
                break
            }
        }
        $mb = [math]::Round($wv.WorkingSetSize / 1MB, 1)
        if (-not $groups.ContainsKey($rootParent)) {
            $groups[$rootParent] = @{ Count = 0; TotalMB = 0 }
        }
        $groups[$rootParent].Count++
        $groups[$rootParent].TotalMB += $mb
    }
    Write-Host "  Total webview instances: $($webviews.Count)"
    Write-Host ""
    foreach ($key in $groups.Keys | Sort-Object { $groups[$_].TotalMB } -Descending) {
        $g = $groups[$key]
        Write-Host "  $key : $($g.Count) instances, $([math]::Round($g.TotalMB,1)) MB"
    }
}

# --- Startup apps ---
Write-Host "`n=== STARTUP APPS ===" -ForegroundColor Cyan
Write-Host "  Registry (HKCU\Run):" -ForegroundColor Yellow
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$props = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
if ($props) {
    $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
        Write-Host "    $($_.Name) = $($_.Value)"
    }
} else {
    Write-Host "    (none)"
}

Write-Host "  Startup folder:" -ForegroundColor Yellow
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupItems = Get-ChildItem $startupFolder -ErrorAction SilentlyContinue
if ($startupItems) {
    foreach ($item in $startupItems) { Write-Host "    $($item.Name)" }
} else {
    Write-Host "    (empty)"
}

Write-Host "  WMI StartupCommand:" -ForegroundColor Yellow
Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    $($_.Name) [$($_.Location)]: $($_.Command)" }

# --- Known-bloat service status ---
Write-Host "`n=== KNOWN-BLOAT SERVICE STATUS ===" -ForegroundColor Cyan
$bloatServices = @("SysMain", "DiagTrack", "PhoneSvc", "RtkAudioUniversalService", "WSearch")
foreach ($svcName in $bloatServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  $svcName : StartType=$($svc.StartType), Status=$($svc.Status)"
    } else {
        Write-Host "  $svcName : NOT FOUND"
    }
}

# --- CrossDevice UWP App Status ---
# Note: CrossDeviceService is a UWP app, NOT a Windows service.
# Disabling PhoneSvc does NOT stop it.
Write-Host "`n=== CROSS DEVICE EXPERIENCE HOST (UWP App) ===" -ForegroundColor Cyan
$cdProcess = Get-Process -Name "CrossDeviceService" -ErrorAction SilentlyContinue
if ($cdProcess) {
    $cdMB = [math]::Round(($cdProcess | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
    Write-Host "  Process: RUNNING ($cdMB MB)" -ForegroundColor Yellow
} else {
    Write-Host "  Process: not running" -ForegroundColor Green
}
$cdPkg = Get-AppxPackage -Name "*CrossDevice*" -ErrorAction SilentlyContinue
if ($cdPkg) {
    Write-Host "  AppxPackage: INSTALLED ($($cdPkg.Name) v$($cdPkg.Version))" -ForegroundColor Yellow
} else {
    Write-Host "  AppxPackage: not installed" -ForegroundColor Green
}
$cdTasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\CrossDevice\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Disabled' }
if ($cdTasks) {
    Write-Host "  Scheduled tasks: $($cdTasks.Count) ACTIVE" -ForegroundColor Yellow
} else {
    Write-Host "  Scheduled tasks: none active" -ForegroundColor Green
}

# --- Irreducible Shell Baseline ---
# These processes CANNOT be permanently eliminated on Win11 Home.
# Report them for awareness only — no action is possible.
Write-Host "`n=== IRREDUCIBLE SHELL BASELINE (no action possible) ===" -ForegroundColor Cyan
$shellProcesses = @('SearchHost', 'TextInputHost', 'StartMenuExperienceHost', 'ShellExperienceHost', 'ShellHost', 'dwm', 'explorer')
foreach ($name in $shellProcesses) {
    $proc = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($proc) {
        $mb = [math]::Round(($proc | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        # Include webview children for SearchHost
        $wvMB = 0
        if ($name -eq 'SearchHost') {
            $wvProcs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "msedgewebview2.exe" }
            $searchPid = $proc.Id
            foreach ($wv in $wvProcs) {
                $cur = $wv
                for ($i = 0; $i -lt 20; $i++) {
                    $pp = [int]$cur.ParentProcessId
                    if ($procMap.ContainsKey($pp) -and $procMap[$pp].Name -ne "msedgewebview2.exe") {
                        if ($procMap[$pp].Name -eq "SearchHost.exe") {
                            $wvMB += [math]::Round($wv.WorkingSetSize / 1MB, 1)
                        }
                        break
                    } elseif ($procMap.ContainsKey($pp)) { $cur = $procMap[$pp] }
                    else { break }
                }
            }
        }
        $extra = if ($wvMB -gt 0) { " + $wvMB MB webviews" } else { "" }
        Write-Host "  $name : $mb MB$extra" -ForegroundColor DarkGray
    }
}
$shellTotal = ($shellProcesses | ForEach-Object {
    $p = Get-Process -Name $_ -ErrorAction SilentlyContinue
    if ($p) { ($p | Measure-Object WorkingSet64 -Sum).Sum } else { 0 }
} | Measure-Object -Sum).Sum / 1MB
Write-Host "  Shell baseline total: $([math]::Round($shellTotal, 0)) MB (cannot be reduced)" -ForegroundColor DarkGray

# --- Defender exclusions (requires admin, graceful fallback) ---
Write-Host "`n=== DEFENDER EXCLUSIONS ===" -ForegroundColor Cyan
try {
    $prefs = Get-MpPreference -ErrorAction Stop
    Write-Host "  Path exclusions:" -ForegroundColor Yellow
    if ($prefs.ExclusionPath) {
        foreach ($p in $prefs.ExclusionPath) { Write-Host "    $p" }
    } else {
        Write-Host "    (none)"
    }
    Write-Host "  Process exclusions:" -ForegroundColor Yellow
    if ($prefs.ExclusionProcess) {
        foreach ($p in $prefs.ExclusionProcess) { Write-Host "    $p" }
    } else {
        Write-Host "    (none)"
    }
} catch {
    Write-Host "  (Requires admin privileges to read - skipped)" -ForegroundColor DarkYellow
}

# --- Registry: Widgets, Copilot, Bing Search ---
Write-Host "`n=== UI BLOAT REGISTRY STATUS ===" -ForegroundColor Cyan
$adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

$taskbarDa = (Get-ItemProperty -Path $adv -Name "TaskbarDa" -ErrorAction SilentlyContinue).TaskbarDa
$copilotBtn = (Get-ItemProperty -Path $adv -Name "ShowCopilotButton" -ErrorAction SilentlyContinue).ShowCopilotButton

$policyPath = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"
$copilotPolicy = $null
if (Test-Path $policyPath) {
    $copilotPolicy = (Get-ItemProperty -Path $policyPath -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
}

$searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$bingSearch = (Get-ItemProperty -Path $searchKey -Name "BingSearchEnabled" -ErrorAction SilentlyContinue).BingSearchEnabled

Write-Host "  Widgets (TaskbarDa):        $(if ($null -eq $taskbarDa) {'NOT SET'} elseif ($taskbarDa -eq 0) {'DISABLED'} else {'ENABLED'})"
Write-Host "  Copilot button:             $(if ($null -eq $copilotBtn) {'NOT SET'} elseif ($copilotBtn -eq 0) {'HIDDEN'} else {'VISIBLE'})"
Write-Host "  Copilot policy:             $(if ($null -eq $copilotPolicy) {'NOT SET'} elseif ($copilotPolicy -eq 1) {'DISABLED'} else {'ENABLED'})"
Write-Host "  Bing in Start search:       $(if ($null -eq $bingSearch) {'NOT SET'} elseif ($bingSearch -eq 0) {'DISABLED'} else {'ENABLED'})"

$searchboxMode = (Get-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -ErrorAction SilentlyContinue).SearchboxTaskbarMode
$searchboxModeText = switch ($searchboxMode) {
    0 { 'HIDDEN (SearchHost still runs — shell-integrated, cannot be eliminated)' }
    1 { 'ICON ONLY' }
    2 { 'FULL SEARCH BOX' }
    default { 'NOT SET (defaults to search box)' }
}
$searchboxColor = if ($searchboxMode -eq 0) { 'Green' } elseif ($null -eq $searchboxMode -or $searchboxMode -eq 2) { 'Red' } else { 'Yellow' }
Write-Host "  Search box (TaskbarMode):   $searchboxModeText" -ForegroundColor $searchboxColor

$searchPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
$disableWebSearch = (Get-ItemProperty -Path $searchPolicyPath -Name "DisableWebSearch" -ErrorAction SilentlyContinue).DisableWebSearch
Write-Host "  Web search policy:          $(if ($null -eq $disableWebSearch) {'NOT SET (web search active)'} elseif ($disableWebSearch -eq 1) {'DISABLED'} else {'ENABLED'})" -ForegroundColor $(if ($disableWebSearch -eq 1) { 'Green' } else { 'Yellow' })

# --- Background App Permissions ---
Write-Host "`n=== BACKGROUND APP PERMISSIONS ===" -ForegroundColor Cyan
$bgPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"
if (Test-Path $bgPath) {
    $bgApps = Get-ChildItem -Path $bgPath -ErrorAction SilentlyContinue
    $allowed = 0
    $denied = 0
    $bloatApps = @()

    # Allowlist prefixes — shell infra, protected apps, auth, frameworks, utilities
    $allowlist = @(
        'Microsoft.Windows.ShellExperienceHost_',
        'Microsoft.Windows.StartMenuExperienceHost_',
        'windows.immersivecontrolpanel_',
        'Microsoft.AAD.BrokerPlugin_',
        'Microsoft.Windows.CloudExperienceHost_',
        'MicrosoftWindows.Client.CBS_',
        'Microsoft.WindowsAppRuntime.',
        'Microsoft.VCLibs.',
        'Microsoft.UI.Xaml.',
        'Microsoft.NET.Native.',
        'Microsoft.Services.Store.Engagement_',
        'AgileBits.1Password_',
        'Microsoft.OneDriveSync_',
        'Microsoft.VisualStudioCode',
        'MicrosoftCorporationII.WindowsSubsystemForLinux_',
        'CanonicalGroupLimited.Ubuntu_',
        'Microsoft.WindowsTerminal_',
        'Microsoft.DesktopAppInstaller_',
        'Microsoft.CompanyPortal_',
        'Microsoft.Windows.OOBENetworkCaptivePortal_',
        'Microsoft.Windows.OOBENetworkConnectionFlow_',
        'Microsoft.WindowsStore_',
        'Microsoft.StorePurchaseApp_',
        'Microsoft.WindowsCalculator_',
        'Microsoft.WindowsNotepad_',
        'Microsoft.WindowsCamera_',
        'Microsoft.Paint_',
        'Microsoft.ScreenSketch_',
        'Microsoft.Windows.Photos_'
    )

    foreach ($app in $bgApps) {
        $disabled = (Get-ItemProperty -Path $app.PSPath -Name "Disabled" -ErrorAction SilentlyContinue).Disabled
        $pkgName = $app.PSChildName
        if ($disabled -eq 1) {
            $denied++
        } else {
            $allowed++
            $isAllowlisted = $false
            foreach ($prefix in $allowlist) {
                if ($pkgName -like "$prefix*") { $isAllowlisted = $true; break }
            }
            if (-not $isAllowlisted) {
                $bloatApps += $pkgName
            }
        }
    }

    Write-Host "  Total: $($bgApps.Count) | Allowed: $allowed | Denied: $denied" -ForegroundColor $(if ($allowed -gt 20) { 'Red' } else { 'Green' })
    if ($bloatApps.Count -gt 0) {
        Write-Host "  Non-allowlisted apps with background access ($($bloatApps.Count)):" -ForegroundColor Yellow
        foreach ($b in ($bloatApps | Sort-Object)) {
            Write-Host "    $b"
        }
    }
} else {
    Write-Host "  BackgroundAccessApplications registry key not found" -ForegroundColor DarkYellow
}

# --- Per-User Services ---
Write-Host "`n=== PER-USER SERVICES ===" -ForegroundColor Cyan
$perUserTemplates = @("cbdhsvc", "CDPUserSvc", "DevicesFlowUserSvc", "MessagingService")
foreach ($template in $perUserTemplates) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$template"
    if (Test-Path $regPath) {
        $startVal = (Get-ItemProperty -Path $regPath -Name "Start" -ErrorAction SilentlyContinue).Start
        $startText = switch ($startVal) { 2 {"Automatic"} 3 {"Manual"} 4 {"Disabled"} default {"Unknown($startVal)"} }
        Write-Host "  Template $template : Start=$startText" -ForegroundColor $(if ($startVal -eq 4) { 'Green' } else { 'Yellow' })
    } else {
        Write-Host "  Template $template : NOT FOUND" -ForegroundColor DarkGray
    }
}
# Show running per-user service instances (pattern: name_hexsuffix)
Write-Host "  Running per-user instances:" -ForegroundColor Yellow
$perUserRunning = Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(cbdhsvc|CDPUserSvc|DevicesFlowUserSvc|MessagingService)_[0-9a-f]+$' -and $_.Status -eq 'Running'
}
if ($perUserRunning) {
    foreach ($s in $perUserRunning) {
        Write-Host "    $($s.Name) : $($s.Status)"
    }
} else {
    Write-Host "    (none running)" -ForegroundColor Green
}

# --- Scheduled Tasks (non-Microsoft) ---
Write-Host "`n=== SCHEDULED TASKS (NON-MICROSOFT) ===" -ForegroundColor Cyan
$nonMsTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' }
if ($nonMsTasks) {
    foreach ($t in $nonMsTasks) {
        $flag = if ($t.TaskPath -like '*BraveSoftware*' -or $t.TaskName -like '*Brave*') { ' [RECOMMEND DISABLE]' } else { '' }
        Write-Host "  $($t.TaskPath)$($t.TaskName) : $($t.State)$flag" -ForegroundColor $(if ($flag) { 'Yellow' } else { 'White' })
    }
} else {
    Write-Host "  (none active)" -ForegroundColor Green
}

# --- Vendor/OEM Services ---
Write-Host "`n=== VENDOR/OEM SERVICES ===" -ForegroundColor Cyan
$vendorServices = @(
    @{ Name = "DolbyDAXAPI";                  Recommend = "Manual"; Critical = $false },
    @{ Name = "IntelGraphicsSoftwareService"; Recommend = "Manual"; Critical = $false },
    @{ Name = "cplspcon";                     Recommend = "Leave";  Critical = $true },
    @{ Name = "IntelAudioService";            Recommend = "Leave";  Critical = $true }
)
foreach ($vs in $vendorServices) {
    $svc = Get-Service -Name $vs.Name -ErrorAction SilentlyContinue
    if ($svc) {
        $action = if ($vs.Critical) { "(hardware-critical, leave alone)" } elseif ($svc.StartType -ne $vs.Recommend) { "[SET TO $($vs.Recommend)]" } else { "(OK)" }
        $color = if ($vs.Critical) { 'DarkGray' } elseif ($svc.StartType -ne $vs.Recommend) { 'Yellow' } else { 'Green' }
        Write-Host "  $($vs.Name) : StartType=$($svc.StartType), Status=$($svc.Status) $action" -ForegroundColor $color
    } else {
        Write-Host "  $($vs.Name) : NOT FOUND" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== SCAN COMPLETE ===" -ForegroundColor Green
