---
name: clean-disk-space
description: Reclaim disk space on Linux by finding large, old, or unused files and pruning them safely with per-category confirmation. Two modes — "safe" (dangling Docker images/containers, old logs, crash/core dumps, package caches, trash, stale temp files, large long-unused files) and "thorough" (largest culprits overall, build artifacts, all unused Docker objects, old kernels). Always shows disk status and per-category potential savings, and ALWAYS asks before deleting. Use when asked to "clean disk", "free up space", "disk is full", "prune docker", "what's eating my disk", or "clean-disk-space".
license: Apache-2.0
compatibility: Requires Linux with bash. Operates only on local filesystems and never touches WSL, Windows, or network mounts.
user-invocable: true
---

# Clean Disk Space

Reclaim disk space by finding large/old/unused files and pruning them **safely, with per-category confirmation**. Linux only.

> **Bundled scripts:** this skill ships a `scripts/` directory next to this file. Wherever you see `<skill-dir>`, substitute the absolute directory this `SKILL.md` was loaded from — never hardcode a user path.

> **The single hard rule: NEVER delete, move, `mv`, `rm`, prune, or vacuum ANYTHING before the user has explicitly approved that category.** Discovery is strictly read-only. Approved file-based items go to a quarantine dir first; they are hard-deleted only after a final explicit confirmation.

## Step 0 — Mode

Read the argument. `thorough` → thorough mode. Anything else or empty → **safe** mode (default). State the active mode to the user in one line.

- **safe** — conservative thresholds; targets clearly reclaimable or long-unused data.
- **thorough** — aggressive thresholds plus biggest-culprits-overall, build artifacts, all unused Docker, old kernels/snaps. Frame everything as opt-in: **default is to remove NOTHING** until the user names what is OK; everything unselected is OFF BOUNDS.

## Step 1 — Disk status (ALWAYS, both modes)

Run the scanner — it prints disk status first and then measures every category, read-only:

```bash
bash <skill-dir>/scripts/scan.sh <mode>
```

Present the `df -h` block in human-readable form. Call out any mount **> 80% used**.

## Step 1.5 — Leftover quarantines from prior runs (ALWAYS)

Quarantines are **never auto-purged** — a previous run may have left one behind (the user chose "Keep quarantine for now" in Step 6, or the session ended before the final delete). Before doing anything else, check for them and, crucially, **report what's inside so the user isn't asked to delete a black box**:

```bash
for d in "$HOME"/.disk-cleanup-quarantine/*/; do
  [ -d "$d" ] || continue
  echo "=== $d ==="
  stat -c 'created %w / modified %y' "$d"      # when it was quarantined
  du -sh "$d"                                    # total size
  [ -f "$d/MANIFEST.tsv" ] && cat "$d/MANIFEST.tsv" || echo "(no MANIFEST — inspect contents manually)"
done
```

For each leftover quarantine, present to the user **before** offering to delete it:
- **When** it was created (date + age in days) — from the dir's timestamp.
- **What** is in it — read `MANIFEST.tsv` and list each `original_path`, size, and category. If there is no manifest, list the actual contents (`du -sh` per top entry) and say the manifest is missing.
- **Why it's still here** — a prior run's "Keep for now" choice or an interrupted session; the skill does not delete quarantines on its own.
- Note whether the quarantined items are regenerable (caches, build `target/` dirs, package caches) vs. irreplaceable, based on their categories.

Then offer each leftover quarantine as its own deletable item in the Step 4 permission question (label it with its size and age, e.g. "Old quarantine from 2026-06-28 (25 days old) — 12 GB"). If approved, it is **already quarantined**, so skip Step 5 (do not re-quarantine it) and delete it directly at the Step 6 final-confirm — offering a restore option that `mv`s its manifest entries back to their `original_path`. Never delete a leftover quarantine without first showing this contents summary.

## Step 2 — Read the categorized scan

The scanner emits machine-parseable lines plus context:
- `CATEGORY\t<key>\t<title>\t<bytes>\t<count>\t<reversible>\t<note>` — one per category. `<bytes>` may be `0` for native-tool categories (Docker, journald, apt, snap, flatpak) whose sizes appear in their own blocks (`docker system df`, `journalctl --disk-usage`) — read those blocks for the real figures.
- `SAMPLE\t<key>\t<text>` — example paths/sizes for that category.
- `reversible` field: `yes` = quarantinable file move; `native` = irreversible native command (prune/clean/vacuum), cannot be quarantined; `review` = inspect samples and pick targets manually.

If a category's size is 0 / negligible, omit it.

**Root-only categories.** These act on system locations and require `sudo`: `rotated_logs`, `crash` (system paths like `/var/crash`, `/var/lib/systemd/coredump`), `journald`, `apt_cache`, `dnf`, `snap`. Docker normally works without `sudo`, but treat it as root-only too if a `docker` command fails with a permission error. If `scan.sh` reports `SUDO unavailable` (or a command later fails on permissions), the skill **cannot execute these itself** — still report them (the scan figures are valid), but mark each `(needs sudo)` and route it to the manual fallback in Step 7 instead of offering it as an actionable option.

## Step 3 — Present the report

Show a clean table ordered by size (largest first):

| Category | Reclaimable | Items | Reversible? | Notes / samples |
|---|---|---|---|---|

End with **Total potential savings** and the per-disk impact (which mount each category sits on). Briefly list a few sample paths per large category so the user sees *what* would go.

When `sudo` is unavailable, suffix each root-only category's name with **`(needs sudo)`** and add a one-line Notes entry saying it can't be cleaned automatically and will be offered as a copy-paste command in Step 7. Split the **Total potential savings** into "actionable now" vs "needs sudo (manual)" so the user sees both.

## Step 4 — Per-category permission (MANDATORY explicit approval)

Before touching anything, ask the user for **explicit per-category approval** — ideally a multi-select prompt where each **category is one option**, labelled with its size (e.g. "Docker reclaimable — 4.2 GB"). If your engine has no multi-select prompt, list the categories and have the user name the ones to clean.

- Group into batches of up to ~4 options per question if your prompt has a limit; split across several questions if there are more categories.
- **Selected = approved to clean. Unselected = OFF BOUNDS.**
- In thorough mode, make the OFF-BOUNDS framing explicit in the question text and default to nothing.
- For `review`-type categories (biggest files overall), present the concrete sample list and ask which specific groups/paths may go — never bulk-approve a whole filesystem.
- Tell the user which approved categories are **irreversible** (`native`) — those skip quarantine and get a separate final confirm in Step 6.
- **Do not** offer `(needs sudo)` categories as actionable options when you can't run `sudo` — they go to Step 7. (If you *do* have working `sudo`, handle them normally in Steps 5/6.)

## Step 5 — Quarantine approved file-based items (`reversible: yes`)

```bash
QDIR="$HOME/.disk-cleanup-quarantine/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$QDIR"
```

For each approved file: record it to `$QDIR/MANIFEST.tsv` (`original_path \t bytes \t category`), then move it preserving structure (`mkdir -p "$QDIR/<reldir>" && mv -- <file> "$QDIR/<reldir>/"`; use `sudo mv` for system files).

- If a source is on a different filesystem than `$HOME` (so `mv` would be a slow copy or risk filling `$HOME`), instead create the quarantine dir on that same mount, or record the path and defer to the Step-6 confirm rather than copying across mounts. Note this to the user.
- Show the exact commands before running them.
- Re-run `df -h`; report space freed and current quarantine size.

## Step 6 — Irreversible categories + final delete confirmation

For each approved `native` category, run its command **only after explicit approval confirming that specific command** (show the exact command):

- Docker (safe): `docker container prune -f`, `docker image prune -f` (dangling), `docker builder prune -f`, `docker volume prune -f`.
- Docker (thorough, only if `docker_all` approved): `docker system prune -a --volumes`.
- journald: `sudo journalctl --vacuum-size=<keep>` (ask how much to keep).
- APT: `sudo apt-get clean` and/or `sudo apt-get autoremove`.
- DNF: `sudo dnf clean all`.
- snap: `sudo snap remove --revision <rev> <name>` per disabled revision.
- flatpak: `flatpak uninstall --unused`.

Then a **final explicit confirmation** on the quarantine:
- **Permanently delete quarantine (X GB)** → `rm -rf "$QDIR"`.
- **Keep quarantine for now** → leave it; tell the user the path and that they can delete it later. Warn that it is **not** auto-purged and will be surfaced (with a contents summary, per Step 1.5) at the start of the next run so it isn't forgotten.
- **Restore everything** → read `MANIFEST.tsv` and `mv` each item back to its original path.

Finish with a final `df -h` and a summary of total space reclaimed.

## Step 7 — Manual fallback (commands the user runs themselves)

Whenever the skill **cannot complete an approved cleanup itself** — a `(needs sudo)` category with no working `sudo`, or any destructive command the user **denied at the permission prompt** — do not just drop it. Give the user a way to proceed:

- Print the **exact, copy-paste-ready command(s)** for each outstanding item, with a one-line comment of what it frees.
- Tell the user they can run them in their own terminal (or have the agent run them, if the engine allows running shell commands). `sudo` commands need an interactive terminal so the password prompt works.
- For the quarantine specifically, always give both the delete and the restore command using the real `$QDIR` path, so a denied "permanently delete" still leaves the user able to finish (or undo) on their own:
  - delete: `rm -rf "<QDIR>"`
  - restore: read `MANIFEST.tsv` and `mv` each item back to its `original_path`.
- Group these under a clear **"To finish manually"** heading and order by size. Never silently drop an approved-but-unexecuted item.

## Safety rules (always)

- **Never** touch: `/`, `/boot` and the active kernel, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib*`, `~/.ssh`, `~/.gnupg`, password/keychain/credential stores, running-container data, or mounted external/network drives.
- Discovery (`scan.sh`) is read-only — it never deletes. The only writes before the final confirm are `mv` into quarantine.
- Don't follow symlinks out of scope; the scanner already uses `-xdev`.
- Always print the exact destructive command before running it.
- If `sudo` is unavailable (`scan.sh` reports `SUDO unavailable`), still report root-only categories with their scanned sizes but mark them `(needs sudo)`, don't try to delete them, and hand the user copy-paste commands via Step 7.
- Never silently cap: if you skip or truncate anything (e.g. a huge tree), say so.
