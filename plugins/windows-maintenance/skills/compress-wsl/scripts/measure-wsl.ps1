# ==========================================================
# WSL Measure Script - READ-ONLY (never compacts or deletes).
# Part of /compress-wsl skill. Enumerates WSL distros, their
# backing ext4.vhdx (path/size/sparse), the guest's actual
# used data, fixed-drive free space, and recommends a
# compaction mechanism. Run before AND after compaction.
#
# NOTE: to measure guest used-data it briefly starts each WSL2
# distro (read-only query). It does NOT modify guest data.
# ==========================================================
param(
    [double]$Margin = 1.15   # set-sparse scratch headroom multiplier over guest used-data
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Format-Size {
    param([double]$Bytes)
    if (-not $Bytes) { return '0 B' }
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes/1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes/1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes/1KB)) }
    return ('{0} B' -f [long]$Bytes)
}

# wsl.exe's OWN output (--list etc.) is UTF-16LE; the stdout of a command run
# inside a distro (`wsl -d X -- cmd`) is whatever the guest emits, i.e. UTF-8.
# Decode with the right encoding per call so parsing is clean either way.
function Invoke-Wsl {
    param([string[]]$WslArgs, [ValidateSet('Unicode','UTF8')][string]$As = 'UTF8')
    $enc  = if ($As -eq 'Unicode') { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::UTF8 }
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = $enc
        & wsl.exe @WslArgs 2>$null
    } finally {
        [Console]::OutputEncoding = $prev
    }
}

# --- Which distros are currently running? (quiet list of names)
$running = @()
$runningRaw = Invoke-Wsl @('--list','--running','--quiet') -As Unicode
foreach ($line in $runningRaw) {
    $n = ($line -replace "`0",'').Trim()
    if ($n) { $running += $n }
}

# --- WSL tool version, and whether --set-sparse is gated.
#     Microsoft DISABLED sparse VHD by default in WSL 2.5.8.0 due to potential
#     data corruption (microsoft/WSL#13075); on gated versions `--set-sparse true`
#     errors and needs an explicit `--allow-unsafe` flag. So set-sparse is NOT a
#     safe default path - the skill defaults to diskpart compact instead.
$wslToolVersion = 'unknown'
$verRaw = Invoke-Wsl @('--version') -As Unicode
foreach ($line in $verRaw) {
    $clean = ($line -replace "`0",'').Trim()
    if ($clean -match '(\d+\.\d+\.\d+(?:\.\d+)?)') { $wslToolVersion = $matches[1]; break }
}
$setSparseGated = $true   # assume gated unless we can prove an older, non-gated version
try {
    if ($wslToolVersion -ne 'unknown') {
        $setSparseGated = ([version]$wslToolVersion -ge [version]'2.5.8.0')
    }
} catch { $setSparseGated = $true }

# ==========================================================
# ENUMERATE DISTROS FROM THE REGISTRY (authoritative; covers
# store-installed AND imported distros). vhdx = BasePath\ext4.vhdx
# ==========================================================
$lxssRoot = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss'
$distros = @()

if (Test-Path $lxssRoot) {
    foreach ($key in (Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        $name = $p.DistributionName
        if (-not $name) { continue }

        $base = "$($p.BasePath)" -replace '^\\\\\?\\',''   # strip \\?\ prefix
        $vhdx = if ($base) { Join-Path $base 'ext4.vhdx' } else { $null }
        $ver  = if ($null -ne $p.Version) { [int]$p.Version } else { 2 }

        $entry = [ordered]@{
            name          = $name
            wslVersion    = $ver
            state         = if ($running -contains $name) { 'Running' } else { 'Stopped' }
            basePath      = $base
            vhdxPath      = $vhdx
            vhdxExists    = $false
            vhdxBytes     = 0
            vhdxHuman     = 'n/a'
            sparse        = $false
            guestUsedBytes= $null
            guestUsedHuman= 'unknown'
            compactable   = $false
            reason        = ''
        }

        if ($ver -ne 2) {
            $entry.reason = 'WSL1 distro - no ext4.vhdx, not compactable.'
        }
        elseif ($vhdx -and (Test-Path -LiteralPath $vhdx)) {
            $item = Get-Item -LiteralPath $vhdx -Force
            $entry.vhdxExists = $true
            $entry.vhdxBytes  = [long]$item.Length
            $entry.vhdxHuman  = (Format-Size $item.Length)
            $entry.sparse     = [bool]($item.Attributes -band [System.IO.FileAttributes]::SparseFile)
            $entry.compactable= $true

            # Guest actual used-data on root fs (starts the distro briefly; read-only).
            # -u root avoids a sudo password prompt in a non-interactive shell.
            $df = Invoke-Wsl @('-d',$name,'-u','root','--','df','-B1','/')
            $dataLine = @($df | Where-Object { ($_ -replace "`0",'').Trim() }) | Select-Object -Last 1
            if ($dataLine) {
                $fields = (($dataLine -replace "`0",'').Trim() -split '\s+')
                if ($fields.Count -ge 3 -and $fields[2] -match '^\d+$') {
                    $entry.guestUsedBytes = [long]$fields[2]
                    $entry.guestUsedHuman = (Format-Size $entry.guestUsedBytes)
                }
            }
        }
        else {
            $entry.reason = 'ext4.vhdx not found at expected path.'
        }
        $distros += $entry
    }
}

# ==========================================================
# FIXED-DRIVE STATUS
# ==========================================================
$disks = Get-Volume |
    Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
    Sort-Object DriveLetter |
    ForEach-Object {
        $used = $_.Size - $_.SizeRemaining
        $pct  = if ($_.Size) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
        [ordered]@{
            drive=("$($_.DriveLetter):"); label="$($_.FileSystemLabel)"
            totalBytes=[long]$_.Size; usedBytes=[long]$used; freeBytes=[long]$_.SizeRemaining
            totalHuman=(Format-Size $_.Size); usedHuman=(Format-Size $used); freeHuman=(Format-Size $_.SizeRemaining)
            pctUsed=$pct
        }
    }

# Free space on the drive that hosts each distro's vhdx (set-sparse scratch lives there).
function Get-DriveFree {
    param([string]$Path)
    if (-not $Path) { return $null }
    $root = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\')   # e.g. "C:"
    ($disks | Where-Object { $_.drive -eq $root } | Select-Object -First 1).freeBytes
}

# ==========================================================
# RECOMMENDATION PER DISTRO
#   diskpart   : in-place, minimal scratch, one-time, needs elevation. DEFAULT.
#   set-sparse : DISABLED by Microsoft as of WSL 2.5.8.0 (data-corruption risk,
#                microsoft/WSL#13075). Needs `--allow-unsafe` to run at all. Never
#                auto-recommended; only an explicit, risk-acknowledged opt-in.
# The vhdx's CURRENT sparse status is checked and surfaced ($d.sparse) so the
# caller knows the disk's state before doing anything.
# ==========================================================
foreach ($d in $distros) {
    if (-not $d.compactable) { $d | Add-Member recommendation 'none'; continue }
    $free = Get-DriveFree $d.vhdxPath
    $d | Add-Member driveFreeBytes ([long]($free)) -Force
    $d | Add-Member driveFreeHuman (Format-Size $free) -Force

    # set-sparse space eligibility (informational only - it is NOT a safe path).
    $sparseFits = ($null -ne $d.guestUsedBytes) -and ($free -ge ($d.guestUsedBytes * $Margin))
    $d | Add-Member setSparseFitsSpace ([bool]$sparseFits) -Force
    $d | Add-Member setSparseGated ([bool]$setSparseGated) -Force
    if ($setSparseGated) {
        $d | Add-Member setSparseNote ("set-sparse is DISABLED on WSL {0} (>= 2.5.8.0) due to data-corruption risk; would require --allow-unsafe. Not recommended." -f $wslToolVersion) -Force
    } else {
        $d | Add-Member setSparseNote ("set-sparse not gated on WSL {0}, but still carries historical corruption risk; diskpart preferred." -f $wslToolVersion) -Force
    }

    # Always recommend diskpart (in-place, lossless, no sparse-mode change).
    $d | Add-Member recommendation 'diskpart' -Force
    if ($d.sparse) {
        $d | Add-Member recommendReason 'vhdx is ALREADY sparse. Do not re-run set-sparse. diskpart compact vdisk in-place (note: sparse vhds may compact poorly/not shrink).' -Force
    } elseif ($null -eq $d.guestUsedBytes) {
        $d | Add-Member recommendReason 'Guest used-data unknown - diskpart (in-place, minimal scratch) is the safe choice. set-sparse is disabled/unsafe.' -Force
    } else {
        $d | Add-Member recommendReason ("diskpart in-place compact (guest uses {0} of a {1} vhdx; drive free {2}). set-sparse is disabled/unsafe on this WSL version." -f $d.guestUsedHuman, $d.vhdxHuman, (Format-Size $free)) -Force
    }
}

# ==========================================================
# HUMAN-READABLE SUMMARY
# ==========================================================
Write-Host ("`n=== WSL {0} ===" -f $wslToolVersion) -ForegroundColor Cyan
if ($setSparseGated) {
    Write-Host "  set-sparse is DISABLED by Microsoft on this version (data-corruption risk, WSL#13075)." -ForegroundColor Yellow
    Write-Host "  -> Skill defaults to in-place 'diskpart compact vdisk'; set-sparse only via explicit --allow-unsafe opt-in." -ForegroundColor Yellow
}
Write-Host "`n=== WSL DISTROS ===" -ForegroundColor Cyan
foreach ($d in $distros) {
    Write-Host ("  {0,-22} WSL{1}  {2,-8} vhdx={3,10}  sparse={4,-5}  guestUsed={5,10}" -f `
        $d.name, $d.wslVersion, $d.state, $d.vhdxHuman, $d.sparse, $d.guestUsedHuman)
    if ($d.compactable) {
        Write-Host ("      -> recommend: {0}  ({1})" -f $d.recommendation, $d.recommendReason) -ForegroundColor Green
    } elseif ($d.reason) {
        Write-Host ("      -> {0}" -f $d.reason) -ForegroundColor DarkGray
    }
}

Write-Host "`n=== FIXED DRIVES ===" -ForegroundColor Cyan
foreach ($v in $disks) {
    Write-Host ("  {0} {1,-14} {2,10} free / {3,10} total  ({4}% used)" -f `
        $v.drive, $v.label, $v.freeHuman, $v.totalHuman, $v.pctUsed)
}

# ==========================================================
# MACHINE-READABLE OUTPUT
# ==========================================================
$payload = [ordered]@{
    generatedAt    = (Get-Date).ToString('s')
    margin         = $Margin
    wslToolVersion = $wslToolVersion
    setSparseGated = [bool]$setSparseGated
    distros        = @($distros)
    disks          = @($disks)
}
Write-Host "`n===JSON_BEGIN==="
$payload | ConvertTo-Json -Depth 8 -Compress
Write-Host "`n===JSON_END==="
