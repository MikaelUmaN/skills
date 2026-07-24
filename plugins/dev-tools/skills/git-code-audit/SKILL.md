---
name: git-code-audit
description: Run a fast git-history audit of an unfamiliar (or your own) repo before reading the code — high-churn files, bus factor, bug clusters, project momentum, and firefighting patterns — and present it as a clean README-style markdown report. Use when asked to "audit", "assess", "get a feel for", or "size up" a codebase via its git history, or when the user references the piechowski.io "git commands before reading code" approach.
license: Apache-2.0
compatibility: Cross-platform. Requires git and a POSIX shell (bash) with standard text utilities (grep, sort, uniq, awk).
user-invocable: true
---

# Git Code Audit

A handful of quick `git` commands that reveal the shape and health of a codebase
*before* you read a single line of it. Based on
https://piechowski.io/post/git-commands-before-reading-code/.

The goal is a **clean README-format summary** of what the git history reveals —
not raw command dumps. Run the commands, read the numbers, then write the report.

## Step 0 — Locate the repo and its source directory

**Argument:** an optional path to the repo root. If the user passed a path
argument, treat it as `<REPO>`. If no argument was given, default to the
current working directory.

The churn analysis (Step 1) must be run from the **source directory**, not the
repo root — otherwise lockfiles, generated code, and vendored deps dominate the
results and hide the real signal.

1. Resolve `<REPO>`: use the passed path if any, else the current directory.
   Confirm it's a git repo with `git -C <REPO> rev-parse --show-toplevel`
   (this also normalizes to the actual repo root if you were handed a subdir).
   If it isn't a git repo, say so and stop.
2. Pick the source directory (relative to `<REPO>`). Check, in order, for the first that exists and
   contains the bulk of the hand-written code:
   `src/`, `app/`, `lib/`, `internal/`, `cmd/`, `pkg/`, `packages/`, `source/`.
   - Monorepos may have several (e.g. `packages/*`) — pick the most active one,
     or note in the report that you scoped to one.
   - If none exist, fall back to the repo root and **say so** in the report
     (results may be noisier).
3. All *other* steps (contributors, bug clusters, momentum, firefighting) run
   from the **repo root** — they're about the whole project.

## Step 1 — High-churn files (run from the source dir)

The 20 most-modified files in the last year. High churn = code that keeps
getting reworked — often the stuff "everyone's afraid to touch," and a stronger
defect predictor than complexity alone.

```bash
git -C <REPO>/<SRCDIR> log --format=format: --name-only --since="1 year ago" -- . \
  | grep -v '^$' | sort | uniq -c | sort -nr | head -20
```

## Step 2 — Contributor distribution (bus factor)

Who actually wrote this, and is the knowledge concentrated in one person?

```bash
# All-time
git -C <REPO> shortlog -sn --no-merges HEAD
# Last 6 months — are the original builders still here?
git -C <REPO> shortlog -sn --no-merges --since="6 months ago" HEAD
```

> **Gotcha:** always pass `HEAD`. Without it, `git shortlog` reads from stdin
> when stdin isn't a TTY (i.e. when an agent runs it non-interactively) and
> silently returns nothing.

Compute the top contributor's share of total commits to state the bus factor
plainly (e.g. "1 author owns 100% of commits").

## Step 3 — Bug clusters

Files that show up most often in fix/bug commits. Cross-reference with Step 1:
files that are **both high-churn and bug-heavy** are the highest-risk code.

```bash
git -C <REPO> log -i -E --grep="fix|bug|broken" --name-only --format='' \
  | grep -v '^$' | sort | uniq -c | sort -nr | head -20
```

## Step 4 — Project momentum

Commits per month over the project's whole life. A steady rhythm is healthy; a
decline suggests lost momentum; a sudden drop often marks a team/personnel change.

```bash
git -C <REPO> log --format='%ad' --date=format:'%Y-%m' | sort | uniq -c
```

## Step 5 — Firefighting patterns

Reverts, hotfixes, rollbacks in the last year. Frequent ones point to an
unreliable deploy process and missing safeguards.

```bash
git -C <REPO> log --oneline --since="1 year ago" | grep -iE 'revert|hotfix|emergency|rollback'
```

Report the count; if non-zero, list the offending commit subjects.

## Step 6 — Write the report

Produce a markdown report with this structure. Fill the **Read this**
interpretation lines yourself from the numbers — that's the value, not the raw
tables. Keep tables compact (top ~10 rows is usually enough; note that you
truncated). Cross-reference churn × bugs to call out the genuine hotspots.

```markdown
# Git Code Audit — <repo name>

*<commit count> commits · <contributor count> contributor(s) · <first month>–<last month> · audited <date>*

## TL;DR
- <3–5 bullets: the headline findings — hotspots, bus factor, momentum, risk>

## 🔥 Hotspots (high churn × bugs)
| File | Changes (1y) | Bug commits |
|------|-------------:|------------:|
| ... | ... | ... |

**Read this:** <which files are both high-churn and bug-prone, and what that implies>

## 👥 Contributors & bus factor
| Author | Commits | Share |
|--------|--------:|------:|
| ... | ... | ... |

**Read this:** <bus factor; whether recent activity matches all-time; risk if key people left>

## 📈 Momentum
<small inline sparkline-ish list or table of YYYY-MM → count, or a one-line trend summary>

**Read this:** <healthy / declining / spiky; any obvious gaps or drops>

## 🚒 Firefighting
<count of reverts/hotfixes; list subjects if any, or "None — clean.">

**Read this:** <what this says about deploy reliability>

## Where to look first
1. <file> — <why>
2. ...
```

## Notes
- Adjust `--since` windows if the repo is very young (<1 year) or very old; for a
  young repo, drop the `--since` on churn/firefighting and say so.
- Don't paste raw 20-row dumps into the chat as the deliverable — the report is
  the deliverable. It's fine to run the commands quietly and only show the report.
- Offer to save the report to a file (e.g. `GIT-AUDIT.md`) if the user wants it.
