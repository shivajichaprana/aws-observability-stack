#!/usr/bin/env python3
"""
validate-dashboards.py
======================

Loose schema + uniqueness validation for Grafana dashboard JSON files under
the dashboards/ directory. Designed to be cheap enough to run in `make ci`
without spinning up a Grafana instance.

Checks performed:

1. The file is valid JSON.
2. The document is an object with `title`, `uid`, and `panels` keys.
3. `title` is at least 3 characters.
4. `uid` is between 4 and 40 characters (Grafana's documented constraint).
5. `panels` is a list.
6. No two dashboards share the same `uid`.

Exits non-zero on the first failure summary.
"""

from __future__ import annotations

import json
import pathlib
import sys

DASHBOARDS_DIR = pathlib.Path(__file__).resolve().parent.parent / "dashboards"


def _emit(message: str) -> None:
    """Print a GitHub-Actions-friendly error annotation to stdout."""
    print(f"::error::{message}")


def validate_dashboard(path: pathlib.Path) -> list[str]:
    """Return a list of error messages for a single dashboard file."""
    errors: list[str] = []
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return [f"{path}: invalid JSON: {exc}"]

    if not isinstance(doc, dict):
        return [f"{path}: top-level must be an object"]

    title = doc.get("title")
    if not isinstance(title, str) or len(title) < 3:
        errors.append(f"{path}: title must be a string of length ≥ 3")

    uid = doc.get("uid")
    if not isinstance(uid, str) or not (4 <= len(uid) <= 40):
        errors.append(f"{path}: uid must be a string of length 4..40")

    if not isinstance(doc.get("panels"), list):
        errors.append(f"{path}: panels must be a list")

    return errors


def main() -> int:
    """Iterate dashboards, accumulate errors, exit 0 on success."""
    if not DASHBOARDS_DIR.is_dir():
        _emit(f"dashboards directory not found at {DASHBOARDS_DIR}")
        return 1

    seen_uids: dict[str, pathlib.Path] = {}
    all_errors: list[str] = []
    count = 0

    for path in sorted(DASHBOARDS_DIR.glob("*.json")):
        count += 1
        for err in validate_dashboard(path):
            all_errors.append(err)

        try:
            uid = json.loads(path.read_text()).get("uid")
        except json.JSONDecodeError:
            continue

        if isinstance(uid, str):
            if uid in seen_uids:
                all_errors.append(
                    f"{path}: duplicate uid '{uid}' (also used by {seen_uids[uid]})",
                )
            else:
                seen_uids[uid] = path

    for err in all_errors:
        _emit(err)

    print(f"validated {count} dashboards, {len(all_errors)} errors")
    return 0 if not all_errors else 1


if __name__ == "__main__":
    sys.exit(main())
