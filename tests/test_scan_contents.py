# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Offline cases for scan_contents.py, run by tests/workflow-steps.sh.

Run as a module from the repository root, so the relative import below
resolves to this directory and nothing else on sys.path:

  python3 -m tests.test_scan_contents

The assertion decides whether a scan saw every submodule level, so a
regression in it would pass every leg it guards. These cases stub the
server with responses in the shapes Nexus IQ and SonarCloud actually
return, checked against both live in September 2026, and require each
outcome to name its cause.

Exits non-zero and names the failing case if any does not hold.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import scan_contents

APP = "lfreleng-actions-test-python-submodules"
KEY = "lfreleng-actions_test-python-submodules"

# Baselines, as the baseline mode would emit them before a scan.
IQ_OLD = "api/v2/applications/x/reports/old/raw|2026-09-23T12:00:00.000Z"
SONAR_OLD = "analysis-old|2026-09-23T12:00:00+0000"


@dataclass(frozen=True)
class Report:
    """One Nexus IQ report as the stub serves it."""

    scan: str
    evaluated: str
    packages: tuple[str, ...]
    stage: str = "build"


def iq_server(*reports: Report) -> scan_contents.Fetch:
    """A Nexus IQ holding one application and the given reports."""
    by_url = {f"api/v2/applications/x/reports/{r.scan}/raw": r for r in reports}

    def fetch(path: str) -> object:
        if path.startswith("api/v2/applications?"):
            return {"applications": [{"id": "internal-1", "publicId": APP}]}
        if path == "api/v2/reports/applications/internal-1":
            return [
                {"stage": r.stage, "evaluationDate": r.evaluated, "reportDataUrl": url}
                for url, r in by_url.items()
            ]
        if path in by_url:
            return {
                "components": [
                    {"packageUrl": f"pkg:pypi/{p}@1.0", "pathnames": [f"x/{p}"]}
                    for p in by_url[path].packages
                ]
            }
        raise AssertionError(f"unexpected request {path}")

    return fetch


def sonar_server(
    key: str, analysed: str, paths: list[str], branch: str = "main"
) -> scan_contents.Fetch:
    """A SonarCloud holding one project, one branch's newest analysis and files.

    Any request that does not name that branch is answered 404, as the
    real server does for an unknown branch. So a query that dropped its
    branch, and would read the default branch in production, fails here
    instead of passing on data it was never meant to see.
    """

    def fetch(path: str) -> object:
        if f"branch={branch}" not in path.split("?", 1)[-1].split("&"):
            raise scan_contents.NotFound(f"HTTP 404 for {path}: branch not named")
        if path.startswith("api/project_analyses/search?"):
            return {"analyses": [{"key": key, "date": analysed}]}
        if path.startswith("api/components/tree?"):
            # Only a recursive traversal reaches the markers below the
            # root; the real 'children' strategy would return none.
            if "strategy=all" not in path.split("?", 1)[-1].split("&"):
                return {
                    "paging": {"pageIndex": 1, "pageSize": 500, "total": 0},
                    "components": [],
                }
            return {
                "paging": {"pageIndex": 1, "pageSize": 500, "total": len(paths)},
                "components": [{"path": p, "qualifier": "FIL"} for p in paths],
            }
        raise AssertionError(f"unexpected request {path}")

    return fetch


def no_application(path: str) -> object:
    """A Nexus IQ that has never heard of the fixture's application."""
    _ = path
    return {"applications": []}


def missing_project(path: str) -> object:
    """A SonarCloud answering 404, as it does for an unknown key."""
    raise scan_contents.NotFound(
        f"HTTP 404 from https://sonarcloud.io/{path}: no such project"
    )


def npm_tomli(path: str) -> object:
    """A report naming 'tomli', but as an npm package rather than PyPI.

    Only a pypi purl is one of the fixture's pins, so this must not be
    counted as the nested level having been scanned.
    """
    if path.endswith("/raw"):
        return {"components": [{"packageUrl": "pkg:npm/tomli@1.0"}]}
    return iq_server(Report("new", "2026-09-23T12:05:00.000Z", ()))(path)


PARENT = ["parent_level.py", "requirements.txt"]
DIRECT = ["direct/direct_level.py", "direct/requirements.txt"]
NESTED = ["direct/nested/nested_level.py", "direct/nested/requirements.txt"]
ALL = ("six", "iniconfig", "tomli")
TWO = ("six", "iniconfig")
OLD_REPORT = Report("old", "2026-09-23T12:00:00.000Z", ALL)

Case = tuple[str, list[str], scan_contents.Fetch, int, str]

CASES: list[Case] = [
    # --- Nexus IQ, the recursive leg
    (
        "iq: recursive checkout finds all three levels",
        [
            "assert",
            "nexus-iq",
            "--subject",
            APP,
            "--after",
            IQ_OLD,
            "--present",
            "six,iniconfig,tomli",
        ],
        iq_server(OLD_REPORT, Report("new", "2026-09-23T12:05:00.000Z", ALL)),
        0,
        "Present as required: six, iniconfig, tomli",
    ),
    (
        "iq: a lane that stopped recursing fails, naming the nested pin",
        [
            "assert",
            "nexus-iq",
            "--subject",
            APP,
            "--after",
            IQ_OLD,
            "--present",
            "six,iniconfig,tomli",
        ],
        iq_server(OLD_REPORT, Report("new", "2026-09-23T12:05:00.000Z", TWO)),
        1,
        "package 'tomli' is missing",
    ),
    # --- Nexus IQ, the negative control: submodules 'true'
    (
        "iq: submodules 'true' has the direct level but not the nested",
        [
            "assert",
            "nexus-iq",
            "--subject",
            APP,
            "--after",
            IQ_OLD,
            "--present",
            "six,iniconfig",
            "--absent",
            "tomli",
        ],
        iq_server(OLD_REPORT, Report("new", "2026-09-23T12:05:00.000Z", TWO)),
        0,
        "Absent as required:  tomli",
    ),
    (
        "iq: a lane ignoring the input and always recursing fails",
        [
            "assert",
            "nexus-iq",
            "--subject",
            APP,
            "--after",
            IQ_OLD,
            "--present",
            "six,iniconfig",
            "--absent",
            "tomli",
        ],
        iq_server(OLD_REPORT, Report("new", "2026-09-23T12:05:00.000Z", ALL)),
        1,
        "package 'tomli' is present, but this checkout mode should not",
    ),
    # --- Nexus IQ, attributing the result to this scan
    (
        "iq: the report held before the scan is refused, however complete",
        ["assert", "nexus-iq", "--subject", APP, "--after", IQ_OLD, "--present", "six"],
        iq_server(OLD_REPORT),
        1,
        "still the one the server held before this scan",
    ),
    (
        "iq: a new report in the same second as the baseline is refused",
        ["assert", "nexus-iq", "--subject", APP, "--after", IQ_OLD, "--present", "six"],
        iq_server(Report("new", "2026-09-23T12:00:00.000Z", ALL)),
        1,
        "is not newer than the one held before this scan",
    ),
    (
        "iq: a report older than the baseline is refused, whatever its ID",
        ["assert", "nexus-iq", "--subject", APP, "--after", IQ_OLD, "--present", "six"],
        iq_server(Report("other", "2026-09-23T11:00:00.000Z", ALL)),
        1,
        "is not newer than the one held before this scan",
    ),
    (
        "iq: with no prior result, the first report is this scan's",
        ["assert", "nexus-iq", "--subject", APP, "--after", "none", "--present", "six"],
        iq_server(Report("first", "2026-09-23T12:05:00.000Z", ALL)),
        0,
        "This scan's Nexus IQ report",
    ),
    (
        "iq: a report at a stage other than build does not count",
        ["assert", "nexus-iq", "--subject", APP, "--after", "none", "--present", "six"],
        iq_server(Report("new", "2026-09-23T12:05:00.000Z", ALL, stage="release")),
        1,
        "holds no Nexus IQ report at all",
    ),
    (
        "iq: a missing application names the fix, as one annotation",
        ["assert", "nexus-iq", "--subject", APP, "--after", "none", "--present", "six"],
        no_application,
        1,
        f"::error::Nexus IQ has no application '{APP}'; create it, or let the server",
    ),
    (
        "iq: a package under another purl type is not mistaken for a pin",
        [
            "assert",
            "nexus-iq",
            "--subject",
            APP,
            "--after",
            IQ_OLD,
            "--present",
            "tomli",
        ],
        npm_tomli,
        1,
        "package 'tomli' is missing",
    ),
    # --- Baselines
    (
        "baseline: records the newest report held before the scan",
        ["baseline", "nexus-iq", "--subject", APP],
        iq_server(OLD_REPORT),
        0,
        "Baseline: api/v2/applications/x/reports/old/raw",
    ),
    (
        "baseline: an application not yet created counts as none",
        ["baseline", "nexus-iq", "--subject", APP],
        no_application,
        0,
        "treating the baseline as none",
    ),
    (
        "baseline: a Sonar project not yet created counts as none",
        ["baseline", "sonar", "--subject", KEY],
        missing_project,
        0,
        "treating the baseline as none",
    ),
    # --- Sonar
    (
        "sonar: recursive checkout indexes all three marker files",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py,direct_level.py,nested_level.py",
        ],
        sonar_server(
            "analysis-new", "2026-09-23T12:05:00+0000", PARENT + DIRECT + NESTED
        ),
        0,
        "Present as required: parent_level.py, direct_level.py, nested_level.py",
    ),
    (
        "sonar: submodules 'true' indexes the direct marker but not the nested",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py,direct_level.py",
            "--absent",
            "nested_level.py",
        ],
        sonar_server("analysis-new", "2026-09-23T12:05:00+0000", PARENT + DIRECT),
        0,
        "Absent as required:  nested_level.py",
    ),
    (
        "sonar: a scan that never reached into submodules fails",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py,direct_level.py",
        ],
        sonar_server("analysis-new", "2026-09-23T12:05:00+0000", PARENT),
        1,
        "file 'direct_level.py' is missing",
    ),
    (
        "sonar: the analysis held before the scan is refused",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py",
        ],
        sonar_server(
            "analysis-old", "2026-09-23T12:00:00+0000", PARENT + DIRECT + NESTED
        ),
        1,
        "still the one the server held before this scan",
    ),
    (
        "sonar: a new analysis in the same second as the baseline is refused",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py",
        ],
        sonar_server(
            "analysis-new", "2026-09-23T12:00:00+0000", PARENT + DIRECT + NESTED
        ),
        1,
        "is not newer than the one held before this scan",
    ),
    # --- Sonar branch: the scan is pinned to one, and so are the queries
    (
        "sonar: queries read the branch the scan was pinned to",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py",
        ],
        sonar_server("analysis-new", "2026-09-23T12:05:00+0000", PARENT, branch="main"),
        0,
        "Present as required: parent_level.py",
    ),
    (
        "sonar: an analysis on another branch is not read as this scan's",
        [
            "assert",
            "sonar",
            "--subject",
            KEY,
            "--after",
            SONAR_OLD,
            "--present",
            "parent_level.py",
        ],
        sonar_server(
            "analysis-new", "2026-09-23T12:05:00+0000", PARENT, branch="feature"
        ),
        1,
        "branch not named",
    ),
]


def run(argv: list[str], fetch: scan_contents.Fetch) -> tuple[int, str]:
    """Run the assertion against a stub, capturing what it printed."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        status = scan_contents.main(argv, fetch=fetch)
    return status, out.getvalue()


def output_round_trip() -> str | None:
    """A baseline's --output token must be accepted as the next --after."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "github_output"
        server = iq_server(OLD_REPORT)
        status, _ = run(
            ["baseline", "nexus-iq", "--subject", APP, "--output", str(out)], server
        )
        if status != 0:
            return f"baseline exited {status}"
        lines = out.read_text(encoding="utf-8").splitlines()
        if len(lines) != 1 or not lines[0].startswith("seen="):
            return f"expected one seen= line, got {lines!r}"
        token = lines[0].removeprefix("seen=")
        newer = iq_server(OLD_REPORT, Report("new", "2026-09-23T12:05:00.000Z", ALL))
        status, output = run(
            [
                "assert",
                "nexus-iq",
                "--subject",
                APP,
                "--after",
                token,
                "--present",
                "six",
            ],
            newer,
        )
        if status != 0:
            return f"assert rejected the baseline's own token: {output.strip()}"
    return None


def main() -> int:
    """Run every case; returns non-zero if any fails."""
    failures = 0
    for label, argv, fetch, want_status, want_text in CASES:
        status, output = run(argv, fetch)
        if status == want_status and want_text in output:
            print(f"  ok    {label}")
            continue
        failures += 1
        print(
            f"  FAIL  {label} (wanted exit {want_status} with {want_text!r}, got {status})"
        )
        for line in output.splitlines():
            print(f"        | {line}")

    extra: list[tuple[str, str | None]] = [
        (
            "output: a baseline token round-trips into the next assert",
            output_round_trip(),
        ),
    ]
    for stamp, label in [
        ("2026-09-23T12:00:00.000Z", "time: Nexus IQ 'Z' form parses"),
        ("2026-09-23T12:00:00+0000", "time: SonarCloud '+0000' form parses"),
    ]:
        try:
            _ = scan_contents.parse_time(stamp)
            extra.append((label, None))
        except ValueError as error:
            extra.append((label, str(error)))
    try:
        _ = scan_contents.parse_time("2026-09-23T12:00:00")
        extra.append(("time: a timestamp without a zone is refused", "it was accepted"))
    except ValueError:
        extra.append(("time: a timestamp without a zone is refused", None))

    for label, problem in extra:
        if problem is None:
            print(f"  ok    {label}")
        else:
            failures += 1
            print(f"  FAIL  {label}: {problem}")

    total = len(CASES) + len(extra)
    print(f"scan_contents: {total - failures} of {total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
