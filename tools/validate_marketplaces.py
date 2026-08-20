#!/usr/bin/env python3
"""Validate this repo's skills and engine wrappers.

The question this answers, per engine:

    "Can <engine> discover, parse, install, and load each skill?"

We split the four verbs into engine-neutral vs engine-specific:

  * parse   (neutral) - SKILL.md frontmatter is valid YAML and obeys the
                        Agent Skills open standard (agentskills.io).
  * load    (neutral) - name == directory, referenced scripts exist, and no
                        machine/engine-specific absolute paths leaked into the body.
  * discover (per-engine) - the engine's marketplace catalog lists every plugin
                            directory and each source resolves.
  * install  (per-engine) - the engine's per-plugin manifest is present and valid.

Neutral results are shared by every engine. Engine-specific results come from the
engine's wrapper files; when a wrapper is absent (e.g. Codex, deferred) that engine's
discover/install are reported SKIP, not FAIL.

Run:  uv run tools/validate_marketplaces.py
Exit code 0 == every active check passed.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGINS_DIR = REPO_ROOT / "plugins"

# Agent Skills standard constraints (agentskills.io/specification)
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")  # kebab, no leading/trailing/consecutive hyphens
NAME_MAX = 64
DESC_MAX = 1024
COMPAT_MAX = 500

# Portability leaks: hardcoded machine/engine paths that must never appear in a neutral SKILL.md body.
LEAK_RE = re.compile(r"[A-Za-z]:\\Users\\|/home/[^\s`]+|~/\.(claude|codex|agents)\b|\.claude[\\/]skills")
# Script references we can verify exist on disk.
SCRIPT_REF_RE = re.compile(r"<skill-dir>[\\/]scripts[\\/]([\w.\-]+)")


def parse_frontmatter(text: str):
    """Return (metadata_dict, error_or_None). Mirrors how a compliant client reads SKILL.md."""
    if not text.startswith("---"):
        return None, "no YAML frontmatter (file must start with '---')"
    parts = text.split("\n", 1)
    rest = parts[1] if len(parts) > 1 else ""
    end = rest.find("\n---")
    if end == -1:
        return None, "frontmatter opening '---' has no closing '---'"
    block = rest[:end]
    try:
        meta = yaml.safe_load(block)
    except yaml.YAMLError as exc:
        return None, f"frontmatter is not valid YAML: {exc}"
    if not isinstance(meta, dict):
        return None, "frontmatter did not parse to a mapping"
    return meta, None


def check_skill(skill_dir: Path) -> list[str]:
    """Engine-neutral parse + load checks for one skill directory."""
    errs: list[str] = []
    md = skill_dir / "SKILL.md"
    try:
        rel = md.relative_to(REPO_ROOT)
    except ValueError:
        rel = md  # skill outside the repo (e.g. tests) — report the absolute path
    text = md.read_text(encoding="utf-8")

    # --- parse ---
    meta, perr = parse_frontmatter(text)
    if perr:
        return [f"{rel}: {perr}"]

    name = meta.get("name")
    if not name:
        errs.append(f"{rel}: missing required field 'name'")
    else:
        if not isinstance(name, str) or not NAME_RE.match(name):
            errs.append(f"{rel}: 'name' must be kebab-case (a-z0-9, single hyphens): {name!r}")
        if isinstance(name, str) and len(name) > NAME_MAX:
            errs.append(f"{rel}: 'name' exceeds {NAME_MAX} chars")
        # --- load: name must match directory ---
        if name != skill_dir.name:
            errs.append(f"{rel}: 'name' ({name!r}) must equal its directory ({skill_dir.name!r})")

    desc = meta.get("description")
    if not desc:
        errs.append(f"{rel}: missing required field 'description'")
    elif not isinstance(desc, str):
        errs.append(f"{rel}: 'description' must be a string")
    else:
        if len(desc) > DESC_MAX:
            errs.append(f"{rel}: 'description' exceeds {DESC_MAX} chars ({len(desc)})")
        if ": " in desc:
            errs.append(f"{rel}: 'description' contains an unquoted ': ' — breaks strict YAML parsers; reword or quote")

    compat = meta.get("compatibility")
    if compat is not None:
        if not isinstance(compat, str):
            errs.append(f"{rel}: 'compatibility' must be a string")
        elif len(compat) > COMPAT_MAX:
            errs.append(f"{rel}: 'compatibility' exceeds {COMPAT_MAX} chars")

    lic = meta.get("license")
    if lic is not None and not isinstance(lic, str):
        errs.append(f"{rel}: 'license' must be a string")

    metadata = meta.get("metadata")
    if metadata is not None:
        if not isinstance(metadata, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in metadata.items()
        ):
            errs.append(f"{rel}: 'metadata' must be a map of string->string")

    # --- load: no leaked machine/engine paths in the body ---
    body = text.split("\n---", 1)[-1]
    for m in LEAK_RE.finditer(body):
        errs.append(f"{rel}: hardcoded machine/engine path in body: {m.group(0)!r} (use <skill-dir> relative refs)")

    # --- load: referenced bundled scripts must exist ---
    for m in SCRIPT_REF_RE.finditer(text):
        script = m.group(1)
        if not (skill_dir / "scripts" / script).is_file():
            errs.append(f"{rel}: references scripts/{script} which does not exist")

    return errs


def discover_skills() -> list[Path]:
    return sorted(p.parent for p in PLUGINS_DIR.glob("*/skills/*/SKILL.md"))


def validate_claude_wrapper(root: Path = REPO_ROOT) -> tuple[list[str], list[str]]:
    """Return (discover_errors, install_errors) for the Claude wrapper."""
    discover: list[str] = []
    install: list[str] = []
    mkt = root / ".claude-plugin" / "marketplace.json"
    if not mkt.is_file():
        return ["missing .claude-plugin/marketplace.json"], ["(skipped - no marketplace)"]
    try:
        cat = json.loads(mkt.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f".claude-plugin/marketplace.json: invalid JSON: {exc}"], []
    if not isinstance(cat.get("name"), str):
        discover.append("marketplace.json: missing string 'name'")
    owner = cat.get("owner")
    if not isinstance(owner, dict) or not owner.get("name"):
        discover.append("marketplace.json: missing owner.name")
    plugins = cat.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        discover.append("marketplace.json: 'plugins' must be a non-empty list")
        return discover, install
    registered: set[str] = set()
    for entry in plugins:
        pname = entry.get("name")
        source = entry.get("source")
        if not pname or not source:
            discover.append(f"marketplace.json: plugin entry needs 'name' and 'source': {entry}")
            continue
        registered.add(pname)
        pdir = (root / source).resolve()
        if not pdir.is_dir():
            discover.append(f"marketplace.json: source for {pname!r} does not resolve: {source}")
            continue
        pj = pdir / ".claude-plugin" / "plugin.json"
        if not pj.is_file():
            install.append(f"{pname}: missing .claude-plugin/plugin.json")
            continue
        try:
            man = json.loads(pj.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            install.append(f"{pname}: plugin.json invalid JSON: {exc}")
            continue
        if man.get("name") != pname:
            install.append(f"{pname}: plugin.json 'name' ({man.get('name')!r}) != marketplace entry {pname!r}")
        if not man.get("description"):
            install.append(f"{pname}: plugin.json missing 'description'")

    # A plugin directory that no catalog entry points at is undiscoverable and
    # uninstallable, so treat the omission as a discover failure.
    for pdir in sorted((root / "plugins").glob("*/.claude-plugin/plugin.json")):
        domain = pdir.parent.parent.name
        if domain not in registered:
            discover.append(
                f"marketplace.json: plugin directory plugins/{domain} is not listed in the catalog"
            )
    return discover, install


def codex_wrapper_present() -> bool:
    if (REPO_ROOT / ".agents" / "plugins" / "marketplace.json").is_file():
        return True
    return any(PLUGINS_DIR.glob("*/.codex-plugin/plugin.json"))


def validate_repo(root: Path = REPO_ROOT):
    """Return (ok, report_lines)."""
    lines: list[str] = []

    skills = discover_skills()
    neutral_errs: list[str] = []
    for s in skills:
        neutral_errs.extend(check_skill(s))
    parse_load_ok = not neutral_errs

    c_disc_errs, c_inst_errs = validate_claude_wrapper(root)
    codex_present = codex_wrapper_present()

    def status(ok: bool) -> str:
        return "PASS" if ok else "FAIL"

    lines.append(f"Skills discovered: {len(skills)}")
    for s in skills:
        lines.append(f"  - {s.relative_to(root)}")
    lines.append("")
    lines.append("Engine   Discover  Parse  Install  Load")
    lines.append(f"Claude   {status(not c_disc_errs):8} {status(parse_load_ok):5}  "
                 f"{status(not c_inst_errs):7}  {status(parse_load_ok)}")
    if codex_present:
        lines.append(f"Codex    (validate) {status(parse_load_ok):5}  (validate)  {status(parse_load_ok)}")
    else:
        lines.append(f"Codex    SKIP      {status(parse_load_ok):5}  SKIP     {status(parse_load_ok)}"
                     "   (wrappers not yet added)")
    lines.append("")
    lines.append("Note: Parse/Load are engine-neutral (shared SKILL.md + scripts), so they apply to")
    lines.append("every engine. Codex Discover/Install are SKIP until .codex-plugin/plugin.json and")
    lines.append(".agents/plugins/marketplace.json exist; the neutral checks already confirm Codex")
    lines.append("will be able to parse and load these skills once its wrapper is added.")

    all_errs = neutral_errs + c_disc_errs + c_inst_errs
    if all_errs:
        lines.append("")
        lines.append("FAILURES:")
        lines.extend(f"  x {e}" for e in all_errs)

    return (not all_errs), lines


def main() -> int:
    ok, lines = validate_repo()
    print("\n".join(lines))
    print()
    print("OK" if ok else "VALIDATION FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
