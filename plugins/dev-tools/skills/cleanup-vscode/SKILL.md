---
name: cleanup-vscode
description: Detect and kill stale/orphaned VS Code server processes, language servers, Claude Code instances, Jupyter kernels, and clean up orphaned kernel connection files on WSL2.
license: Apache-2.0
compatibility: Linux/WSL2. Requires bash with ps, grep, awk, sleep, and kill; Jupyter runtime files under ~/.local/share/jupyter.
allowed-tools: Bash, AskUserQuestion
user-invocable: true
---

# Cleanup VS Code Stale Processes

Scan the system for stale and orphaned VS Code Remote Server processes on WSL2
and present a cleanup proposal for user confirmation before killing anything.

**CRITICAL**: Never kill active processes. Always present findings and ask user
before terminating anything.

## Instructions

When the user invokes `/cleanup-vscode`, follow these steps exactly:

### Step 1: Discover the process landscape

Run the following commands to build a complete picture. Run them all in a single
bash call to get a consistent snapshot:

```bash
echo "=== MAIN VSCODE SERVER ==="
ps -eo pid,ppid,etime,rss,args | grep "out/server-main.js" | grep -v grep

echo "=== EXTENSION HOSTS ==="
ps -eo pid,ppid,etime,rss,%cpu,args | grep "type=extensionHost" | grep -v grep

echo "=== PROCESSES WITH clientProcessId ==="
ps -eo pid,ppid,rss,args | grep "clientProcessId" | grep -v grep

echo "=== CLAUDE CODE INSTANCES ==="
ps -eo pid,ppid,etime,rss,%cpu,args | grep "claude.*native-binary\|claude.*stream-json" | grep -v grep

echo "=== JUPYTER KERNELS ==="
ps -eo pid,ppid,etime,rss,args | grep "ipykernel_launcher" | grep -v grep

echo "=== KERNEL CONNECTION FILES ==="
ls -la ~/.local/share/jupyter/runtime/kernel-*.json 2>/dev/null

echo "=== FILE WATCHERS ==="
ps -eo pid,ppid,etime,rss,args | grep "type=fileWatcher" | grep -v grep

echo "=== ORPHANED PROCESSES (PPID=1) ==="
ps -eo pid,ppid,etime,rss,args | grep -E "vscode-server|extensionHost|pylance|ipykernel" | grep -v grep | awk '$2 == 1'
```

### Step 2: Classify each extension host as ORPHANED or LIVE

This is the primary signal for whether a host is safe to terminate. Everything
else (CPU, age) is informational only.

Capture the main vscode-server PID first, then classify each ExtHost:

```bash
MAIN_PID=$(ps -eo pid,args | grep "out/server-main.js" | grep -v grep | awk '{print $1}')
echo "MAIN_PID=$MAIN_PID"

for EHPID in $(ps -eo pid,args | grep "type=extensionHost" | grep -v grep | awk '{print $1}'); do
  EH_PPID=$(ps -p "$EHPID" -o ppid= 2>/dev/null | tr -d ' ')
  if [ -z "$EH_PPID" ]; then continue; fi
  if [ "$EH_PPID" = "1" ] || ! ps -p "$EH_PPID" > /dev/null 2>&1; then
    echo "ORPHANED: ExtHost $EHPID (PPID=$EH_PPID — parent missing or init)"
  elif [ "$EH_PPID" = "$MAIN_PID" ]; then
    echo "LIVE: ExtHost $EHPID (PPID=$EH_PPID = main server — window likely open)"
  else
    echo "UNKNOWN: ExtHost $EHPID (PPID=$EH_PPID — neither init nor main server)"
  fi
done
```

**Classification rule:**
- **ORPHANED** — `PPID == 1` OR the PPID no longer exists as a process. Parent
  died, so no VS Code window can still be bound to this host. Safe to terminate.
- **LIVE** — PPID is the running main vscode-server. The server still manages
  this host, which means a VS Code window is almost certainly still attached.
  **Killing this will trigger a respawn** (the server reconnects the window to a
  fresh ExtHost). Only propose termination if the user explicitly opts into
  aggressive mode and names the host.
- **UNKNOWN** — neither init nor the main server. Treat as LIVE (conservative).

### Step 2b: Sample CPU activity (INFORMATIONAL ONLY)

Sample CPU usage twice with a 3-second gap for display purposes. **Do NOT use
this to decide whether to kill a host** — a VS Code window left open for hours
may have zero CPU activity and still be in use.

```bash
# First sample
ps -eo pid,cputime,args | grep "type=extensionHost" | grep -v grep
sleep 3
# Second sample
ps -eo pid,cputime,args | grep "type=extensionHost" | grep -v grep
```

If cputime did NOT change between samples, flag the host as `idle` in the
informational report. If it changed, flag as `active`. This is a label only; it
does not change the classification from Step 2.

### Step 3: Map extension hosts to projects

For each extension host PID, identify which project/workspace it serves by
looking at its child processes' paths:

```bash
# For each extension host PID, find children that reveal the project
for EHPID in $(ps -eo pid,args | grep "type=extensionHost" | grep -v grep | awk '{print $1}'); do
  echo "=== ExtHost PID $EHPID ==="
  # Look for venv paths in child Pylance/Python processes
  ps -eo pid,ppid,args | grep "clientProcessId=$EHPID" | grep -v grep | grep -oP '/[^ ]*\.venv/[^ ]*' | head -3
  # Also check ipykernel children
  ps -eo pid,ppid,args | awk -v p=$EHPID '$2==p' | grep -oP '/[^ ]*/\.venv/' | head -1
  # Check Claude Code instances that are children
  ps -eo pid,ppid,args | awk -v p=$EHPID '$2==p' | grep claude | head -1
done
```

The venv path reveals the project directory (e.g. a path ending in
`crudeinventory/NP-crude-inventory/.venv/` identifies the crude inventory project).

### Step 4: Identify orphaned Jupyter kernel connection files

```bash
# Get connection files referenced by running kernels
ACTIVE_KERNEL_FILES=$(ps -eo args | grep ipykernel_launcher | grep -v grep | grep -oP '(?<=--f=)\S+')

# List all kernel connection files and check which ones have no running kernel
for f in ~/.local/share/jupyter/runtime/kernel-*.json; do
  if echo "$ACTIVE_KERNEL_FILES" | grep -qF "$f"; then
    echo "ACTIVE: $f"
  else
    echo "ORPHANED: $f"
  fi
done
```

### Step 5: Identify orphaned child processes

Find processes whose `--clientProcessId` references a PID that no longer exists:

```bash
for LINE in $(ps -eo pid,args | grep "clientProcessId" | grep -v grep | sed 's/.*clientProcessId=\([0-9]*\).*/\1/' | sort -u); do
  if ! ps -p "$LINE" > /dev/null 2>&1; then
    echo "DEAD PARENT $LINE — orphaned children:"
    ps -eo pid,rss,args | grep "clientProcessId=$LINE" | grep -v grep
  fi
done
```

### Step 6: Calculate memory totals

For each extension host, sum the RSS of the extension host process itself plus
all its children (processes with matching `--clientProcessId` and direct child
PIDs). Convert KB to MB for display.

### Step 7: Present findings to the user

Split the report into two clearly separated sections. The split matches the
default recommendation: Section A is safe to clean, Section B is informational.

#### Section A — Recommended for cleanup (safe)

**A.1 Orphaned Jupyter kernel connection files** — list each file with mtime.

**A.2 Orphaned child processes** — parent ExtHost is dead. List PID, RSS, description.

**A.3 ORPHANED extension hosts** — `PPID == 1` or parent dead. List PID, age,
RSS (host + children), project mapping if any. These are the only ExtHosts in
the default recommendation.

#### Section B — For your information only (NOT recommended)

**B.1 LIVE extension hosts.** For each, show:
- PID, age, RSS (MB), CPU activity flag (`idle` / `active` from Step 2b)
- Project mapping (from Step 3)
- Child count and their total RSS
- Claude Code instances running under this host

Precede this list with the note:

> These are still registered with the VS Code server (PPID = main server),
> which means a VS Code window is almost certainly still attached. Killing any
> of them will trigger the server to respawn the host when the window
> reconnects, and may disrupt unsaved language-server state, a running debug
> session, or a Jupyter kernel in that window. Use the **Aggressive** option
> below only if you know a specific host can go.

#### Protected (will NEVER be touched)

- The main vscode-server process.
- The extension host running THIS Claude Code conversation. Identify it by
  walking up from the current claude PID via `$PPID` until you reach a process
  whose args contain `type=extensionHost`.

#### Summary line

```
Recommended cleanup: N kernel files + N orphaned child procs + N ORPHANED ExtHosts (~X MB reclaimable)
Informational (LIVE ExtHosts): N (total ~Y MB, not recommended)
```

### Step 8: Ask user what to clean

The default recommendation is conservative: it only touches things we KNOW are
unused. Killing a LIVE ExtHost requires an explicit opt-in.

Use AskUserQuestion with these options (in this order, with the first labeled
"(Recommended)"):

- **"Recommended cleanup"** — deletes orphaned kernel files, kills orphaned
  child processes, and kills any ORPHANED ExtHosts (PPID=1 / dead parent).
  Never touches LIVE ExtHosts. This is the safe default.
- **"Safe only"** — orphaned kernel files + orphaned child processes only. No
  ExtHosts at all. Use when the user wants the absolute minimum.
- **"Aggressive: kill specific LIVE ExtHost(s)"** — user picks by number from
  the informational list in Section B. The question description must include
  the warning: *"These are registered with the server. Killing may disrupt
  another window, and a respawn is likely if the window is still open — only
  choose this if you know the host belongs to a closed/stuck window."* Also
  performs the Safe-only items.
- **"None"** — abort, clean nothing.

Do not offer a single-option "kill everything idle" bundle. Aggressive
terminations must be per-host and explicit.

### Step 9: Execute cleanup

Map the user's Step 8 choice to the sub-steps below:

- **Recommended cleanup** → run 9.1, 9.2, 9.3 (targets = ORPHANED ExtHosts), 9.4
- **Safe only** → run 9.1, 9.2, 9.4
- **Aggressive** → run 9.1, 9.2, 9.3 (targets = the specific LIVE ExtHost(s) the user selected), 9.4
- **None** → do nothing and exit

#### 9.1 Delete orphaned kernel connection files
```bash
rm -f <file1> <file2> ...
```

#### 9.2 Kill orphaned child processes (SIGTERM first)
```bash
kill <pid1> <pid2> ... 2>/dev/null
sleep 2
# Check survivors and SIGKILL
kill -9 <pid1> <pid2> ... 2>/dev/null
```

#### 9.3 Kill selected extension hosts (this kills all their children too)

The set of targets depends on the user's Step 8 choice — ORPHANED hosts under
Recommended, or the specific LIVE hosts the user named under Aggressive. Do not
expand the target set beyond what the user chose.

```bash
# Kill the extension host — its children (Pylance, Claude, kernels, etc.)
# will receive SIGHUP when parent dies, but kill them explicitly too
CHILDREN=$(ps -eo pid,ppid | awk -v p=<EHPID> '$2==p {print $1}')
# Also get grandchildren (processes with --clientProcessId=<EHPID>)
GRANDCHILDREN=$(ps -eo pid,args | grep "clientProcessId=<EHPID>" | grep -v grep | awk '{print $1}')

# SIGTERM all of them
kill $CHILDREN $GRANDCHILDREN <EHPID> 2>/dev/null
sleep 3
# SIGKILL survivors
kill -9 $CHILDREN $GRANDCHILDREN <EHPID> 2>/dev/null
```

#### 9.4 Kill orphaned Jupyter kernels whose connection file was deleted

Check if any `ipykernel_launcher` processes are still running for deleted
connection files and kill them too.

### Step 10: Verify and report

```bash
echo "=== AFTER CLEANUP ==="
echo "Extension hosts remaining:"
ps -eo pid,etime,rss,args | grep "type=extensionHost" | grep -v grep | wc -l

echo "Total vscode-server processes:"
ps aux | grep vscode-server | grep -v grep | wc -l

echo "Jupyter kernels running:"
ps -eo pid,args | grep ipykernel_launcher | grep -v grep | wc -l

echo "Kernel connection files:"
ls ~/.local/share/jupyter/runtime/kernel-*.json 2>/dev/null | wc -l

echo "Claude Code instances:"
ps -eo pid,args | grep "claude.*native-binary" | grep -v grep | wc -l
```

Report what was cleaned and how much memory was freed (compare RSS totals
before and after).

## Important Safety Rules

1. **NEVER kill the main vscode-server process** (`out/server-main.js`). This
   would disconnect ALL VS Code windows.

2. **NEVER kill the extension host that owns THIS conversation**. To find it:
   walk up from the current process using `$PPID` or check which extension host
   PID matches the `--clientProcessId` of the current claude process.

3. **NEVER auto-kill anything** without user confirmation via AskUserQuestion.

4. **Prefer SIGTERM** over SIGKILL. Only use SIGKILL as a fallback after 3
   seconds if the process is still alive.

5. **By default, never propose killing an ExtHost whose PPID is the live main
   vscode-server.** CPU idleness and age are informational only — a window left
   open for hours may still be in use. An ExtHost is only eligible for default
   cleanup when its PPID is `1` or its parent process no longer exists
   (classified ORPHANED in Step 2). To terminate a LIVE ExtHost, the user must
   explicitly choose the Aggressive path and accept that a respawn is likely if
   a window is still open.
