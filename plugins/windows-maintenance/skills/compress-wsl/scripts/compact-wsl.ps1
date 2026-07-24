# ==========================================================
# WSL Compact Script - diskpart in-place `compact vdisk`.
# Part of /compress-wsl skill.
#
# Preconditions the CALLER must satisfy (see SKILL.md):
#   - WSL is already shut down (`wsl --shutdown`) so the vhdx is released.
#   - The user has confirmed the destructive step.
#
# This runs diskpart ELEVATED (a UAC prompt appears). `compact vdisk`
# only drops already-zeroed/unused blocks from the dynamically-expanding
# vhdx - it is lossless: guest data is never altered. The vhdx is
# NEVER deleted, moved, or recreated.
# ==========================================================
param(
    [Parameter(Mandatory=$true)][string]$VhdxPath,
    [int]$RetrySeconds = 5    # if the file is still locked, wait this long and retry once
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Format-Size {
    param([double]$Bytes)
    if (-not $Bytes) { return '0 B' }
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes/1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes/1MB)) }
    return ('{0} B' -f [long]$Bytes)
}

function Write-Result {
    param([bool]$Ok, [string]$Msg, [long]$Before = 0, [long]$After = 0, [string]$Log = '')
    $reclaimed = [long]($Before - $After)

    # diskpart's progress animation can produce a multi-MB log; ConvertTo-Json
    # (JavaScriptSerializer, ~2MB MaxJsonLength) throws on huge strings and the
    # error is swallowed, yielding an EMPTY JSON block. So sanitize + cap the log:
    # drop progress-spam lines and keep only a short tail.
    $logClean = ''
    if ($Log) {
        $logClean = (($Log -split "`r?`n") |
            Where-Object { $_ -and ($_ -notmatch 'percent completed') } |
            Select-Object -Last 15) -join "`n"
        if ($logClean.Length -gt 2000) { $logClean = $logClean.Substring($logClean.Length - 2000) }
    }

    $payload = [ordered]@{
        ok             = $Ok
        message        = $Msg
        vhdxPath       = $VhdxPath
        beforeBytes    = $Before
        beforeHuman    = (Format-Size $Before)
        afterBytes     = $After
        afterHuman     = (Format-Size $After)
        reclaimedBytes = $reclaimed
        reclaimedHuman = (Format-Size ([math]::Max(0,$reclaimed)))
        diskpartLog    = $logClean
    }

    # Emit defensively so the JSON block is NEVER empty, even if serialization fails.
    $json = $null
    try { $json = $payload | ConvertTo-Json -Depth 5 -Compress } catch { $json = $null }
    if ([string]::IsNullOrWhiteSpace($json)) {
        $json = '{{"ok":{0},"beforeBytes":{1},"afterBytes":{2},"reclaimedBytes":{3},"message":"json-fallback"}}' -f `
            ($Ok.ToString().ToLower()), $Before, $After, $reclaimed
    }
    Write-Host "`n===JSON_BEGIN==="
    Write-Output $json
    Write-Host "`n===JSON_END==="
}

# --- Guard: file must exist
if (-not (Test-Path -LiteralPath $VhdxPath)) {
    Write-Result -Ok $false -Msg "vhdx not found: $VhdxPath"
    return
}

# --- Guard: file must not be locked (WSL not fully released yet).
function Test-Locked {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}
if (Test-Locked $VhdxPath) {
    Start-Sleep -Seconds $RetrySeconds
    if (Test-Locked $VhdxPath) {
        Write-Result -Ok $false -Msg "vhdx is locked/in use. Ensure `wsl --shutdown` completed and no distro is Running, then retry."
        return
    }
}

$before = [long](Get-Item -LiteralPath $VhdxPath -Force).Length

# --- Build the diskpart script + a log path in the scratch dir.
$work    = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$dpScript = Join-Path $work ("compact-wsl-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
$dpLog    = Join-Path $work ("compact-wsl-{0}.log" -f ([guid]::NewGuid().ToString('N')))

@(
    "select vdisk file=`"$VhdxPath`""
    "attach vdisk readonly"
    "compact vdisk"
    "detach vdisk"
    "exit"
) | Set-Content -LiteralPath $dpScript -Encoding ascii

# --- Run diskpart ELEVATED and WAITED. The elevated process has its own
#     stdout, so redirect it to a log file we read afterward.
$inner = "diskpart /s `"$dpScript`" *> `"$dpLog`""
$log = ''
try {
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-NonInteractive','-Command', $inner) `
        -Verb RunAs -Wait -WindowStyle Hidden -PassThru
    # A non-elevated parent cannot read an elevated child's ExitCode (Access denied);
    # don't let that throw and abort reporting. Success is judged from the file size.
    try { $exit = $proc.ExitCode } catch { $exit = $null }
    if (Test-Path -LiteralPath $dpLog) { $log = (Get-Content -LiteralPath $dpLog -Raw) }
} catch {
    Write-Result -Ok $false -Msg "Elevation was cancelled or diskpart could not start: $($_.Exception.Message)" -Before $before -After $before
    Remove-Item -LiteralPath $dpScript,$dpLog -Force -ErrorAction SilentlyContinue
    return
}

$after = [long](Get-Item -LiteralPath $VhdxPath -Force).Length
Remove-Item -LiteralPath $dpScript,$dpLog -Force -ErrorAction SilentlyContinue

# diskpart prints "DiskPart successfully compacted the virtual disk file." on success.
$ok = ($log -match 'successfully compacted') -or ($after -lt $before)
$msg = if ($ok) {
    "diskpart compact completed. Reclaimed {0}." -f (Format-Size ([math]::Max(0,$before-$after)))
} else {
    "diskpart did not report success and the file did not shrink. See diskpartLog."
}

Write-Host ("`nBefore: {0}   After: {1}   Reclaimed: {2}" -f (Format-Size $before), (Format-Size $after), (Format-Size ([math]::Max(0,$before-$after)))) -ForegroundColor Green
Write-Result -Ok $ok -Msg $msg -Before $before -After $after -Log $log
