# skills

Engine-neutral **[Agent Skills](https://agentskills.io)** with thin per-engine wrappers.

The **core** is a set of standard skills (a `SKILL.md` + resources per skill) that any
skills-compatible agent can read — the reusable part. On top sit **thin wrapper manifests** so
the *same* skills are installable from a specific engine's marketplace. **Claude Code is wired up
today; OpenAI Codex is a planned wrapper** over the identical skills — no skill content is
duplicated per engine.

## Layout

```
.claude-plugin/marketplace.json                 # Claude marketplace (engine wrapper)
plugins/
  windows-maintenance/                          # a DOMAIN plugin (groups related skills)
    .claude-plugin/plugin.json                  # Claude plugin manifest
    skills/                                      # engine-neutral core skills (single source of truth)
      compress-wsl/           SKILL.md + scripts/
      clean-disk-space/       SKILL.md + scripts/
      reduce-memory-footprint/ SKILL.md + scripts/
      reduce-store-uwp-bloatware-footprint/ SKILL.md
tools/validate_marketplaces.py                  # "can each engine discover/parse/install/load?"
tests/  pyproject.toml  .github/workflows/validate.yml
```

Each skill's `SKILL.md` carries only the standard frontmatter fields (`name`, `description`,
`license`, `compatibility`) plus two Claude behavior flags (`disable-model-invocation`,
`user-invocable`) that other engines safely ignore. Scripts are referenced relative to the skill
directory (`<skill-dir>\scripts\…`), never by an absolute machine path.

### Deferred (Codex wrappers — documented, not yet created)
- `.agents/plugins/marketplace.json` — the **Codex** marketplace catalog.
- `plugins/<domain>/.codex-plugin/plugin.json` — the Codex per-plugin manifest.

Both would point at the **same** `skills/` directories. (`.agents/plugins/marketplace.json` is a
Codex path, not a neutral one — the Agent Skills standard defines skills + `.agents/skills/`
discovery, not marketplaces.)

## Skills (domain: `windows-maintenance`)

| Skill | Platform | What it does |
|-------|----------|--------------|
| `compress-wsl` | Windows (manages WSL2) | Compact the WSL2 `ext4.vhdx` in place with `diskpart` after `fstrim`; honest before/after reporting. |
| `clean-disk-space` | Windows | Find large/stale/junk files and prune with per-category confirmation. |
| `reduce-memory-footprint` | Windows | Trim services, startup apps, and processes interactively. |
| `reduce-store-uwp-bloatware-footprint` | Windows | Remove pre-installed Store/UWP bloatware, with a keep-list. |

Platform is a convention (no engine enforces OS gating) surfaced via the `compatibility` field and
marketplace `tags`. Install only what fits the environment you're in.

## Install (Claude Code)

```
/plugin marketplace add MikaelUmaN/skills
/plugin install windows-maintenance@rainysoft-skills
```

That one plugin provides all four skills, namespaced as `/windows-maintenance:compress-wsl`,
`/windows-maintenance:clean-disk-space`, etc.

## Running across Windows and WSL

Native-Windows Claude Code and Claude Code inside WSL are **separate installs** (different
`~/.claude`, independent plugins/trust). So:

- **Add the marketplace in each environment separately, via the GitHub remote** — not a local
  path (adding a local path from WSL trips a known updater bug that drops a stray directory).
- **Install per environment.** These four skills are Windows-invoked; install them in Windows CC.
- Update with `/plugin marketplace update rainysoft-skills` (run per environment); a running session
  keeps launch-time versions until `/reload-plugins` or restart.

## Adding a skill or domain

1. `plugins/<domain>/skills/<name>/SKILL.md` (+ `scripts/` if needed). Reference scripts as
   `<skill-dir>\scripts\<file>` — never a hardcoded absolute path.
2. Frontmatter: `name` (kebab-case, **must equal the directory name**, ≤64), `description` (≤1024,
   no unquoted `: `), and optionally `license`/`compatibility`. Engine-specific behavior flags are
   allowed but kept minimal.
3. Ensure a `plugins/<domain>/.claude-plugin/plugin.json` exists and the domain is listed in
   `.claude-plugin/marketplace.json`.
4. Run the validator (below) before committing.

## Validate

The validator answers, per engine: **"can it discover, parse, install, and load each skill?"**
`parse`/`load` are engine-neutral (the shared `SKILL.md` + scripts); `discover`/`install` come
from each engine's wrapper (Codex shows `SKIP` until its wrapper exists).

```
uv run tools/validate_marketplaces.py     # requires uv (astral.sh/uv); bootstraps Python + deps
uv run --group dev pytest -q              # tests
```

CI runs both on every push/PR (`.github/workflows/validate.yml`).

## License

Apache-2.0 (see `LICENSE`).
