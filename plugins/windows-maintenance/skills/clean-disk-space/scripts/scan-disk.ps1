# ==========================================================
# Disk Scan Script — read-only. Collects disk status and
# per-category reclaimable-space candidates.
# Part of /clean-disk-space skill. NEVER deletes anything.
# ==========================================================
param(
    [ValidateSet('safe','thorough')]
    [string]$Mode = 'safe',
    [int]$LogAgeDays = 30,        # logs older than this are "stale"
    [int]$StaleDays  = 180,       # general "not touched in a long time" cutoff
    [int]$TopN       = 25,        # thorough: how many big items to surface
    [long]$BigFileMB = 200        # thorough: a file this big is "large"
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# --- WSL / virtual-disk guard. These paths are OFF LIMITS and are
#     filtered out of every candidate list. Docker is handled via the
#     docker CLI only (see SKILL.md) — its WSL backing vhdx is never touched.
# Note: ALL .vhdx are excluded — they are virtual disks (WSL2 ext4/swap, Hyper-V,
# Windows Sandbox) and are never safe to bulk-delete. WSL's swap.vhdx lives under %TEMP%.
$wslPattern = '(\\wsl\$|\\wsl\.localhost|\.vhdx|\\Docker\\wsl\\|CanonicalGroupLimited|MicrosoftCorporationII\.WindowsSubsystemForLinux|\\Linux\\|docker-desktop)'

function Format-Size {
    param([double]$Bytes)
    if (-not $Bytes) { return '0 B' }
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes/1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes/1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes/1KB)) }
    return ('{0} B' -f [long]$Bytes)
}

function Get-CandidateFiles {
    param([string[]]$Roots, [scriptblock]$Where)
    $out = foreach ($r in $Roots) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue
        }
    }
    $out = $out | Where-Object { $_.FullName -notmatch $wslPattern }
    # Dedupe by full path — some roots resolve to the same folder (e.g. %TEMP% and
    # %LOCALAPPDATA%\Temp) which would otherwise double-count files.
    $out = $out | Sort-Object FullName -Unique
    if ($Where) { $out = $out | Where-Object $Where }
    ,@($out)
}

function New-CatResult {
    param([string]$Name, [string]$Risk, [string]$Desc, $Files)
    $files = @($Files)
    $sum = ($files | Measure-Object Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    $top = $files | Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {
        [ordered]@{
            path      = $_.FullName
            sizeBytes = [long]$_.Length
            sizeHuman = (Format-Size $_.Length)
            lastWrite = $_.LastWriteTime.ToString('yyyy-MM-dd')
        }
    }
    [ordered]@{
        name        = $Name
        risk        = $Risk
        description = $Desc
        sizeBytes   = [long]$sum
        sizeHuman   = (Format-Size $sum)
        fileCount   = $files.Count
        topItems    = @($top)
    }
}

$logCut   = (Get-Date).AddDays(-$LogAgeDays)
$staleCut = (Get-Date).AddDays(-$StaleDays)
$LA       = $env:LOCALAPPDATA
$RA       = $env:APPDATA
$UP       = $env:USERPROFILE

# ==========================================================
# DISK STATUS
# ==========================================================
Write-Host "`n=== DISK STATUS ===" -ForegroundColor Cyan
$disks = Get-Volume |
    Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
    Sort-Object DriveLetter |
    ForEach-Object {
        $used = $_.Size - $_.SizeRemaining
        $pct  = if ($_.Size) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
        Write-Host ("  {0}: {1,-14} {2,9} used / {3,9} total  ({4}% used, {5} free)" -f `
            $_.DriveLetter, $_.FileSystemLabel, (Format-Size $used), (Format-Size $_.Size), $pct, (Format-Size $_.SizeRemaining))
        [ordered]@{
            drive      = "$($_.DriveLetter):"
            label      = "$($_.FileSystemLabel)"
            totalBytes = [long]$_.Size
            usedBytes  = [long]$used
            freeBytes  = [long]$_.SizeRemaining
            totalHuman = (Format-Size $_.Size)
            usedHuman  = (Format-Size $used)
            freeHuman  = (Format-Size $_.SizeRemaining)
            pctUsed    = $pct
        }
    }

$fixedDrives = @($disks | ForEach-Object { $_.drive + '\' })

# ==========================================================
# CATEGORIES (both modes)
# ==========================================================
$cats = @()
Write-Host "`n=== SCANNING CATEGORIES ($Mode mode) ===" -ForegroundColor Cyan

# 1. Crash dumps & minidumps
$dumpFiles = @()
$dumpFiles += Get-CandidateFiles -Roots @("$LA\CrashDumps", "$env:WINDIR\Minidump")
$dumpFiles += Get-CandidateFiles -Roots @($UP) -Where { $_.Extension -in '.dmp','.mdmp' -and $_.LastWriteTime -lt $staleCut }
if (Test-Path "$env:WINDIR\MEMORY.DMP") { $dumpFiles += Get-Item "$env:WINDIR\MEMORY.DMP" }
$cats += New-CatResult 'Crash dumps & minidumps' 'low' 'Memory/crash dump files (.dmp). Only useful right after a crash you intend to debug.' $dumpFiles

# 2. Temp files
$cats += New-CatResult 'Temp files' 'low' 'User and Windows TEMP folders. Safe to clear; in-use files are skipped on delete.' `
    (Get-CandidateFiles -Roots @($env:TEMP, "$LA\Temp", "$env:WINDIR\Temp"))

# 3. Windows Update cache
$cats += New-CatResult 'Windows Update cache' 'low' 'Downloaded update payloads in SoftwareDistribution\Download. Rebuilt automatically.' `
    (Get-CandidateFiles -Roots @("$env:WINDIR\SoftwareDistribution\Download"))

# 4. Delivery Optimization cache
$cats += New-CatResult 'Delivery Optimization cache' 'low' 'Peer-to-peer update cache. Rebuilt automatically.' `
    (Get-CandidateFiles -Roots @("$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"))

# 5. Recycle Bin (all fixed drives)
$cats += New-CatResult 'Recycle Bin' 'low' 'Deleted items still occupying space across all drives.' `
    (Get-CandidateFiles -Roots @($fixedDrives | ForEach-Object { Join-Path $_ '$Recycle.Bin' }))

# 6. Thumbnail / icon caches
$cats += New-CatResult 'Thumbnail & icon caches' 'low' 'Explorer thumbnail/icon DB cache. Rebuilt on demand.' `
    (Get-CandidateFiles -Roots @("$LA\Microsoft\Windows\Explorer") -Where { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' })

# 7. Developer / package-manager caches
$devRoots = @(
    "$LA\npm-cache", "$RA\npm-cache",
    "$LA\pip\Cache", "$LA\Yarn\Cache", "$LA\pnpm-cache",
    "$UP\.nuget\packages", "$UP\.cargo\registry\cache", "$UP\.gradle\caches",
    "$LA\go-build", "$UP\go\pkg\mod\cache\download",
    "$LA\Microsoft\vscode-cpptools", "$LA\JetBrains\*\caches"
)
$cats += New-CatResult 'Developer / package caches' 'medium' 'npm/pip/yarn/nuget/cargo/gradle/go caches. Safe but will re-download on next build.' `
    (Get-CandidateFiles -Roots $devRoots)

# 8. Stale log files
$cats += New-CatResult "Stale log files (>$LogAgeDays days)" 'medium' "*.log/*.etl not modified in over $LogAgeDays days. Active apps recreate logs they need." `
    (Get-CandidateFiles -Roots @($LA, "$env:ProgramData", "$env:WINDIR\Logs") -Where { $_.Extension -in '.log','.etl' -and $_.LastWriteTime -lt $logCut })

# 9. Browser caches
$browserRoots = @(
    "$LA\Google\Chrome\User Data\Default\Cache",
    "$LA\Google\Chrome\User Data\Default\Code Cache",
    "$LA\Microsoft\Edge\User Data\Default\Cache",
    "$LA\Microsoft\Edge\User Data\Default\Code Cache",
    "$LA\Mozilla\Firefox\Profiles",
    "$LA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
)
$cats += New-CatResult 'Browser caches' 'low' 'Chrome/Edge/Brave/Firefox HTTP & code caches. Rebuilt on browsing; may log you out of nothing.' `
    (Get-CandidateFiles -Roots $browserRoots -Where { $_.FullName -match '\\(Cache|Code Cache|cache2)\\' })

# ==========================================================
# THOROUGH-ONLY categories
# ==========================================================
if ($Mode -eq 'thorough') {
    # 10. Large or stale files in Downloads
    $cats += New-CatResult 'Downloads — large/old files' 'medium' "Files in Downloads larger than ${BigFileMB}MB OR untouched >$StaleDays days. Review individually." `
        (Get-CandidateFiles -Roots @("$UP\Downloads") -Where { $_.Length -ge ($BigFileMB*1MB) -or $_.LastWriteTime -lt $staleCut })

    # 11. Installer leftovers anywhere in profile
    $cats += New-CatResult 'Installer leftovers' 'medium' 'Old .iso/.msi/.exe/.zip installers in your profile, untouched for a long time.' `
        (Get-CandidateFiles -Roots @($UP) -Where { $_.Extension -in '.iso','.msi','.zip','.7z' -and $_.LastWriteTime -lt $staleCut -or ($_.Extension -eq '.exe' -and $_.Length -ge (50*1MB) -and $_.LastWriteTime -lt $staleCut) })

    # 12. Windows.old (previous Windows install)
    $cats += New-CatResult 'Windows.old (previous install)' 'high' 'Previous Windows version kept after an upgrade. Deleting blocks rollback to the old build.' `
        (Get-CandidateFiles -Roots @("$env:SystemDrive\Windows.old"))

    # 13. hiberfil.sys (informational — removed via powercfg, not file delete)
    $hib = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    if ($hib) {
        $cats += [ordered]@{
            name='Hibernation file (hiberfil.sys)'; risk='high'
            description='Reserved for hibernation/Fast Startup. Reclaim ONLY via `powercfg /h off` (disables hibernation), never by deleting the file.'
            sizeBytes=[long]$hib.Length; sizeHuman=(Format-Size $hib.Length); fileCount=1
            topItems=@([ordered]@{path=$hib.FullName; sizeBytes=[long]$hib.Length; sizeHuman=(Format-Size $hib.Length); lastWrite=$hib.LastWriteTime.ToString('yyyy-MM-dd')})
        }
    }

    # 14. Largest top-level directories across fixed drives (the "biggest culprits")
    Write-Host "  ...measuring largest top-level directories (this can take a minute)" -ForegroundColor DarkGray
    $bigDirs = foreach ($d in $fixedDrives) {
        Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch $wslPattern } | ForEach-Object {
                $sz = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch $wslPattern } | Measure-Object Length -Sum).Sum
                [ordered]@{ path=$_.FullName; sizeBytes=[long]$sz; sizeHuman=(Format-Size $sz); lastWrite=$_.LastWriteTime.ToString('yyyy-MM-dd') }
            }
    }
    $bigDirs = @($bigDirs | Sort-Object sizeBytes -Descending | Select-Object -First $TopN)
    $cats += [ordered]@{
        name='Largest directories (review individually)'; risk='review'
        description='Biggest top-level folders by size. NOT a delete list — context for deciding what to target. Many are essential (Windows, Program Files, your data).'
        sizeBytes=0; sizeHuman='n/a (review)'; fileCount=$bigDirs.Count; topItems=$bigDirs
    }

    # 15. Largest individual files across the user profile + ProgramData
    Write-Host "  ...finding largest individual files" -ForegroundColor DarkGray
    $bigFiles = Get-CandidateFiles -Roots @($UP, "$env:ProgramData") -Where { $_.Length -ge ($BigFileMB*1MB) }
    $bigFiles = @($bigFiles | Sort-Object Length -Descending | Select-Object -First $TopN)
    $cats += New-CatResult 'Largest individual files (review)' 'review' "Single files >= ${BigFileMB}MB under your profile/ProgramData. Review individually." $bigFiles
}

# ==========================================================
# DOCKER (CLI only — never touches the WSL vhdx directly)
# ==========================================================
$docker = [ordered]@{ available=$false; reason='docker CLI not found'; df=''; danglingImages=0; stoppedContainers=0 }
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $info = & docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        $docker.available = $true
        $docker.reason = 'ok'
        $docker.df = (& docker system df 2>&1 | Out-String)
        $docker.danglingImages   = @(& docker images -f 'dangling=true' -q 2>$null).Count
        $docker.stoppedContainers= @(& docker ps -a -f 'status=exited' -f 'status=created' -q 2>$null).Count
        Write-Host "`n=== DOCKER ===" -ForegroundColor Cyan
        Write-Host $docker.df
        Write-Host ("  Dangling images: {0} | Stopped containers: {1}" -f $docker.danglingImages, $docker.stoppedContainers)
    } else {
        $docker.reason = 'docker CLI present but daemon not responding'
    }
}

# ==========================================================
# SUMMARY (human-readable)
# ==========================================================
Write-Host "`n=== POTENTIAL SAVINGS BY CATEGORY ===" -ForegroundColor Cyan
foreach ($c in ($cats | Sort-Object { $_.sizeBytes } -Descending)) {
    Write-Host ("  [{0,-6}] {1,-40} {2,12}  ({3} items)" -f $c.risk, $c.name, $c.sizeHuman, $c.fileCount)
}
$reclaimable = ($cats | Where-Object { $_.risk -ne 'review' } | ForEach-Object { $_.sizeBytes } | Measure-Object -Sum).Sum
Write-Host ("`n  Estimated directly reclaimable (excludes review-only): {0}" -f (Format-Size $reclaimable)) -ForegroundColor Green

# ==========================================================
# MACHINE-READABLE OUTPUT
# ==========================================================
$payload = [ordered]@{
    mode        = $Mode
    generatedAt = (Get-Date).ToString('s')
    disks       = @($disks)
    categories  = @($cats)
    docker      = $docker
    reclaimableBytes = [long]$reclaimable
    reclaimableHuman = (Format-Size $reclaimable)
}
Write-Host "`n===JSON_BEGIN==="
$payload | ConvertTo-Json -Depth 8 -Compress
Write-Host "`n===JSON_END==="
