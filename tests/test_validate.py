"""Tests for the marketplace/skill validator.

One smoke test (the repo itself must validate) plus one negative case (a bad
skill must be rejected), so the validator can't silently rot into a no-op.
"""
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
