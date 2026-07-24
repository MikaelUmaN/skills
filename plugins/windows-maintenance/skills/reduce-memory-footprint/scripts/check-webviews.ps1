# ==========================================================
# WebView Parent Chain Tracer
# Part of /reduce-memory-footprint skill
#
# Traces every msedgewebview2.exe back to its root parent,
# then outputs both individual chains and a grouped summary.
# ==========================================================

$ErrorActionPreference = "Continue"

Write-Host "`n=== msedgewebview2.exe Parent Chain Analysis ===" -ForegroundColor Cyan

# Build process map
$allProcs = Get-CimInstance Win32_Process
$procMap = @{}
foreach ($p in $allProcs) { $procMap[[int]$p.ProcessId] = $p }

$webviews = @($allProcs | Where-Object { $_.Name -eq "msedgewebview2.exe" })

if ($webviews.Count -eq 0) {
    Write-Host "  No msedgewebview2.exe processes found." -ForegroundColor Green
    exit 0
}

Write-Host "  Found $($webviews.Count) webview instances`n" -ForegroundColor Yellow

# --- Individual chains ---
Write-Host "--- Individual Chains ---" -ForegroundColor Cyan
$groups = @{}

foreach ($wv in $webviews) {
    $chain = [System.Collections.ArrayList]::new()
    [void]$chain.Add("msedgewebview2.exe(PID:$($wv.ProcessId))")
    $current = $wv
    $rootParent = "UNKNOWN"

    for ($i = 0; $i -lt 20; $i++) {
        $ppid = [int]$current.ParentProcessId
        if ($procMap.ContainsKey($ppid) -and $procMap[$ppid].Name -ne "msedgewebview2.exe") {
            $parent = $procMap[$ppid]
            [void]$chain.Add("$($parent.Name)(PID:$ppid)")
            $rootParent = $parent.Name
            break
        } elseif ($procMap.ContainsKey($ppid)) {
            [void]$chain.Add("msedgewebview2.exe(PID:$ppid)")
            $current = $procMap[$ppid]
        } else {
            [void]$chain.Add("DEAD(PID:$ppid)")
            $rootParent = "DEAD($ppid)"
            break
        }
    }

    $mb = [math]::Round($wv.WorkingSetSize / 1MB, 1)

    # Track groups
    if (-not $groups.ContainsKey($rootParent)) {
        $groups[$rootParent] = @{ Count = 0; TotalMB = 0; PIDs = @() }
    }
    $groups[$rootParent].Count++
    $groups[$rootParent].TotalMB += $mb
    $groups[$rootParent].PIDs += $wv.ProcessId

    # Print chain
    $chainStr = $chain -join " <- "
    Write-Host "  [$mb MB] $chainStr"
}

# --- Grouped summary ---
Write-Host "`n--- Grouped Summary (by root parent) ---" -ForegroundColor Cyan
Write-Host ("{0,-30} {1,6} {2,10}" -f "Root Parent", "Count", "Total MB") -ForegroundColor White
Write-Host ("{0,-30} {1,6} {2,10}" -f "----------", "-----", "--------")

$sortedKeys = $groups.Keys | Sort-Object { $groups[$_].TotalMB } -Descending
foreach ($key in $sortedKeys) {
    $g = $groups[$key]
    Write-Host ("{0,-30} {1,6} {2,10}" -f $key, $g.Count, [math]::Round($g.TotalMB, 1))
}

$totalMB = ($groups.Values | ForEach-Object { $_.TotalMB } | Measure-Object -Sum).Sum
Write-Host ("{0,-30} {1,6} {2,10}" -f "TOTAL", $webviews.Count, [math]::Round($totalMB, 1)) -ForegroundColor Yellow

Write-Host "`n=== Analysis Complete ===" -ForegroundColor Green
