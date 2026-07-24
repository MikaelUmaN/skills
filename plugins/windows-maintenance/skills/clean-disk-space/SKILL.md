---
name: clean-disk-space
description: Reclaim disk space on Windows by finding large, stale, or junk files and pruning them with per-category confirmation. Two modes — "safe" (well-known junk — crash dumps, temp, caches, dangling Docker images/containers, stale logs) and "thorough" (hunts the largest culprits anywhere on disk). Always reports disk status and per-category potential savings first, and ALWAYS asks before deleting anything. WSL is off limits.
license: Apache-2.0
compatibility: Requires Windows with PowerShell. Operates only on Windows storage and never touches WSL.
disable-model-invocation: true
user-invocable: true
---

# Clean Disk Space

> **Bundled scripts:** the `.ps1` files this skill runs live in a `scripts/` subdirectory beside this SKILL.md. Wherever a command below shows `<skill-dir>`, substitute the absolute path of the directory containing this SKILL.md (you are given this skill's location when it loads). Do not hardcode an absolute user path.

Free up disk space by surfacing reclaimable files **grouped into categories**, then deleting only what the user explicitly approves — **one approval per category**.

## Modes

Read the mode from the invocation (`/clean-disk-space safe` or `/clean-disk-space thorough`). Default to **safe** if unspecified.

- **safe** — Targets well-known, low-risk junk: crash dumps, temp folders, Windows Update / Delivery Optimization caches, Recycle Bin, thumbnail caches, package-manager caches, stale log files, browser caches, and **dangling Docker images / stopped containers**. The goal is files that take up space and have not been used in a long time.
- **thorough** — Everything in safe, PLUS the heavy hitters: large/old files in Downloads, installer leftovers, `Windows.old`, the hibernation file, the **largest top-level directories**, and the **largest individual files** on disk. The goal is to find the biggest culprits wherever they are.

## Absolute rules

1. **WSL is OFF LIMITS.** Never touch `\\wsl$`, `\\wsl.localhost`, any `ext4.vhdx` / distro `.vhdx`, `%LOCALAPPDATA%\Docker\wsl\`, or `docker-desktop` data. The scan script already filters these out — do not add them back. WSL manages its own filesystem.
2. **Docker is managed only via the `docker` CLI** (`docker image prune`, etc.). This is fine and requested. Never delete Docker's backing vhdx files directly.
3. **NEVER delete anything before calling `AskUserQuestion`.** Default is KEEP. Only categories/items the user explicitly approves get removed. Anything not selected is treated as OFF BOUNDS.
4. **Permission is per CATEGORY.** A "yes" to one category is not a "yes" to another. Respect "no" — do not re-ask.
5. Items marked **review** (largest dirs/files, `Windows.old`, hibernation) require extra care — these often contain essential system data or the user's own files. Confirm specific items, never bulk-delete a review category.

## Procedure

### Phase 1 — Scan (read-only)
Run the scan script for the chosen mode. It prints disk status + a category breakdown and emits a JSON block between `===JSON_BEGIN===` and `===JSON_END===`.

```
powershell -ExecutionPolicy Bypass -File "<skill-dir>\scripts\scan-disk.ps1" -Mode safe
```
(thorough mode also enumerates the largest directories — note to the user it may take a minute.)

When calling PowerShell from the Bash tool, use the `powershell -File ... ` form above (no heredoc needed; the script takes `-Mode`). Parse the JSON block for exact sizes, file counts, and `topItems`.

### Phase 2 — Present status + savings
Show the user, in human-readable form:
1. **Disk status** for every fixed drive: used / total / free and % used.
2. **Potential savings per category**, sorted largest first, as a table: Category | Risk | Size | # items. Include the Docker summary (dangling image / stopped container counts, `docker system df`).
3. The **estimated directly reclaimable** total (excludes review-only categories).

For categories with notable `topItems`, list a few of the biggest so the user sees *related* files and can judge.

### Phase 3 — Ask permission (per category) — MANDATORY
Use **`AskUserQuestion`** before deleting anything. Frame each category as its own choice; default to non-destructive.

- Group categories into questions (max 4 options each, up to 4 questions per call; do multiple rounds if there are more). Use `multiSelect: true` where natural.
- For **safe** mode: ask which categories to clean. Typical options per category: "Delete all", "Skip". For Docker include "Prune dangling images + stopped containers".
- For **thorough** mode: for the **review** categories (largest dirs/files, Downloads, installers, `Windows.old`, hibernation), present the concrete items and ask **which may be removed** — anything not selected stays. Make clear that **unselected = off bounds**. Phrase positively: "Which of these may I remove?" so the safe default (select nothing) deletes nothing.

Never proceed to deletion for a category the user didn't explicitly approve.

### Phase 4 — Delete approved categories
For each approved category, delete and report bytes freed. Use these patterns. Always keep the WSL guard; skip locked/in-use files silently (`-ErrorAction SilentlyContinue`).

File-based categories (crash dumps, temp, caches, stale logs, thumbnails, browser caches, Windows Update / Delivery Optimization, large/old files, installers):
```powershell
# Delete a specific candidate set. Operate on the exact paths from the scan's topItems
# (or re-enumerate the same roots) — never a broader path than was approved.
$paths | Where-Object { $_ -notmatch '(\\wsl\$|\\wsl\.localhost|ext4\.vhdx|\\Docker\\wsl\\|docker-desktop)' } |
    ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -ErrorAction SilentlyContinue }
```

Recycle Bin:
```powershell
Clear-RecycleBin -Force -ErrorAction SilentlyContinue   # all drives; or -DriveLetter C
```

Docker (only if approved):
```powershell
docker container prune -f          # stopped containers
docker image prune -f              # dangling images (add -a only if user approved ALL unused images)
docker builder prune -f            # build cache
# docker volume prune -f           # ONLY if explicitly approved — volumes may hold real data
```

`Windows.old` — prefer the supported tool over raw delete (requires admin):
```powershell
# Recommended: cleanmgr /sageset then /sagerun, or:
Start-Process powershell -Verb RunAs -ArgumentList '-Command "Remove-Item C:\Windows.old -Recurse -Force"'
```

Hibernation file — never delete the file; if approved, disable hibernation (requires admin):
```powershell
Start-Process powercfg -Verb RunAs -ArgumentList '/h off'
```

### Phase 5 — Final report
Re-run the scan (`scan-disk.ps1 -Mode <mode>`) or recompute free space and show **before → after** per drive, plus total space reclaimed and a per-category summary of what was deleted vs. skipped.

## Notes
- Windows often has NTFS last-access updates disabled, so "not used in a long time" is judged by **LastWriteTime**. Mention this caveat — a file untouched by writes may still be in active use.
- Some system paths need elevation; if a delete is access-denied, report it rather than forcing.
- Be honest about savings: report what was actually freed, and note categories that were skipped or where files were locked/in-use.
