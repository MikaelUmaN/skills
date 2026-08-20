"""Tests for the marketplace/skill validator.

One smoke test (the repo itself must validate) plus negative cases (a bad skill
and an unregistered plugin must be rejected), so the validator can't silently
rot into a no-op.
"""
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import validate_marketplaces as v  # noqa: E402


def test_repo_validates_clean():
    ok, lines = v.validate_repo()
    assert ok, "repo failed validation:\n" + "\n".join(lines)


def test_bad_skill_is_rejected(tmp_path):
    # name is not kebab-case AND does not match its directory
    skill = tmp_path / "Bad_Name"
    skill.mkdir()
    (skill / "SKILL.md").write_text(
        "---\nname: Bad_Name\ndescription: x\n---\n\nbody\n", encoding="utf-8"
    )
    errs = v.check_skill(skill)
    assert errs, "validator should have rejected a non-kebab name / dir mismatch"


def _write_wrapper(root: Path, registered: list[str], on_disk: list[str]) -> None:
    """Build a minimal Claude wrapper: a catalog listing `registered`, dirs for `on_disk`."""
    mkt = root / ".claude-plugin"
    mkt.mkdir(parents=True)
    (mkt / "marketplace.json").write_text(
        json.dumps({
            "name": "test-catalog",
            "owner": {"name": "Test"},
            "plugins": [{"name": n, "description": n, "source": f"./plugins/{n}"} for n in registered],
        }),
        encoding="utf-8",
    )
    for n in on_disk:
        pd = root / "plugins" / n / ".claude-plugin"
        pd.mkdir(parents=True)
        (pd / "plugin.json").write_text(
            json.dumps({"name": n, "description": n, "version": "1.0.0"}), encoding="utf-8"
        )


def test_registered_plugin_is_accepted(tmp_path):
    _write_wrapper(tmp_path, registered=["alpha"], on_disk=["alpha"])
    discover, install = v.validate_claude_wrapper(tmp_path)
    assert not discover and not install, f"clean wrapper rejected: {discover + install}"


def test_unregistered_plugin_is_rejected(tmp_path):
    # 'beta' exists on disk but no catalog entry points at it -> undiscoverable
    _write_wrapper(tmp_path, registered=["alpha"], on_disk=["alpha", "beta"])
    discover, _ = v.validate_claude_wrapper(tmp_path)
    assert any("plugins/beta" in e for e in discover), (
        "validator should have rejected a plugin directory missing from the catalog; "
        f"got {discover}"
    )
