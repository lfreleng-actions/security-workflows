# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Assert which submodule levels of a fixture reached a scan's result.

The scan lanes report nothing about what they analysed, so a lane that
stopped fetching submodules would keep passing against less code: the
docs/BRIEF.md D12 failure mode. This asks the server afterwards.

The fixture, lfreleng-actions/test-python-submodules, nests three levels,
and each carries something found in no other level: an exactly pinned
requirements.txt line, which Nexus IQ identifies, and a marker source
file, which Sonar indexes. Finding a level's marker therefore proves
that level was scanned; its absence proves it was not.

Attributing the result to the right scan matters as much as reading it.
A result left by an earlier leg or run could satisfy the check while
this scan saw nothing, so the result is pinned by the server's own
record, never by the runner's clock:

  baseline  before a scan, record the identity of the newest result the
            server already holds (a Nexus IQ report, a Sonar analysis)
  assert    after it, require a result with a DIFFERENT identity that is
            strictly newer by the server's clock, then check its content

Comparing the server with itself leaves no runner clock skew and no
truncated timestamp to reason about. Each assert emits the identity it
confirmed, which is the next leg's baseline when legs share a project.

Usage:
  scan_contents.py baseline nexus-iq --subject ID [--output FILE]
  scan_contents.py assert nexus-iq --subject ID --after TOKEN \
      --present six,iniconfig --absent tomli [--output FILE]

--output appends 'seen=<token>' to FILE, for $GITHUB_OUTPUT. A token is
'none' when the server held no result yet.

Credentials come from the environment: NEXUS_IQ_SERVER,
NEXUS_IQ_USERNAME and NEXUS_IQ_PASSWORD, or SONAR_TOKEN (optional for a
public project) and SONAR_HOST_URL (default https://sonarcloud.io).
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import http.client
import json
import os
import sys
import urllib.parse
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import cast

Fetch = Callable[[str], object]

# Package URL type of every level's pin; see the fixture's README.
PURL_TYPE = "pypi"

NONE = "none"

# The Sonar branch every submodule scan is pinned to, via the lanes'
# sonar_branch_name. Without a name, the scanner's GitHub Actions
# auto-configuration analyses under the ref that dispatched the run, so
# a run from a branch under review would land somewhere these queries
# never look. Both the scans and the queries name it, so they agree.
SONAR_BRANCH = "main"


class AssertionFailed(Exception):
    """A finding that should fail the job, with a message naming why."""


class NotFound(AssertionFailed):
    """The server has no such application or project (HTTP 404)."""


class LevelsMismatch(AssertionFailed):
    """The result's content disagrees with the checkout mode, per level.

    Carries each failure separately so each becomes its own annotation,
    rather than being joined into one string and split apart again.
    """

    def __init__(self, failures: list[str]) -> None:
        """Record the individual failures."""
        super().__init__("; ".join(failures))
        self.failures: list[str] = failures


@dataclass(frozen=True)
class Result:
    """One scan result as the server records it."""

    identity: str
    stamp: str

    @property
    def when(self) -> dt.datetime:
        """The server's timestamp for this result."""
        return parse_time(self.stamp)

    @property
    def token(self) -> str:
        """A single-line form that round-trips through a job output."""
        return f"{self.identity}|{self.stamp}"


def as_dict(value: object, what: str) -> dict[str, object]:
    """Narrow a JSON value to an object, or fail naming what it was."""
    if not isinstance(value, dict):
        raise AssertionFailed(f"expected a JSON object for {what}")
    mapping = cast("dict[object, object]", value)
    return {str(key): item for key, item in mapping.items()}


def as_list(value: object, what: str) -> list[object]:
    """Narrow a JSON value to an array, or fail naming what it was."""
    if not isinstance(value, list):
        raise AssertionFailed(f"expected a JSON array for {what}")
    return list(cast("list[object]", value))


def as_text(value: object, what: str) -> str:
    """Narrow a JSON value to a non-empty string."""
    if not isinstance(value, str) or not value:
        raise AssertionFailed(f"expected a non-empty string for {what}")
    return value


def parse_time(value: str) -> dt.datetime:
    """Parse an ISO 8601 timestamp in any form either server emits.

    Nexus IQ writes '2026-09-21T10:56:26.285Z' and SonarCloud writes
    '2026-09-21T21:46:24+0000'. A naive value is rejected rather than
    guessed at, because comparing it with an aware one is meaningless.
    """
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    elif len(text) > 5 and text[-5] in "+-" and text[-4:].isdigit():
        text = text[:-2] + ":" + text[-2:]
    parsed = dt.datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        raise ValueError(f"timestamp has no timezone: {value!r}")
    return parsed


def parse_token(token: str) -> Result | None:
    """Read a baseline token back; 'none' means no prior result."""
    if token == NONE:
        return None
    identity, sep, stamp = token.rpartition("|")
    if not sep or not identity or not stamp:
        raise AssertionFailed(f"malformed baseline token: {token!r}")
    _ = parse_time(stamp)
    return Result(identity, stamp)


def names(values: str) -> list[str]:
    """Split a comma-separated argument, ignoring empty entries."""
    return [v.strip() for v in values.split(",") if v.strip()]


def check_levels(
    found: Iterable[str], present: list[str], absent: list[str], what: str
) -> list[str]:
    """Compare what a scan found against what each level should leave.

    Returns human-readable failures; an empty list means the result
    matched. Both directions are checked, because a lane that ignored
    the submodules input and always recursed would pass a presence-only
    test.
    """
    seen = set(found)
    missing = (
        f"{what} '{name}' is missing, so its submodule level never reached the scan"
        for name in present
        if name not in seen
    )
    extra = (
        f"{what} '{name}' is present, but this checkout mode should not"
        + " have fetched its level: the lane fetched more than it was told"
        for name in absent
        if name in seen
    )
    return [*missing, *extra]


def require_new(result: Result | None, before: Result | None, what: str) -> Result:
    """Require a result that this scan produced, judged by the server.

    It must differ from the one held before the scan, and be strictly
    newer by the server's own clock. Identity settles the same-second
    case a timestamp alone cannot, and never consulting the runner's
    clock removes skew between the two.
    """
    if result is None:
        raise AssertionFailed(
            f"the server holds no {what} at all, so the scan never reached it"
        )
    if before is None:
        return result
    if result.identity == before.identity:
        raise AssertionFailed(
            f"the newest {what} is still the one the server held before this"
            + f" scan ({before.stamp}), so the scan never reached the server"
            + " or has not finished processing"
        )
    if result.when <= before.when:
        raise AssertionFailed(
            f"the newest {what} ({result.stamp}) is not newer than the one"
            + f" held before this scan ({before.stamp}), so it cannot be this"
            + " scan's"
        )
    return result


def iq_latest(fetch: Fetch, application: str) -> tuple[Result | None, str]:
    """Return the newest build-stage report, and its data URL."""
    query = urllib.parse.urlencode({"publicId": application})
    apps = as_dict(fetch(f"api/v2/applications?{query}"), "applications")
    listed = as_list(apps.get("applications", []), "applications list")
    if not listed:
        raise NotFound(
            f"Nexus IQ has no application '{application}'; create it, or"
            + " let the server create applications automatically"
        )
    internal = as_text(as_dict(listed[0], "application").get("id"), "application id")
    reports = [
        as_dict(r, "report")
        for r in as_list(fetch(f"api/v2/reports/applications/{internal}"), "reports")
    ]
    build = [r for r in reports if r.get("stage") == "build"]
    if not build:
        return None, ""
    latest = max(
        build,
        key=lambda r: parse_time(as_text(r.get("evaluationDate"), "evaluationDate")),
    )
    # The data URL names the report's own scan ID, so it identifies the
    # report uniquely: two evaluations never share one.
    url = as_text(latest.get("reportDataUrl"), "reportDataUrl")
    return Result(url, as_text(latest.get("evaluationDate"), "evaluationDate")), url


def iq_packages(fetch: Fetch, url: str) -> list[str]:
    """Return the fixture-pin package names in one report."""
    data = as_dict(fetch(url), "report data")
    prefix = f"pkg:{PURL_TYPE}/"
    found: list[str] = []
    for item in as_list(data.get("components", []), "components"):
        component = as_dict(item, "component")
        purl = component.get("packageUrl")
        if isinstance(purl, str) and purl.startswith(prefix):
            found.append(purl[len(prefix) :].split("@", 1)[0].lower())
            paths = component.get("pathnames")
            where = (
                ", ".join(str(p) for p in cast("list[object]", paths))
                if isinstance(paths, list)
                else "?"
            )
            print(f"  identified {purl}  in {where}")
    return found


def sonar_latest(fetch: Fetch, project: str, branch: str) -> Result | None:
    """Return the newest analysis of one branch of the project."""
    query = urllib.parse.urlencode({"project": project, "branch": branch, "ps": 1})
    analyses = as_dict(fetch(f"api/project_analyses/search?{query}"), "analyses")
    listed = as_list(analyses.get("analyses", []), "analyses list")
    if not listed:
        return None
    analysis = as_dict(listed[0], "analysis")
    return Result(
        as_text(analysis.get("key"), "analysis key"),
        as_text(analysis.get("date"), "analysis date"),
    )


def sonar_files(fetch: Fetch, project: str, branch: str) -> list[str]:
    """Return the basenames of every file one branch's analysis indexed."""
    found: list[str] = []
    page = 1
    while True:
        query = urllib.parse.urlencode(
            {
                "component": project,
                "branch": branch,
                "qualifiers": "FIL",
                # Named rather than left to the default. The default
                # does recurse today (checked live: every file, two
                # levels deep, like strategy=all), but the markers sit
                # below the root, and 'children' would return none of
                # them. Asking for all descendants says what this needs.
                "strategy": "all",
                "ps": 500,
                "p": page,
            }
        )
        tree = as_dict(fetch(f"api/components/tree?{query}"), "component tree")
        for item in as_list(tree.get("components", []), "components"):
            path = str(as_dict(item, "component").get("path") or "")
            print(f"  indexed {path}")
            found.append(path.rsplit("/", 1)[-1])
        paging = as_dict(tree.get("paging", {}), "paging")
        size, total = paging.get("pageSize", 500), paging.get("total", 0)
        if (
            not isinstance(size, int)
            or not isinstance(total, int)
            or page * size >= total
        ):
            break
        page += 1
    return found


def http_fetcher(base: str, authorisation: str | None) -> Fetch:
    """Build a JSON GET against one HTTPS server, with optional credentials.

    http.client rather than urllib.request: it is fully typed, and it
    cannot be steered to a file:// or other scheme by a crafted URL,
    because the connection is HTTPS to one host fixed here.
    """
    parts = urllib.parse.urlsplit(base)
    if parts.scheme != "https" or not parts.hostname:
        raise AssertionFailed(f"server must be an https:// URL, not {base!r}")
    host, port = parts.hostname, parts.port
    prefix = parts.path.rstrip("/")

    def fetch(path: str) -> object:
        target = f"{prefix}/{path.lstrip('/')}"
        headers = {"Accept": "application/json"}
        if authorisation:
            headers["Authorization"] = authorisation
        connection = http.client.HTTPSConnection(host, port, timeout=60)
        try:
            connection.request("GET", target, headers=headers)
            response = connection.getresponse()
            body = response.read()
        finally:
            connection.close()
        if response.status == 404:
            # A Sonar query naming a branch cannot tell its two causes
            # apart, and they need different fixes: a project key the
            # server does not know, or a branch nothing has analysed.
            cause = (
                "no such project, or no analysis yet on the named branch;"
                + " check the project key, and that a scan has run on that branch"
                if "branch=" in target
                else "no such project or application; check the key"
            )
            raise NotFound(f"HTTP 404 from https://{host}{target}: {cause}")
        if response.status != 200:
            # The common causes differ by status, and a bare failure
            # names neither: 401 is the credential, 403 its scope.
            hint = {
                401: "credentials were rejected",
                403: "credentials lack permission to read this",
            }.get(response.status, "unexpected response")
            raise AssertionFailed(
                f"HTTP {response.status} from https://{host}{target}: {hint}"
            )
        return cast("object", json.loads(body))

    return fetch


def basic(user: str, secret: str) -> str:
    """Encode an HTTP Basic credential."""
    return "Basic " + base64.b64encode(f"{user}:{secret}".encode()).decode()


class Arguments(argparse.Namespace):
    """Parsed command line, typed so nothing downstream is Any."""

    mode: str = ""
    server: str = ""
    subject: str = ""
    after: str = ""
    present: str = ""
    absent: str = ""
    output: str = ""
    branch: str = SONAR_BRANCH


def server_fetch(args: Arguments) -> Fetch:
    """Build the fetcher for the chosen server from the environment."""
    env = os.environ
    if args.server == "nexus-iq":
        return http_fetcher(
            env["NEXUS_IQ_SERVER"],
            basic(env["NEXUS_IQ_USERNAME"], env["NEXUS_IQ_PASSWORD"]),
        )
    token = env.get("SONAR_TOKEN")
    return http_fetcher(
        env.get("SONAR_HOST_URL", "https://sonarcloud.io"),
        basic(token, "") if token else None,
    )


def latest(args: Arguments, fetch: Fetch) -> tuple[Result | None, str]:
    """Return the newest result for the subject, and how to read it."""
    if args.server == "nexus-iq":
        return iq_latest(fetch, args.subject)
    return sonar_latest(fetch, args.subject, args.branch), args.subject


def baseline(args: Arguments, fetch: Fetch) -> str:
    """Record the newest result before a scan; 'none' if there is none.

    A missing application or project counts as none, not as a failure:
    a server that creates them on first scan is then still usable, and
    if it does not, the assertion after the scan names the fix.
    """
    try:
        result, _ = latest(args, fetch)
    except NotFound as error:
        print(f"::notice::{error}; treating the baseline as none")
        return NONE
    if result is None:
        print("No result held yet; baseline is none")
        return NONE
    print(f"Baseline: {result.identity} at {result.stamp}")
    return result.token


def check(args: Arguments, fetch: Fetch) -> str:
    """Assert this scan's result carries exactly the expected levels."""
    before = parse_token(args.after)
    result, source = latest(args, fetch)
    what = "Nexus IQ report" if args.server == "nexus-iq" else "Sonar analysis"
    fresh = require_new(result, before, what)
    print(f"This scan's {what}: {fresh.identity} at {fresh.stamp}")
    if args.server == "nexus-iq":
        found, kind = iq_packages(fetch, source), "package"
    else:
        found, kind = sonar_files(fetch, source, args.branch), "file"
    present, absent = names(args.present), names(args.absent)
    failures = check_levels(found, present, absent, kind)
    if failures:
        raise LevelsMismatch(failures)
    print(f"Present as required: {', '.join(present)}")
    print(f"Absent as required:  {', '.join(absent) or '(none)'}")
    return fresh.token


def main(argv: list[str] | None = None, fetch: Fetch | None = None) -> int:
    """Run a baseline or an assertion; returns the process exit status."""
    parser = argparse.ArgumentParser(
        description="Assert submodule levels in a scan result."
    )
    _ = parser.add_argument("mode", choices=["baseline", "assert"])
    _ = parser.add_argument("server", choices=["nexus-iq", "sonar"])
    _ = parser.add_argument(
        "--subject", required=True, help="IQ application ID or Sonar key"
    )
    _ = parser.add_argument(
        "--after", default="", help="baseline token from before the scan"
    )
    _ = parser.add_argument("--present", default="", help="markers that must appear")
    _ = parser.add_argument("--absent", default="", help="markers that must not")
    _ = parser.add_argument(
        "--output", default="", help="append seen=<token> to this file"
    )
    _ = parser.add_argument(
        "--branch",
        default=SONAR_BRANCH,
        help="Sonar branch the scan was pinned to (default %(default)s)",
    )
    args = parser.parse_args(argv, namespace=Arguments())
    if args.mode == "assert" and not args.after:
        parser.error("assert needs --after, the baseline taken before the scan")
    if args.mode == "assert" and not names(args.present):
        parser.error("assert needs at least one --present marker")

    label = "Nexus IQ application" if args.server == "nexus-iq" else "Sonar project"
    print(f"{label} {args.subject}:")
    try:
        fetch = fetch or server_fetch(args)
        token = baseline(args, fetch) if args.mode == "baseline" else check(args, fetch)
    except LevelsMismatch as error:
        for message in error.failures:
            print(f"::error::{message}")
        return 1
    except AssertionFailed as error:
        print(f"::error::{error}")
        return 1
    if args.output:
        with open(args.output, "a", encoding="utf-8") as handle:
            _ = handle.write(f"seen={token}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
