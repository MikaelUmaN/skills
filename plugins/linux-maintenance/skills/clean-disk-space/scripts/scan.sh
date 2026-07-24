#!/usr/bin/env bash
# clean-disk-space :: read-only disk-usage scanner.
# Measures reclaimable space per CATEGORY. NEVER deletes, moves, or prunes anything.
# Usage: scan.sh [safe|thorough]
set -uo pipefail

MODE="${1:-safe}"
[[ "$MODE" != "safe" && "$MODE" != "thorough" ]] && MODE="safe"

# Thresholds differ per mode.
if [[ "$MODE" == "thorough" ]]; then
  BIG_MB=50         # "large file" cut-off (MB)
  STALE_DAYS=30     # not accessed/modified in N days
  TMP_DAYS=3
else
  BIG_MB=100
  STALE_DAYS=90
  TMP_DAYS=7
fi

HOME_DIR="${HOME:-/home/$(id -un)}"
MAX_SAMPLES=8       # cap sample paths printed per category

# ---- helpers ---------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Run a command under a wall-clock cap (if `timeout` exists) so one slow mount
# can't hang the whole scan.
tmo() { if have timeout; then timeout "$1" "${@:2}"; else "${@:2}"; fi; }

# Local, cleanable mountpoints only. Excludes pseudo filesystems AND
# WSL/Windows/network mounts (drvfs, 9p, cifs/nfs, /mnt/*, WSL drivers) — those
# are off-bounds "external drives" and pathologically slow to walk.
real_mounts() {
  df --output=target,fstype -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2 | \
  while read -r mp fstype; do
    case "$fstype" in drvfs|9p|fuseblk|cifs|nfs|nfs4|smbfs|fuse.*) continue;; esac
    case "$mp" in /mnt/*|/usr/lib/wsl/*|/init|/snap/*|/proc*|/sys*) continue;; esac
    echo "$mp"
  done
}

# Non-interactive sudo probe. SUDO="" means no privilege escalation available.
SUDO=""
if have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

# Human-readable bytes.
hr() { numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# Sum file sizes printed one-per-line on stdin (`find -printf '%s\n'`). Prints total bytes.
# NOTE: never capture `find -print0` into a shell variable — bash strips NUL bytes.
sum_bytes() { awk '{s+=$1} END{print s+0}'; }
# Count non-empty lines on stdin. Always prints exactly one number, exits 0.
count_lines() { awk 'NF{n++} END{print n+0}'; }

# Emit one category record. Args: key, title, bytes, count, reversible(yes/no/native), note
emit() {
  printf 'CATEGORY\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}
emit_sample() { printf 'SAMPLE\t%s\t%s\n' "$1" "$2"; }

section() { printf '\n=== %s ===\n' "$1"; }

# ---- 0. environment banner -------------------------------------------------
printf 'SCAN_MODE\t%s\n' "$MODE"
printf 'SUDO\t%s\n' "$([[ -n "$SUDO" ]] && echo available || echo unavailable)"
printf 'THRESHOLDS\tbig>=%sMB\tstale>%sd\ttmp>%sd\n' "$BIG_MB" "$STALE_DAYS" "$TMP_DAYS"

# ---- 1. disk status --------------------------------------------------------
section "DISK STATUS"
df -h -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -h

# ===========================================================================
# CATEGORY SCANS (read-only)
# ===========================================================================

# --- 1) Docker reclaimable --------------------------------------------------
if have docker && docker info >/dev/null 2>&1; then
  section "DOCKER"
  docker system df 2>/dev/null || true
  dangling=$(docker images -f dangling=true -q 2>/dev/null | wc -l | tr -d ' ')
  exited=$(docker ps -a -f status=exited -f status=created -q 2>/dev/null | wc -l | tr -d ' ')
  # Reclaimable bytes from `docker system df --format` (sum of RECLAIMABLE column is non-trivial; use plain df text).
  emit docker "Docker reclaimable (dangling images, stopped containers, build cache, unused volumes)" \
    "0" "$((dangling + exited))" "native" "dangling_images=$dangling exited_containers=$exited — see 'docker system df' above for sizes; thorough mode also targets ALL unused images"
  docker images -f dangling=true --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2>/dev/null | head -n "$MAX_SAMPLES" | while read -r line; do emit_sample docker "$line"; done
fi

# --- 2) System & rotated logs ----------------------------------------------
section "LOGS"
if have journalctl; then
  jusage=$($SUDO journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGTPE]i?B?' | tail -1 || true)
  emit journald "systemd journal logs" "0" "1" "native" "journalctl --disk-usage => ${jusage:-unknown}; reclaim via 'journalctl --vacuum-size='"
fi
if [[ -d /var/log ]]; then
  LOG_EXPR=( -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -regex '.*\.[0-9]+$' \) )
  rbytes=$($SUDO find /var/log "${LOG_EXPR[@]}" -printf '%s\n' 2>/dev/null | sum_bytes)
  rcount=$($SUDO find /var/log "${LOG_EXPR[@]}" -printf '.\n' 2>/dev/null | count_lines)
  emit rotated_logs "Rotated/archived logs in /var/log" "$rbytes" "$rcount" "yes" "compressed & numbered old logs"
  $SUDO find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -regex '.*\.[0-9]+$' \) -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n "$MAX_SAMPLES" | while read -r sz p; do emit_sample rotated_logs "$(hr "$sz")  $p"; done
fi

# --- 3) Crash & core dumps --------------------------------------------------
section "CRASH"
crash_files() {
  $SUDO find /var/crash -type f -printf "%s\t%p\n" 2>/dev/null
  find "$HOME_DIR" -maxdepth 4 -type f \( -name 'core' -o -name 'core.*' \) -printf "%s\t%p\n" 2>/dev/null
  $SUDO find /var/lib/systemd/coredump -type f -printf "%s\t%p\n" 2>/dev/null
}
crash_total=$(crash_files | cut -f1 | sum_bytes)
crash_count=$(crash_files | count_lines)
emit crash "Crash reports & core dumps (/var/crash, coredump, core.*)" "$crash_total" "$crash_count" "yes" "apport/systemd-coredump + core files"
{ $SUDO find /var/crash -type f -printf '%s\t%p\n' 2>/dev/null; $SUDO find /var/lib/systemd/coredump -type f -printf '%s\t%p\n' 2>/dev/null; } | sort -rn | head -n "$MAX_SAMPLES" | while read -r sz p; do emit_sample crash "$(hr "$sz")  $p"; done

# --- 4) Package-manager caches ---------------------------------------------
section "PKGCACHE"
if [[ -d /var/cache/apt/archives ]]; then
  aptb=$($SUDO find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  aptc=$($SUDO find /var/cache/apt/archives -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')
  emit apt_cache "APT package cache (/var/cache/apt/archives/*.deb)" "$aptb" "$aptc" "native" "reclaim via 'apt-get clean'"
fi
if have dnf && [[ -d /var/cache/dnf ]]; then
  dnfb=$($SUDO du -sb /var/cache/dnf 2>/dev/null | awk '{print $1+0}')
  emit dnf_cache "DNF package cache (/var/cache/dnf)" "${dnfb:-0}" "1" "native" "reclaim via 'dnf clean all'"
fi

# --- 5) User caches ---------------------------------------------------------
section "USERCACHE"
if [[ -d "$HOME_DIR/.cache" ]]; then
  cb=$(du -sb "$HOME_DIR/.cache" 2>/dev/null | awk '{print $1+0}')
  emit user_cache "User caches (~/.cache: thumbnails, pip/npm/yarn/go, browsers)" "${cb:-0}" "1" "yes" "app caches regenerate on demand"
  du -sb "$HOME_DIR/.cache"/* 2>/dev/null | sort -rn | head -n "$MAX_SAMPLES" | while read -r sz p; do emit_sample user_cache "$(hr "$sz")  $p"; done
fi

# --- 6) Trash ---------------------------------------------------------------
section "TRASH"
trash_total=0
for td in "$HOME_DIR/.local/share/Trash" "$HOME_DIR/.Trash"; do
  if [[ -d "$td" ]]; then
    tb=$(du -sb "$td" 2>/dev/null | awk '{print $1+0}')
    trash_total=$((trash_total + tb))
  fi
done
emit trash "Trash / recycle bins (~/.local/share/Trash)" "$trash_total" "1" "yes" "already-deleted items"

# --- 7) Stale temp files ----------------------------------------------------
section "TEMP"
tmp_files() {
  find /tmp -mindepth 1 -type f -mtime +"$TMP_DAYS" -printf "%s\n" 2>/dev/null
  $SUDO find /var/tmp -mindepth 1 -type f -mtime +"$TMP_DAYS" -printf "%s\n" 2>/dev/null
}
tmpb=$(tmp_files | sum_bytes)
tmpc=$(tmp_files | count_lines)
emit temp "Stale temp files (/tmp, /var/tmp older than ${TMP_DAYS}d)" "$tmpb" "$tmpc" "yes" "not modified in >${TMP_DAYS} days"

# --- 8) Large long-unused files --------------------------------------------
section "LARGEOLD"
SEARCH_ROOTS=("$HOME_DIR")
for d in /data /srv /opt; do [[ -d "$d" ]] && SEARCH_ROOTS+=("$d"); done
bigfiles=$(find "${SEARCH_ROOTS[@]}" -xdev -type f -size +"${BIG_MB}"M -atime +"$STALE_DAYS" -mtime +"$STALE_DAYS" \
            ! -path "*/.cache/*" ! -path "*/.local/share/Trash/*" \
            -printf '%s\t%A@\t%p\n' 2>/dev/null)
bob=$(printf '%s\n' "$bigfiles" | awk -F'\t' '{s+=$1} END{print s+0}')
boc=$(printf '%s\n' "$bigfiles" | count_lines)
emit large_old "Large long-unused files (>=${BIG_MB}MB, not read/written in >${STALE_DAYS}d)" "$bob" "$boc" "yes" "core target: big files gathering dust under ${SEARCH_ROOTS[*]}"
printf '%s\n' "$bigfiles" | sort -rn | head -n "$MAX_SAMPLES" | while IFS=$'\t' read -r sz at p; do [[ -n "$p" ]] && emit_sample large_old "$(hr "$sz")  $p"; done

# ===========================================================================
# THOROUGH-ONLY CATEGORIES
# ===========================================================================
if [[ "$MODE" == "thorough" ]]; then

  # --- 9) Largest files & dirs overall --------------------------------------
  # Bounded: directory totals capped at depth 3 (NOT `du -a`, which walks every
  # file and is too slow on large disks), plus the biggest individual files.
  section "BIGGEST"
  DU_DEPTH=3
  while read -r mp; do
    [[ -z "$mp" ]] && continue
    emit_sample biggest "--- mountpoint $mp (top dirs, depth<=$DU_DEPTH) ---"
    tmo 90 $SUDO du -hx --max-depth="$DU_DEPTH" "$mp" 2>/dev/null | sort -rh | head -n 15 | while read -r sz p; do emit_sample biggest "$sz  $p"; done
    emit_sample biggest "--- $mp (largest individual files) ---"
    tmo 90 $SUDO find "$mp" -xdev -type f -size +200M -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 10 | while IFS=$'\t' read -r sz p; do [[ -n "$p" ]] && emit_sample biggest "$(hr "$sz")  $p"; done
  done < <(real_mounts)
  emit biggest "Largest files & directories overall (regardless of age)" "0" "0" "review" "inspect samples (per-mount scans capped at 90s each); pick targets manually"

  # --- 10) Build artifacts --------------------------------------------------
  section "BUILD"
  bafiles=$(find "$HOME_DIR" -xdev -type d \( -name node_modules -o -name target -o -name build -o -name .gradle -o -name __pycache__ -o -name .venv -o -name venv \) -prune -print 2>/dev/null)
  bab=0
  while IFS= read -r d; do [[ -z "$d" ]] && continue; s=$(du -sb "$d" 2>/dev/null | awk '{print $1+0}'); bab=$((bab+s)); done <<<"$bafiles"
  bac=$(printf '%s\n' "$bafiles" | count_lines)
  emit build "Build artifacts (node_modules, target, build, .venv, __pycache__)" "$bab" "$bac" "yes" "regenerated by rebuild; verify projects are inactive"
  printf '%s\n' "$bafiles" | head -n "$MAX_SAMPLES" | while read -r d; do [[ -n "$d" ]] && emit_sample build "$(du -sh "$d" 2>/dev/null)"; done

  # --- 11) All unused docker ------------------------------------------------
  if have docker && docker info >/dev/null 2>&1; then
    section "DOCKER_ALL"
    emit docker_all "ALL unused Docker images/volumes (docker system prune -a --volumes)" "0" "0" "native" "AGGRESSIVE: removes every image not used by a container; see 'docker system df'"
  fi

  # --- 12) Old kernels / snaps / flatpak ------------------------------------
  section "SYS_EXTRA"
  if have snap; then
    disabled=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    [[ -n "$disabled" ]] && emit snaps "Disabled old snap revisions" "0" "$(printf '%s\n' "$disabled" | count_lines)" "native" "remove via 'snap remove --revision'"
    printf '%s\n' "$disabled" | head -n "$MAX_SAMPLES" | while read -r l; do [[ -n "$l" ]] && emit_sample snaps "$l"; done
  fi
  if have flatpak; then
    emit flatpak "Unused flatpak runtimes" "0" "0" "native" "reclaim via 'flatpak uninstall --unused'"
  fi
  if [[ -d "$HOME_DIR/Downloads" ]]; then
    dlfiles=$(find "$HOME_DIR/Downloads" -xdev -type f -mtime +"$STALE_DAYS" -printf '%s\t%p\n' 2>/dev/null)
    dlb=$(printf '%s\n' "$dlfiles" | awk -F'\t' '{s+=$1} END{print s+0}')
    dlc=$(printf '%s\n' "$dlfiles" | count_lines)
    emit downloads "Old files in ~/Downloads (>${STALE_DAYS}d)" "$dlb" "$dlc" "yes" "downloaded files gathering dust"
    printf '%s\n' "$dlfiles" | sort -rn | head -n "$MAX_SAMPLES" | while IFS=$'\t' read -r sz p; do [[ -n "$p" ]] && emit_sample downloads "$(hr "$sz")  $p"; done
  fi
fi

section "SCAN COMPLETE"
echo "DONE"
