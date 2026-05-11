#!/usr/bin/env python3
"""
inject-runbook-links.py
=======================

Post-process Prometheus / AMP alert YAMLs (and Grafana dashboard JSONs) to
make sure every alert carries a `runbook_url` annotation that points to the
canonical runbook for that alert.

Why this script exists
----------------------

The Terraform source-of-truth for "alert name -> runbook URL" is the map
declared in `terraform/composite-alarms.tf` (output `runbook_url_map`). The
Prometheus alerts in `alerts/*.yaml` are written by humans and tend to
drift - someone copy-pastes a rule, renames the alert, and forgets to update
the runbook annotation, so the on-call ends up on a 404.

This script enforces the map in two modes:

  * ``--check``  - exit non-zero if any alert is missing or has a wrong
                   runbook URL (used in CI on Day 48).
  * ``--apply``  - rewrite the YAML files in place so every matching alert
                   has the right URL.

For Grafana dashboard JSON files, the script walks every panel and rewrites
the `description` field (and any `runbook` field in panel.links) for panels
whose `title` matches a known alert name.

The script does NOT add new alerts - if an alert exists in YAML but not in
the runbook map, it is reported (in check mode) but left alone, with a hint
that either the alert name should be aligned or a new runbook added.

Inputs
------

The runbook map is loaded in this priority order:

  1. ``--map-file`` (JSON, same shape as Terraform's runbook_url_map output)
  2. ``terraform -chdir=terraform output -json runbook_url_map`` (if
     terraform is on $PATH and the workspace is initialised)
  3. The hard-coded fallback at the top of this file, which mirrors the
     same map verbatim. CI uses the JSON file; humans running locally just
     run the script and it does the right thing.

Usage
-----

    # Dry-run, see what would change:
    scripts/inject-runbook-links.py --check

    # Rewrite in place:
    scripts/inject-runbook-links.py --apply

    # Restrict to specific files:
    scripts/inject-runbook-links.py --apply alerts/slo-availability.yaml

Exit codes
----------

  0   no drift, or apply succeeded with no errors
  1   drift detected (check mode), or apply hit an error
  2   bad invocation / missing inputs
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

# ---------------------------------------------------------------------------
# Fallback runbook map. Kept in sync with terraform/composite-alarms.tf.
# CI runs `terraform output -json runbook_url_map` first so this is only used
# when the script is run on a developer laptop without terraform initialised.
# ---------------------------------------------------------------------------

DEFAULT_RUNBOOK_BASE = (
    "https://github.com/shivajichaprana/aws-observability-stack/blob/main/docs/runbooks"
)

FALLBACK_RUNBOOK_MAP: dict[str, str] = {
    "HighErrorRate": f"{DEFAULT_RUNBOOK_BASE}/high-error-rate.md",
    "HighLatency": f"{DEFAULT_RUNBOOK_BASE}/high-latency.md",
    "NodePressure": f"{DEFAULT_RUNBOOK_BASE}/node-pressure.md",
}

# ---------------------------------------------------------------------------
# Alert-name aliases. Prometheus alerts often use SLO-specific names that
# don't match the friendly composite alarm name - this table maps them to
# the same runbook so the on-call lands on the same page either way.
# ---------------------------------------------------------------------------

ALERT_ALIASES: dict[str, str] = {
    # SLO availability alerts -> HighErrorRate runbook
    "SLOAvailabilityFastBurn": "HighErrorRate",
    "SLOAvailabilityMediumBurn": "HighErrorRate",
    "SLOAvailabilitySlowBurn": "HighErrorRate",
    "SLOAvailabilityTrend": "HighErrorRate",
    # SLO latency alerts -> HighLatency runbook
    "SLOLatencyFastBurn": "HighLatency",
    "SLOLatencyMediumBurn": "HighLatency",
    "SLOLatencySlowBurn": "HighLatency",
    # Node-pressure aliases
    "KubeNodeMemoryPressure": "NodePressure",
    "KubeNodeDiskPressure": "NodePressure",
    "KubeNodeNotReady": "NodePressure",
}

LOG_FORMAT = "%(asctime)s %(levelname)-7s %(message)s"
LOG_DATEFMT = "%Y-%m-%dT%H:%M:%S"

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Issue:
    """A single drift finding in a file."""

    file: Path
    alert: str
    expected: str | None
    actual: str | None
    reason: str

    def render(self) -> str:
        return (
            f"  - {self.file}:{self.alert}: {self.reason}\n"
            f"      expected: {self.expected}\n"
            f"      actual:   {self.actual}"
        )


# ---------------------------------------------------------------------------
# Loading the runbook map
# ---------------------------------------------------------------------------


def load_map_from_file(path: Path) -> dict[str, str]:
    log = logging.getLogger(__name__)
    log.debug("Loading runbook map from %s", path)
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)

    # Terraform's `output -json runbook_url_map` shape is
    # {"sensitive": false, "type": "...", "value": {...}}
    if isinstance(data, dict) and "value" in data and isinstance(data["value"], dict):
        return {str(k): str(v) for k, v in data["value"].items()}

    if isinstance(data, dict):
        return {str(k): str(v) for k, v in data.items()}

    raise ValueError(f"{path} does not contain a JSON object")


def load_map_from_terraform(terraform_dir: Path) -> dict[str, str] | None:
    """Try to read the runbook map directly from `terraform output`.

    Returns None if terraform is unavailable or the output is missing - the
    caller is expected to fall back to the bundled default.
    """
    log = logging.getLogger(__name__)
    tf = shutil.which("terraform")
    if tf is None:
        log.debug("terraform binary not on PATH; skipping terraform output")
        return None
    if not (terraform_dir / ".terraform").is_dir():
        log.debug("%s is not a terraform-initialised dir; skipping", terraform_dir)
        return None
    try:
        proc = subprocess.run(
            [tf, "-chdir", str(terraform_dir), "output", "-json", "runbook_url_map"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        log.debug("terraform output failed: %s", exc)
        return None

    try:
        return {str(k): str(v) for k, v in json.loads(proc.stdout).items()}
    except json.JSONDecodeError as exc:
        log.warning("terraform output returned malformed JSON: %s", exc)
        return None


def resolve_runbook_map(
    map_file: Path | None, terraform_dir: Path
) -> dict[str, str]:
    log = logging.getLogger(__name__)
    if map_file is not None:
        return load_map_from_file(map_file)
    tf_map = load_map_from_terraform(terraform_dir)
    if tf_map is not None:
        log.info("Loaded runbook map from `terraform output` (%d entries)", len(tf_map))
        return tf_map
    log.info("Using bundled fallback runbook map (%d entries)", len(FALLBACK_RUNBOOK_MAP))
    return dict(FALLBACK_RUNBOOK_MAP)


# ---------------------------------------------------------------------------
# YAML helpers
#
# We avoid pulling in PyYAML at runtime - this script needs to work on
# vanilla CI containers and a regex pass is more than sufficient for the
# narrow surface we care about (single annotation rewrite).
# ---------------------------------------------------------------------------


# Match a Prometheus alert block opener: `      - alert: AlertName`
ALERT_OPENER_RE = re.compile(r"^(?P<indent>\s*)- alert:\s+(?P<name>\S+)\s*$")
# Match a `runbook_url: ...` annotation line (single- or double-quoted).
RUNBOOK_LINE_RE = re.compile(
    r"^(?P<indent>\s*)runbook_url:\s+(?P<quote>[\"']?)(?P<url>[^\"'\n]+)(?P=quote)\s*$"
)
# Match the start of the annotations: block (so we can insert under it).
ANNOTATIONS_RE = re.compile(r"^(?P<indent>\s*)annotations:\s*$")


def alert_to_runbook(alert_name: str, runbook_map: dict[str, str]) -> str | None:
    """Return the canonical runbook URL for an alert name.

    Falls back to alias lookup (e.g. SLOAvailabilityFastBurn -> HighErrorRate).
    """
    if alert_name in runbook_map:
        return runbook_map[alert_name]
    alias = ALERT_ALIASES.get(alert_name)
    if alias and alias in runbook_map:
        return runbook_map[alias]
    return None


def process_yaml(
    path: Path, runbook_map: dict[str, str], apply: bool
) -> tuple[list[Issue], bool]:
    """Walk a YAML alert file, find drift, optionally rewrite in place.

    Returns (issues, changed).
    """
    log = logging.getLogger(__name__)
    issues: list[Issue] = []
    changed = False

    lines = path.read_text(encoding="utf-8").splitlines(keepends=False)
    out: list[str] = []

    i = 0
    current_alert: str | None = None
    current_alert_indent = ""
    while i < len(lines):
        line = lines[i]
        opener = ALERT_OPENER_RE.match(line)
        if opener:
            current_alert = opener.group("name")
            current_alert_indent = opener.group("indent")
            out.append(line)
            i += 1
            continue

        if current_alert is not None:
            rb = RUNBOOK_LINE_RE.match(line)
            if rb:
                expected = alert_to_runbook(current_alert, runbook_map)
                if expected is None:
                    issues.append(
                        Issue(
                            file=path,
                            alert=current_alert,
                            expected=None,
                            actual=rb.group("url"),
                            reason="alert is not in the runbook map (consider aliasing or adding a runbook)",
                        )
                    )
                    out.append(line)
                elif rb.group("url") != expected:
                    issues.append(
                        Issue(
                            file=path,
                            alert=current_alert,
                            expected=expected,
                            actual=rb.group("url"),
                            reason="runbook_url is stale",
                        )
                    )
                    if apply:
                        out.append(f'{rb.group("indent")}runbook_url: "{expected}"')
                        changed = True
                        log.info(
                            "[%s] %s: rewrote runbook_url -> %s",
                            path.name,
                            current_alert,
                            expected,
                        )
                    else:
                        out.append(line)
                else:
                    out.append(line)
                i += 1
                continue

            # If we hit the next alert opener with no runbook_url seen, add one.
            next_opener = ALERT_OPENER_RE.match(line)
            if next_opener:
                expected = alert_to_runbook(current_alert, runbook_map)
                if expected is not None:
                    issues.append(
                        Issue(
                            file=path,
                            alert=current_alert,
                            expected=expected,
                            actual=None,
                            reason="alert has no runbook_url annotation",
                        )
                    )
                    if apply:
                        insertion_indent = current_alert_indent + "    "
                        out.append(f"{insertion_indent}# runbook_url injected by inject-runbook-links.py")
                        out.append(f'{insertion_indent}runbook_url: "{expected}"')
                        changed = True
                current_alert = next_opener.group("name")
                current_alert_indent = next_opener.group("indent")

        out.append(line)
        i += 1

    # Handle the very last alert in the file (no closer to trigger detection).
    if current_alert is not None:
        # If any matching `runbook_url:` line was present anywhere, it'd already
        # have been handled. If not, we get here only when the final block is
        # missing the annotation entirely.
        final_block = "\n".join(out[-20:])
        if "runbook_url:" not in final_block:
            expected = alert_to_runbook(current_alert, runbook_map)
            if expected is not None and not any(
                iss.alert == current_alert and iss.file == path for iss in issues
            ):
                issues.append(
                    Issue(
                        file=path,
                        alert=current_alert,
                        expected=expected,
                        actual=None,
                        reason="alert has no runbook_url annotation",
                    )
                )
                if apply:
                    out.append(f'        runbook_url: "{expected}"')
                    changed = True

    if apply and changed:
        path.write_text("\n".join(out) + "\n", encoding="utf-8")

    return issues, changed


# ---------------------------------------------------------------------------
# Grafana dashboard helpers
# ---------------------------------------------------------------------------


def walk_grafana_panels(panels: list[dict[str, Any]]) -> Iterable[dict[str, Any]]:
    """Yield panel dicts, recursing through row sub-panels."""
    for panel in panels:
        yield panel
        sub = panel.get("panels")
        if isinstance(sub, list):
            yield from walk_grafana_panels(sub)


def process_grafana_dashboard(
    path: Path, runbook_map: dict[str, str], apply: bool
) -> tuple[list[Issue], bool]:
    """Inject runbook links into Grafana dashboard panels.

    For each panel whose `title` matches a known alert name (or alias), set:

      * panel.description           - human-readable note with runbook link
      * panel.links[]               - Grafana panel link with title 'Runbook'

    Grafana renders panel links as a small dropdown in the panel header so
    on-call can jump from any chart directly to the runbook.
    """
    log = logging.getLogger(__name__)
    issues: list[Issue] = []
    raw = path.read_text(encoding="utf-8")
    try:
        dashboard = json.loads(raw)
    except json.JSONDecodeError as exc:
        log.error("Failed to parse %s: %s", path, exc)
        return [
            Issue(
                file=path,
                alert="<file>",
                expected=None,
                actual=None,
                reason=f"invalid JSON: {exc}",
            )
        ], False

    panels = dashboard.get("panels", [])
    changed = False

    for panel in walk_grafana_panels(panels):
        title = str(panel.get("title", "")).strip()
        if not title:
            continue
        rb_url = alert_to_runbook(title, runbook_map)
        if rb_url is None:
            # Try a forgiving match: replace whitespace, look up as a key.
            squashed = re.sub(r"[\s_-]+", "", title)
            rb_url = alert_to_runbook(squashed, runbook_map)
        if rb_url is None:
            continue

        # ---- Description (used by the panel hover-card) ----
        desired_marker = f"<!-- runbook: {rb_url} -->"
        cur_desc = str(panel.get("description", ""))
        if desired_marker not in cur_desc:
            new_desc = cur_desc.rstrip()
            if new_desc:
                new_desc += "\n\n"
            new_desc += desired_marker
            issues.append(
                Issue(
                    file=path,
                    alert=title,
                    expected=desired_marker,
                    actual=cur_desc or None,
                    reason="panel description missing runbook marker",
                )
            )
            if apply:
                panel["description"] = new_desc
                changed = True

        # ---- Panel link ----
        links = panel.get("links", [])
        if not isinstance(links, list):
            links = []
        has_runbook_link = any(
            isinstance(l, dict) and l.get("url") == rb_url for l in links
        )
        if not has_runbook_link:
            issues.append(
                Issue(
                    file=path,
                    alert=title,
                    expected=rb_url,
                    actual=None,
                    reason="panel has no link to runbook",
                )
            )
            if apply:
                links.append(
                    {
                        "title": "Runbook",
                        "type": "link",
                        "url": rb_url,
                        "targetBlank": True,
                    }
                )
                panel["links"] = links
                changed = True

    if apply and changed:
        path.write_text(
            json.dumps(dashboard, indent=2) + "\n",
            encoding="utf-8",
        )
        log.info("[%s] dashboard rewritten with runbook annotations", path.name)

    return issues, changed


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def default_targets(repo_root: Path) -> list[Path]:
    """Return every alert YAML and Grafana dashboard JSON under the repo."""
    targets: list[Path] = []
    for pattern in ("alerts/*.yaml", "alerts/*.yml"):
        targets.extend(sorted(repo_root.glob(pattern)))
    targets.extend(sorted(repo_root.glob("dashboards/*.json")))
    return targets


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject canonical runbook URLs into Prometheus alert YAMLs and Grafana dashboards.",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Report drift without rewriting files.")
    mode.add_argument("--apply", action="store_true", help="Rewrite files in place.")
    parser.add_argument(
        "--map-file",
        type=Path,
        default=None,
        help="Path to a JSON file containing the alert -> runbook URL map. Overrides terraform output.",
    )
    parser.add_argument(
        "--terraform-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "terraform",
        help="Path to the Terraform root used to look up runbook_url_map (default: ../terraform).",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )
    parser.add_argument(
        "files",
        nargs="*",
        type=Path,
        help="Specific files to process. Defaults to alerts/*.yaml and dashboards/*.json.",
    )

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format=LOG_FORMAT,
        datefmt=LOG_DATEFMT,
    )
    log = logging.getLogger(__name__)

    repo_root = Path(__file__).resolve().parent.parent

    try:
        runbook_map = resolve_runbook_map(args.map_file, args.terraform_dir)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        log.error("Could not load runbook map: %s", exc)
        return 2

    if not runbook_map:
        log.error("Runbook map is empty - nothing to inject.")
        return 2

    log.info("Runbook map (%d entries):", len(runbook_map))
    for k, v in sorted(runbook_map.items()):
        log.info("  %s -> %s", k, v)

    targets = args.files or default_targets(repo_root)
    if not targets:
        log.warning("No alert or dashboard files found under %s", repo_root)
        return 0

    all_issues: list[Issue] = []
    files_changed = 0

    for target in targets:
        if not target.is_file():
            log.warning("Skipping non-file %s", target)
            continue
        if target.suffix in {".yaml", ".yml"}:
            issues, changed = process_yaml(target, runbook_map, apply=args.apply)
        elif target.suffix == ".json":
            issues, changed = process_grafana_dashboard(target, runbook_map, apply=args.apply)
        else:
            log.debug("Skipping unsupported file type: %s", target)
            continue
        all_issues.extend(issues)
        if changed:
            files_changed += 1

    if all_issues:
        log.warning("Found %d drift issue(s):", len(all_issues))
        for issue in all_issues:
            sys.stderr.write(issue.render() + "\n")

    if args.check and all_issues:
        log.error("Runbook annotation drift detected. Re-run with --apply or fix manually.")
        return 1

    if args.apply:
        log.info("Rewrote %d file(s).", files_changed)
        return 0

    log.info("No drift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
