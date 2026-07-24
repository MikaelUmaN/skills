# AGENTS.md

Guidance for AI coding agents (Claude Code, OpenAI Codex, and any other
skills-compatible engine) working in this repository. This is the **single source
of truth** for agent instructions — see [Agent instructions](#agent-instructions) below.

## What this repository is

This is a repository of **distributable Agent Skills**, authored to be
**vendor-neutral** and to follow the open **[Agent Skills](https://agentskills.io)**
specification. A skill is a `SKILL.md` (standard frontmatter + instructions) plus any
resources it needs (`scripts/`, etc.); any skills-compatible agent can read it.

On top of that shared core, we provide **vendor-specific support via thin wrapper
manifests**, so the *same* skills are installable from each engine's marketplace with
**no skill content duplicated per engine**:

- **Claude Code** — wired up today (`.claude-plugin/marketplace.json` +
  `plugins/<domain>/.claude-plugin/plugin.json`).
- **OpenAI Codex** — planned wrapper (`.agents/plugins/marketplace.json` +
  `plugins/<domain>/.codex-plugin/plugin.json`), pointing at the same `skills/`.
- Additional engines can be added the same way: a wrapper that discovers/installs,
  never a fork of the skill itself.

## Layout

```
.claude-plugin/marketplace.json        # Claude marketplace catalog (engine wrapper)
plugins/
  <domain>/                            # a DOMAIN plugin grouping related skills
    .claude-plugin/plugin.json         # Claude plugin manifest
    skills/                            # engine-neutral core skills (single source of truth)
      <skill-name>/  SKILL.md + scripts/
tools/validate_marketplaces.py         # per-engine discover/parse/install/load checks
tests/  pyproject.toml  .github/workflows/validate.yml
CLAUDE.md                              # pure pointer to this file — never a content source
AGENTS.md                              # this file — the source of truth for agents
```

### Deferred (Codex wrappers — documented, not yet created)

- `.agents/plugins/marketplace.json` — the Codex marketplace catalog.
- `plugins/<domain>/.codex-plugin/plugin.json` — the Codex per-plugin manifest.

Both point at the **same** `skills/` directories. Note `.agents/plugins/…` is a Codex
path, not a neutral one — the Agent Skills standard defines skills + `.agents/skills/`
discovery, not marketplaces.

## Current contents

Three domain plugins exist today:

- **`windows-maintenance`** — four Windows/WSL skills: `compress-wsl`,
  `clean-disk-space`, `reduce-memory-footprint`, `reduce-store-uwp-bloatware-footprint`.
- **`linux-maintenance`** — `clean-disk-space` (Linux/bash disk cleanup with
  per-category confirmation).
- **`dev-tools`** — `git-code-audit` (cross-platform git-history health report).

Each skill reports state first and asks before changing anything. "Platform" is a
convention surfaced via the `compatibility` field and marketplace `tags`; no engine
enforces OS gating. Note that a skill `name` is unique only within its domain — the
Linux and Windows `clean-disk-space` skills share a name and are disambiguated by
install namespace (`linux-maintenance:clean-disk-space` vs
`windows-maintenance:clean-disk-space`).

## Skill authoring conventions

- `SKILL.md` frontmatter carries only standard fields (`name`, `description`,
  `license`, `compatibility`) plus minimal engine-specific behavior flags
  (`disable-model-invocation`, `user-invocable`) that other engines safely ignore.
- `name` is kebab-case, **must equal the skill directory name**, ≤64 chars.
- `description` is ≤1024 chars with no unquoted `: ` sequence.
- Reference scripts **relative to the skill directory** (`<skill-dir>\scripts\<file>`),
  never by an absolute machine path.

## Adding a skill or domain

1. Create `plugins/<domain>/skills/<name>/SKILL.md` (+ `scripts/` if needed).
2. Fill frontmatter per the conventions above.
3. Ensure `plugins/<domain>/.claude-plugin/plugin.json` exists and the domain is
   listed in `.claude-plugin/marketplace.json`.
4. Run the validator (below) before committing.

## Validate

The validator answers, per engine: **"can it discover, parse, install, and load each
skill?"** `parse`/`load` are engine-neutral (shared `SKILL.md` + scripts);
`discover`/`install` come from each engine's wrapper (Codex shows `SKIP` until its
wrapper exists).

```
uv run tools/validate_marketplaces.py     # requires uv (astral.sh/uv); bootstraps Python + deps
uv run --group dev pytest -q              # tests
```

CI runs both on every push/PR (`.github/workflows/validate.yml`).

## Install (Claude Code)

```
/plugin marketplace add MikaelUmaN/skills
/plugin install windows-maintenance@rainysoft-skills
```

Native-Windows Claude Code and Claude Code inside WSL are separate installs — add the
marketplace and install per environment, via the GitHub remote (not a local path).

## Agent instructions

- **Treat this file (`AGENTS.md`) as the single source of truth** for how to work in
  this repository. All agents — regardless of engine — read from here.
- **Do not write agent guidance into `CLAUDE.md`.** It is a pure pointer to this file
  and must contain no information of its own. Put any new instructions here instead.
- Keep skills engine-neutral; add engine support through wrapper manifests, never by
  duplicating or forking skill content.
- Run the validator and tests before committing changes.

## License

Apache-2.0 (see `LICENSE`).
