# ==========================================================
# Apply Cleanup Script - Requires admin for service/registry changes
# Part of /reduce-memory-footprint skill
#
# Usage (elevated):
#   .\apply-cleanup.ps1 -DisableServices -DisableStartup -DisableSearchWebviews -KillProcesses -DisableUI
#
# All flags are optional. Only approved sections run.
# ==========================================================
param(
    [switch]$DisableServices,
    [switch]$DisableStartup,
    [switch]$DisableSearchWebviews,
    [switch]$KillProcesses,
    [switch]$DisableUI,
    [switch]$DenyBackgroundApps,
    [switch]$DisablePerUserServices,
    [switch]$DisableScheduledTasks,
    [switch]$SetVendorServicesManual,
    [switch]$RemoveCrossDeviceApp
)

$ErrorActionPreference = "Continue"

Write-Host "`n=== APPLY CLEANUP (Admin) ===" -ForegroundColor Cyan

# -------------------------------------------------------
# 1. Disable bloat services permanently
# -------------------------------------------------------
if ($DisableServices) {
    Write-Host "`n--- Disabling Services ---" -ForegroundColor Yellow

    # Note: CrossDeviceService is a UWP app, not a Windows service.
    # Use -RemoveCrossDeviceApp flag instead.
    $services = @(
        @{ Name = "SysMain";            Display = "Superfetch" },
        @{ Name = "DiagTrack";          Display = "Telemetry" },
        @{ Name = "PhoneSvc";           Display = "Phone Link telephony" }
    )

    foreach ($s in $services) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $s.Name -StartupType Disabled
                # Also set via registry for robustness
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
                if (Test-Path $regPath) {
                    Set-ItemProperty -Path $regPath -Name "Start" -Value 4
                }
                Write-Host "  $($s.Name) ($($s.Display)): DISABLED" -ForegroundColor Green
            } catch {
                Write-Host "  $($s.Name): FAILED - $_" -ForegroundColor Red
            }
        } else {
            Write-Host "  $($s.Name): not found (OK)" -ForegroundColor DarkGray
        }
    }

    # Kill associated processes that may linger
    @('PhoneExperienceHost', 'CrossDeviceService', 'YourPhoneServer') | ForEach-Object {
        $p = Get-Process -Name $_ -ErrorAction SilentlyContinue
        if ($p) {
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed process: $_" -ForegroundColor Green
        }
    }
}

# -------------------------------------------------------
# 2. Remove non-essential startup apps
# -------------------------------------------------------
if ($DisableStartup) {
    Write-Host "`n--- Disabling Startup Apps ---" -ForegroundColor Yellow

    # HKLM Run entries to remove
    $hklmRun = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $removeFromHKLM = @("RtkAudUService")

    foreach ($name in $removeFromHKLM) {
        $val = Get-ItemProperty -Path $hklmRun -Name $name -ErrorAction SilentlyContinue
        if ($val) {
            Remove-ItemProperty -Path $hklmRun -Name $name -ErrorAction SilentlyContinue
            Write-Host "  Removed ${name} from HKLM Run" -ForegroundColor Green
        } else {
            Write-Host "  ${name}: not in HKLM Run (already removed)" -ForegroundColor DarkGray
        }
    }

    # Disable the Realtek background service (audio still works without it)
    $rtkSvc = Get-Service -Name "RtkAudioUniversalService" -ErrorAction SilentlyContinue
    if ($rtkSvc -and $rtkSvc.StartType -ne 'Disabled') {
        Stop-Service -Name "RtkAudioUniversalService" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "RtkAudioUniversalService" -StartupType Disabled
        $rtkReg = "HKLM:\SYSTEM\CurrentControlSet\Services\RtkAudioUniversalService"
        if (Test-Path $rtkReg) { Set-ItemProperty -Path $rtkReg -Name "Start" -Value 4 }
        Write-Host "  RtkAudioUniversalService set to Disabled" -ForegroundColor Green
    }

    # Kill the process too
    Stop-Process -Name "RtkAudUService64" -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------
# 3. Disable SearchHost webview bloat permanently
# -------------------------------------------------------
if ($DisableSearchWebviews) {
    Write-Host "`n--- Eliminating Search Webviews Permanently ---" -ForegroundColor Yellow

    # ---- Root cause: hide taskbar search box ----
    # SearchboxTaskbarMode: 0=Hidden, 1=Icon, 2=SearchBox
    # Mode 0 prevents SearchHost from spawning webviews entirely.
    # Search still works via Win+S or Win key + typing.
    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value 0 -Type DWord
    Write-Host "  SearchboxTaskbarMode = 0 (hidden)" -ForegroundColor Green

    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarModeCache" -Value 0 -Type DWord
    Write-Host "  SearchboxTaskbarModeCache = 0 (cleared)" -ForegroundColor Green

    # ---- User-level: disable dynamic search box + cloud search ----
    $searchSettings = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings"
    if (!(Test-Path $searchSettings)) { New-Item -Path $searchSettings -Force | Out-Null }
    Set-ItemProperty -Path $searchSettings -Name "IsDynamicSearchBoxEnabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchSettings -Name "IsMSACloudSearchEnabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchSettings -Name "IsAADCloudSearchEnabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchSettings -Name "IsDeviceSearchHistoryEnabled" -Value 0 -Type DWord
    Write-Host "  Dynamic search, cloud search, search history = 0" -ForegroundColor Green

    # ---- Machine policy: disable dynamic content + web search + highlights ----
    $searchPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    if (!(Test-Path $searchPolicy)) { New-Item -Path $searchPolicy -Force | Out-Null }
    Set-ItemProperty -Path $searchPolicy -Name "EnableDynamicContentInWSB" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "DisableWebSearch" -Value 1 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "AllowSearchHighlights" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "ConnectedSearchUseWeb" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "AllowCloudSearch" -Value 0 -Type DWord
    Set-ItemProperty -Path $searchPolicy -Name "AllowCortana" -Value 0 -Type DWord
    Write-Host "  Search policies applied (HKLM) - web/cloud/highlights/cortana all disabled" -ForegroundColor Green

    # ---- Disable WSearch service entirely ----
    # Manual still gets auto-triggered; Disabled prevents indexing.
    # Search still works (live file system scan), just slower results.
    try {
        Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "WSearch" -StartupType Disabled
        $wsearchReg = "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch"
        if (Test-Path $wsearchReg) {
            Set-ItemProperty -Path $wsearchReg -Name "Start" -Value 4
        }
        Write-Host "  WSearch service: DISABLED and stopped" -ForegroundColor Green
    } catch {
        Write-Host "  WSearch: $_" -ForegroundColor Red
    }

    # ---- Kill SearchHost ----
    Stop-Process -Name "SearchHost" -Force -ErrorAction SilentlyContinue
    Write-Host "  SearchHost killed" -ForegroundColor Green

    # ---- Restart explorer to apply taskbar changes immediately ----
    Write-Host "  Restarting explorer.exe to apply taskbar changes..." -ForegroundColor Yellow
    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process "explorer.exe"
    Write-Host "  Explorer restarted - search box hidden" -ForegroundColor Green

    # ---- Wait for SearchHost to respawn, then kill it and its webviews ----
    Start-Sleep -Seconds 5
    $shProc = Get-Process -Name "SearchHost" -ErrorAction SilentlyContinue
    if ($shProc) {
        # Kill all webview2 processes parented by SearchHost
        $allCim = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "msedgewebview2.exe" }
        $cimMap = @{}
        Get-CimInstance Win32_Process | ForEach-Object { $cimMap[[int]$_.ProcessId] = $_ }
        foreach ($wv in $allCim) {
            $cur = $wv
            for ($i = 0; $i -lt 20; $i++) {
                $pp = [int]$cur.ParentProcessId
                if ($cimMap.ContainsKey($pp) -and $cimMap[$pp].Name -ne "msedgewebview2.exe") {
                    if ($cimMap[$pp].Name -eq "SearchHost.exe") {
                        Stop-Process -Id $wv.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                    break
                } elseif ($cimMap.ContainsKey($pp)) { $cur = $cimMap[$pp] }
                else { break }
            }
        }
        Stop-Process -Name "SearchHost" -Force -ErrorAction SilentlyContinue
        Write-Host "  Killed SearchHost and its webview children" -ForegroundColor Green
    }
}

# -------------------------------------------------------
# 4. Kill non-essential processes (immediate, non-permanent)
# -------------------------------------------------------
if ($KillProcesses) {
    Write-Host "`n--- Killing Bloat Processes ---" -ForegroundColor Yellow

    $targets = @(
        'PhoneExperienceHost',
        'CrossDeviceService',
        'MicrosoftStartFeedProvider',
        'backgroundTaskHost',
        'RtkAudUService64',
        'YourPhoneServer'
    )

    foreach ($name in $targets) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            $count = $procs.Count
            $mb = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed $name ($count instance(s), $mb MB)" -ForegroundColor Green
        }
    }
}

# -------------------------------------------------------
# 5. Disable UI bloat (Widgets, Copilot, Bing)
# -------------------------------------------------------
if ($DisableUI) {
    Write-Host "`n--- Disabling UI Bloat ---" -ForegroundColor Yellow

    $adv = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $adv -Name "TaskbarDa" -Value 0 -Type DWord
    Write-Host "  Widgets (TaskbarDa) = 0" -ForegroundColor Green

    Set-ItemProperty -Path $adv -Name "ShowCopilotButton" -Value 0 -Type DWord
    Write-Host "  Copilot button hidden" -ForegroundColor Green

    $copilotPolicy = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"
    if (!(Test-Path $copilotPolicy)) { New-Item -Path $copilotPolicy -Force | Out-Null }
    Set-ItemProperty -Path $copilotPolicy -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord
    Write-Host "  Copilot policy disabled" -ForegroundColor Green

    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    Set-ItemProperty -Path $searchKey -Name "BingSearchEnabled" -Value 0 -Type DWord
    Write-Host "  Bing in Start = 0" -ForegroundColor Green

    # Disable Start Feed scheduled tasks
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like "*Feed*" -or $_.TaskName -like "*Start*Content*" } |
        ForEach-Object {
            Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  Disabled task: $($_.TaskName)" -ForegroundColor Green
        }
}

# -------------------------------------------------------
# 6. Deny background access for non-allowlisted UWP apps
# -------------------------------------------------------
if ($DenyBackgroundApps) {
    Write-Host "`n--- Denying Background App Access ---" -ForegroundColor Yellow

    $bgPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"

    # Allowlist prefixes - shell infra, protected apps, auth, frameworks, utilities
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

    if (Test-Path $bgPath) {
        $bgApps = Get-ChildItem -Path $bgPath -ErrorAction SilentlyContinue
        $deniedCount = 0
        $skippedCount = 0

        foreach ($app in $bgApps) {
            $pkgName = $app.PSChildName
            $isAllowlisted = $false
            foreach ($prefix in $allowlist) {
                if ($pkgName -like "$prefix*") { $isAllowlisted = $true; break }
            }

            if ($isAllowlisted) {
                $skippedCount++
            } else {
                $currentDisabled = (Get-ItemProperty -Path $app.PSPath -Name "Disabled" -ErrorAction SilentlyContinue).Disabled
                if ($currentDisabled -ne 1) {
                    Set-ItemProperty -Path $app.PSPath -Name "Disabled" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $app.PSPath -Name "DisabledByUser" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    $deniedCount++
                }
            }
        }

        Write-Host "  Denied background access: $deniedCount apps" -ForegroundColor Green
        Write-Host "  Allowlisted (skipped): $skippedCount apps" -ForegroundColor DarkGray
    } else {
        Write-Host "  BackgroundAccessApplications key not found" -ForegroundColor DarkYellow
    }
}

# -------------------------------------------------------
# 7. Disable per-user service templates (Phone Link ecosystem)
# -------------------------------------------------------
if ($DisablePerUserServices) {
    Write-Host "`n--- Disabling Per-User Service Templates ---" -ForegroundColor Yellow

    $templates = @("cbdhsvc", "CDPUserSvc", "DevicesFlowUserSvc", "MessagingService")

    foreach ($template in $templates) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$template"
        if (Test-Path $regPath) {
            try {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 4
                Write-Host "  $template template: DISABLED (Start=4)" -ForegroundColor Green
            } catch {
                Write-Host "  $template : FAILED - $_" -ForegroundColor Red
            }
        } else {
            Write-Host "  $template : not found (OK)" -ForegroundColor DarkGray
        }
    }

    # Stop running per-user instances
    $perUserRunning = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(cbdhsvc|CDPUserSvc|DevicesFlowUserSvc|MessagingService)_[0-9a-f]+$' -and $_.Status -eq 'Running'
    }
    foreach ($s in $perUserRunning) {
        try {
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            Write-Host "  Stopped instance: $($s.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to stop $($s.Name): $_" -ForegroundColor Red
        }
    }

    # Kill PhoneExperienceHost (spawned by these services)
    $peh = Get-Process -Name "PhoneExperienceHost" -ErrorAction SilentlyContinue
    if ($peh) {
        $mb = [math]::Round(($peh | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        $peh | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Killed PhoneExperienceHost ($mb MB)" -ForegroundColor Green
    }
}

# -------------------------------------------------------
# 8. Disable non-essential scheduled tasks
# -------------------------------------------------------
if ($DisableScheduledTasks) {
    Write-Host "`n--- Disabling Non-Essential Scheduled Tasks ---" -ForegroundColor Yellow

    # Brave updater tasks
    $braveTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { ($_.TaskPath -like '*BraveSoftware*' -or $_.TaskName -like '*Brave*') -and $_.State -ne 'Disabled' }
    if ($braveTasks) {
        foreach ($t in $braveTasks) {
            try {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
                Write-Host "  Disabled: $($t.TaskPath)$($t.TaskName)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed: $($t.TaskPath)$($t.TaskName) - $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  No active Brave tasks found" -ForegroundColor DarkGray
    }

    # Flag other non-Microsoft, non-disabled tasks
    $otherTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskPath -notlike '*BraveSoftware*' -and $_.TaskName -notlike '*Brave*' -and $_.State -ne 'Disabled' }
    if ($otherTasks) {
        Write-Host "  Other non-Microsoft tasks (not auto-disabled, review manually):" -ForegroundColor Yellow
        foreach ($t in $otherTasks) {
            Write-Host "    $($t.TaskPath)$($t.TaskName) : $($t.State)"
        }
    }
}

# -------------------------------------------------------
# 9. Set vendor/OEM services to Manual
# -------------------------------------------------------
if ($SetVendorServicesManual) {
    Write-Host "`n--- Setting Vendor Services to Manual ---" -ForegroundColor Yellow

    $vendorTargets = @("DolbyDAXAPI", "IntelGraphicsSoftwareService")

    foreach ($svcName in $vendorTargets) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.StartType -ne 'Manual') {
                try {
                    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                    Set-Service -Name $svcName -StartupType Manual
                    Write-Host "  $svcName : set to Manual, stopped" -ForegroundColor Green
                } catch {
                    Write-Host "  $svcName : FAILED - $_" -ForegroundColor Red
                }
            } else {
                Write-Host "  $svcName : already Manual" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  $svcName : not found" -ForegroundColor DarkGray
        }
    }
}

# -------------------------------------------------------
# 10. Remove Cross Device Experience Host (UWP app)
# CrossDeviceService is NOT a Windows service — it's a UWP app
# that runs independently via the Store framework.
# -------------------------------------------------------
if ($RemoveCrossDeviceApp) {
    Write-Host "`n--- Removing Cross Device Experience Host ---" -ForegroundColor Yellow

    # Kill the running process first
    $cdProc = Get-Process -Name "CrossDeviceService" -ErrorAction SilentlyContinue
    if ($cdProc) {
        $mb = [math]::Round(($cdProc | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        $cdProc | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Killed CrossDeviceService process ($mb MB)" -ForegroundColor Green
    } else {
        Write-Host "  CrossDeviceService not running" -ForegroundColor DarkGray
    }

    # Also kill PhoneExperienceHost if running
    $peh = Get-Process -Name "PhoneExperienceHost" -ErrorAction SilentlyContinue
    if ($peh) {
        $peh | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Killed PhoneExperienceHost" -ForegroundColor Green
    }

    # Uninstall the AppxPackage for all users
    $cdPkg = Get-AppxPackage -Name "*CrossDevice*" -AllUsers -ErrorAction SilentlyContinue
    if ($cdPkg) {
        foreach ($pkg in $cdPkg) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Host "  Removed AppxPackage: $($pkg.Name)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to remove AppxPackage: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  No CrossDevice AppxPackage found (already removed)" -ForegroundColor DarkGray
    }

    # Remove provisioned package to prevent reinstallation on new profiles
    $cdProv = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "*CrossDevice*" }
    if ($cdProv) {
        foreach ($prov in $cdProv) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                Write-Host "  Removed provisioned package: $($prov.PackageName)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to remove provisioned package: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  No CrossDevice provisioned package found (already removed)" -ForegroundColor DarkGray
    }

    # Disable CrossDevice scheduled tasks
    $cdTasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\CrossDevice\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Disabled' }
    if ($cdTasks) {
        foreach ($t in $cdTasks) {
            try {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
                Write-Host "  Disabled task: $($t.TaskPath)$($t.TaskName)" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to disable task: $($t.TaskName) - $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  No active CrossDevice scheduled tasks" -ForegroundColor DarkGray
    }

    # Disable Mobile Devices startup entry if present
    $startupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    if (Test-Path $startupPath) {
        $mobileDevices = Get-ItemProperty -Path $startupPath -ErrorAction SilentlyContinue |
            Get-Member -MemberType NoteProperty | Where-Object { $_.Name -like "*CrossDevice*" -or $_.Name -like "*MobileDevices*" }
        if ($mobileDevices) {
            foreach ($entry in $mobileDevices) {
                Remove-ItemProperty -Path $startupPath -Name $entry.Name -ErrorAction SilentlyContinue
                Write-Host "  Removed startup entry: $($entry.Name)" -ForegroundColor Green
            }
        }
    }

    Write-Host "  Cross Device Experience Host removal complete" -ForegroundColor Green
    Write-Host "  Note: Major Windows Updates may reinstall this app (~2x/year)" -ForegroundColor Yellow
}

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
Write-Host "`n=== ALL CHANGES APPLIED ===" -ForegroundColor Cyan
if ($DisableSearchWebviews) {
    Write-Host "Search webviews eliminated. No reboot required - explorer was restarted." -ForegroundColor Green
    Write-Host "Note: WSearch (indexing) is disabled. Search via Win+S still works but uses live file scan." -ForegroundColor Yellow
}
Start-Sleep -Seconds 3
