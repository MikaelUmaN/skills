---
name: compress-wsl
description: Reclaim disk space that WSL2 is holding onto for Windows. A WSL2 distro's ext4.vhdx grows as data is written but never shrinks on its own, so space freed inside Linux stays locked from Windows' view. This skill checks the WSL version and the vhdx's current sparse status FIRST, measures the vhdx and free space, runs fstrim inside the guest, shuts WSL down, then compacts the disk in place with an elevated `diskpart compact vdisk` (the safe default). It does NOT use `wsl --manage --set-sparse` by default — Microsoft DISABLED sparse VHD in WSL 2.5.8.0 due to data-corruption risk (microsoft/WSL#13075) and it now needs `--allow-unsafe`; the skill only touches set-sparse as an explicit, risk-acknowledged opt-in and never enables it on an already-sparse or gated setup. It ALWAYS confirms before shutting WSL down, reports actual bytes reclaimed honestly (including "0 reclaimed"), and verifies the distro reboots with its filesystem intact afterward. Never deletes, moves, or recreates a vhdx.
license: Apache-2.0
compatibility: Runs in Windows Claude Code (PowerShell) to compact a WSL2 ext4.vhdx in place with diskpart; requires Windows 11, WSL2, and administrator elevation for diskpart.
disable-model-invocation: true
user-invocable: true
---

# Compress WSL

> **Bundled scripts:** the `.ps1` files this skill runs live in a `scripts/` subdirectory beside this SKILL.md. Wherever a command below shows `<skill-dir>`, substitute the absolute path of the directory containing this SKILL.md (you are given this skill's location when it loads). Do not hardcode an absolute user path.

Reclaim the slack space a WSL2 `ext4.vhdx` holds after data has been deleted inside the distro.
Measure **before**, compact, measure **after**, and verify the distro still boots cleanly.

## Absolute rules

1. **Never delete, move, or recreate a vhdx.** Only `diskpart compact vdisk` — it is lossless,
   touching only unused/zeroed blocks.
2. **diskpart is the default and only auto-approved mechanism.** **Never run
   `wsl --manage --set-sparse`** as part of the normal flow. Microsoft disabled sparse VHD in
   **WSL 2.5.8.0** over **data-corruption risk** ([microsoft/WSL#13075](https://github.com/microsoft/WSL/issues/13075));
   on gated versions it errors and needs `--allow-unsafe`. Only run set-sparse if the user
   **explicitly** asks after being told the corruption risk (see the gated opt-in below).
3. **Check sparse status before doing anything.** `measure-wsl.ps1` reports each vhdx's current
   `sparse` flag and the WSL version's `setSparseGated` state. Surface both. If a vhdx is
   **already sparse**, warn the user (it's in the risky mode and may compact poorly) and never
   attempt to toggle sparse.
4. **Always confirm before `wsl --shutdown`** — it kills every running Linux process across all
   distros. And confirm before the elevated diskpart step (a UAC prompt will appear).
5. **Report actual bytes reclaimed.** Compute before→after from real file sizes. If little or
   nothing was reclaimed, say so plainly — never imply success that didn't happen.
6. **Skip WSL1 distros** (no vhdx) and, unless the user explicitly asks, `docker-desktop*`
   distros (Docker manages its own disks).

## Mechanism

- **diskpart** (`compact vdisk`, elevated) — **the default**. In-place, minimal scratch, one-time,
  no persistent mode change, lossless. Works regardless of free-space headroom, which is why it is
  used even when the drive is nearly full. `measure-wsl.ps1` recommends this for every compactable
  distro.
- **set-sparse** (`wsl --manage <distro> --set-sparse true`) — **do not use by default.** It is
  disabled by Microsoft as of WSL 2.5.8.0 (data-corruption risk) and requires `--allow-unsafe` on
  gated versions. `measure-wsl.ps1` reports whether it would even fit space-wise
  (`setSparseFitsSpace`) purely as information — a "yes" there is **not** a recommendation to use
  it. Treat it only as the gated opt-in below.

### Gated set-sparse opt-in (only if the user explicitly insists)
If, after being told the corruption risk, the user still wants set-sparse (e.g. for ongoing
auto-reclaim), confirm explicitly via `AskUserQuestion`, then run
`wsl --manage <distro> --set-sparse true --allow-unsafe`. Strongly advise backing up / exporting
the distro first. Never do this silently or as a fallback.

## Procedure

### Phase 1 — Measure + recommend (read-only)
Run the measure script and parse the JSON block (`===JSON_BEGIN===` … `===JSON_END===`):
```
powershell -ExecutionPolicy Bypass -File "<skill-dir>\scripts\measure-wsl.ps1"
```
It reports the top-level **WSL version** and whether set-sparse is **gated** (`setSparseGated`),
and per distro: state, vhdx path/size, **current `sparse` flag**, **guest used-data**, drive free
space, and a **`recommendation`** (always `diskpart`) with the reason.
(It briefly starts each WSL2 distro to read `df` — this is read-only.)

Present to the user: the WSL version + that set-sparse is disabled on gated versions; and per
compactable distro the vhdx size, guest used-data, drive free space, **current sparse status**,
and that the plan is an in-place `diskpart` compact. **If any vhdx is already `sparse=true`, flag
it** — warn that it's in Microsoft's risky sparse mode and may not compact well; do not toggle
sparse. If there are multiple WSL2 distros, default to all of them but let the user narrow the
selection.

### Phase 2 — Confirm go-ahead — MANDATORY
Use **`AskUserQuestion`** to confirm the destructive sequence: **fstrim → `wsl --shutdown` →
diskpart compact**. Note diskpart triggers a **UAC prompt** and that shutdown ends all running
Linux processes. The mechanism is **diskpart** — do **not** offer set-sparse here. (Only if the
user explicitly raises set-sparse, follow the gated opt-in in the Mechanism section, with the
corruption warning.) Do not proceed for any distro the user didn't approve.

### Phase 3 — fstrim (maximize what can be reclaimed)
For each chosen WSL2 distro, discard freed blocks so compaction can reclaim them. Run as root to
avoid a sudo password prompt:
```
wsl -d <distro> -u root -- fstrim -av
```
If the distro/filesystem doesn't support fstrim, note it and continue (compaction still reclaims
already-unmapped blocks).

### Phase 4 — Shut down WSL
```
wsl --shutdown
```
Then verify nothing is Running before touching the vhdx:
```
wsl --list --running
```
It must report no running distros. Pause a few seconds so the vhdx file handle is released.

### Phase 5 — Compact (diskpart, in-place)
Run the elevated compaction (UAC prompt; parse the JSON result):
```
powershell -ExecutionPolicy Bypass -File "<skill-dir>\scripts\compact-wsl.ps1" -VhdxPath "<vhdxPath from Phase 1>"
```
If the script reports the vhdx is **locked**, WSL hadn't fully released it — wait a few seconds
and run it once more.

(Do **not** run set-sparse here. It is only ever run via the explicit gated opt-in in the
Mechanism section, never as part of this phase.)

### Phase 6 — Report before → after
Re-run `measure-wsl.ps1` and show, per distro: vhdx size **before → after**, **bytes reclaimed**,
the current sparse flag, and **C: free before → after**. Be honest about small or zero gains — if
the disk barely shrank, there simply wasn't much slack to reclaim, and that is the correct outcome
to report.

### Phase 7 — Verify boot + integrity
Confirm the distro starts and its filesystem is intact:
```
wsl -d <distro> -- true                 # exit 0 => booted
wsl -d <distro> -u root -- uname -a      # kernel/userspace responds
wsl -d <distro> -- df -h /               # root fs mounted, data present
wsl -d <distro> -u root -- sh -c 'echo ok > /tmp/.compress_wsl_test && cat /tmp/.compress_wsl_test && rm -f /tmp/.compress_wsl_test'
```
All should succeed. Report pass/fail per check. A full `fsck` on the root fs isn't possible while
it's mounted, but `diskpart compact vdisk` is block-level lossless (only unused/zeroed regions are
dropped), so the guest filesystem and data are not modified.

## Notes

- **Sparse VHD is risky right now.** Do **not** suggest `[experimental] sparseVhd=true` in
  `%USERPROFILE%\.wslconfig` or `--set-sparse` as an "auto-reclaim" convenience — Microsoft
  disabled sparse VHD in WSL 2.5.8.0 over data corruption
  ([microsoft/WSL#13075](https://github.com/microsoft/WSL/issues/13075)). If the user asks about
  it, relay the risk and that it needs `--allow-unsafe`; recommend re-running this skill's diskpart
  compact periodically instead. Check upstream before treating sparse as safe again.
- **Very low free space is fine for diskpart.** `compact vdisk` is in-place and needs almost no
  scratch space, so it works even when C: is nearly full (as on this machine). Still warn the user
  if free space is critically low before starting.
- vhdx paths come from the registry (`HKCU:\...\Lxss`), so imported distros with custom locations
  are handled too — always compact the path reported by `measure-wsl.ps1`, never a guessed one.
