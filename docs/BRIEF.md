<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Design Brief: Security Workflows

This document records the design decisions behind `security-workflows`:
the reusable GitHub Actions workflows that scan and audit projects for
security and supply-chain risk across the `lfreleng-actions` estate.

The immediate driver is migrating the security lanes out of
`lfit/releng-reusable-workflows`, which is being deprecated, and getting
ONAP repositories off large per-repository CLM workflows onto thin
callers.

## Why a dedicated repository

### The churn problem

`releng-reusable-workflows` demonstrates a self-sustaining maintenance
tax. Workflows in that repository reference their own siblings via
`lfit/releng-reusable-workflows/...@<sha>`, so every release spawns a
fresh round of Dependabot self-bump pull requests — six to seven per
cycle, observed identically at v0.7.4 → v0.8.1 and again at
v0.8.1 → v0.10.0. Merging them creates commits, which become the next
release, which regenerates them. Those self-references were two releases
stale at every point sampled.

The cause is the **reference form**, not co-location. GitHub supports
`./.github/workflows/X.yaml` for same-repository calls, which resolves
to the same commit as the caller and therefore cannot go stale.

### Why splitting is not the fix for churn

Splitting a repository *removes* the `./` escape hatch: cross-repository
references must be SHA-pinned, so a split makes coordinated change
strictly harder — release A, then bump-and-release B, with no atomic
option. Churn alone argues for co-location.

### The actual argument: cohesion

CLM is not JVM-specific. `releng-reusable-workflows` already carries
Node.js and Gradle CLM callers alongside Maven, so the lane cannot live
in `java-workflows` without stranding consumers. The same holds for
zizmor, Scorecard and package hardening, none of which are tied to a
language. A tool-agnostic security repository is the right home.

### Scoping rule

Host only **standalone lanes that callers invoke directly**. Never lanes
that other repositories' reusable workflows nest into. Composition
happens at the caller.

Concretely: the SBOM and Grype jobs stay as inline jobs inside
`java-workflows`' verify lane. Moving them here would force a
cross-repository reference and reintroduce the treadmill above.

## Root cause driving the ONAP migration

ONAP CLM workflows fail with:

```text
java.lang.UnsupportedClassVersionError:
com/sonatype/insight/scan/cli/PolicyEvaluatorCli
has been compiled by a more recent version of the Java Runtime
(class file version 61.0) ... only recognizes up to 55.0
```

A single Java version drives both the Maven build (JDK 11, for older
ONAP code) and the Nexus IQ CLI 2.x (which requires Java 17). The fix is
to decouple the build JDK from the CLI runtime JDK, and to auto-detect
the build JDK per project via `build-metadata-action`.

An earlier proposal downgraded the CLI to the legacy 1.x line across
sixteen repositories. That treated the symptom; it has been abandoned.

## Lane inventory

Migrating from `lfit/releng-reusable-workflows`:

| Source | Lane | Gerrit posture |
| ------ | ---- | -------------- |
| `reuse-sonatype-lifecycle.yaml` | `sonatype-lifecycle.yaml` | Full |
| `reuse-sonarqube-cloud.yaml` | `sonarqube-cloud.yaml` | Full |
| `reuse-zizmor.yaml` | `zizmor.yaml` | Partial |
| `reuse-openssf-scorecard.yaml` | `openssf-scorecard.yaml` | None, by design |
| `reuse-package-hardening-audit.yaml` | `package-hardening-audit.yaml` | Full |
| `reuse-python-codeql.yaml` | `codeql.yaml` | Partial |
| `reuse-verify-github-actions.yaml` | `action-pin-audit.yaml` | Full |

Nine `composed-*` wrappers in the source repository (seven SonarCloud
variants, two Nexus IQ) are **not** ported as files. Each bundled a
build with a scan, and each was a source of intra-repository
cross-references. Their behaviour folds into a `build_type` input on the
relevant lane. Net: sixteen files become seven lanes.

The lane and this repository's own Scorecard self-scan wanted the same
filename, and could not merge into one file: the self-scan is a
`push`/`schedule`/`branch_protection_rule` workflow and the lane is
`workflow_call`. The lane keeps the canonical
`openssf-scorecard.yaml`, because that is the name consumers write in
their `uses:` line, and the self-scan becomes
`openssf-scorecard-self.yaml`. The self-scan now calls the lane by
local path, so the repository dogfoods what it publishes and drops its
last dependency on `lfit/releng-reusable-workflows`.

## Design decisions

### D1 — Collapse the `composed-*` matrix

Per-ecosystem wrappers become a `build_type` input. Anything more
elaborate composes at the caller.

### D2 — Resolve the `java_version` collision

In the source CLM workflow, `java_version` means the *Nexus IQ CLI
runtime* JDK. In `java-workflows` it means the *build* JDK. Align with
`java-workflows`:

- `java_version` — build JDK, auto-detected via `build-metadata-action`,
  with a caller override taking precedence.
- `iq_java_version` — Nexus IQ CLI runtime JDK, default 17.

Auto-detection is what makes the ONAP fix general: no per-repository
hardcoding of `11` across sixteen repositories.

### D3 — Failure-tolerance naming

`fail_on_build_error` becomes `build_permit_fail`, matching the house
`*_permit_fail` convention and its `NO_BLOCK_AUDIT_FAIL` escape hatch.
Semantics are preserved exactly.

### D4 — No `reuse-` filename prefix

No such prefix exists in `python-`, `go-`, `node-` or `java-workflows`.
Reusable lanes take bare descriptive names.

### D5 — Baseline on `go-workflows`

`python-workflows` is described as the reference implementation but is
the most drifted. `go-workflows` is the most current and complete:
input validation beyond Gerrit, `type: number` timeout inputs, and
`*_enabled` job toggles. Where the repositories disagree, prefer Go.

### D6 — Build-scoped egress hatch

`build_permit_egress_traffic` (boolean, default `false`) runs
harden-runner in audit mode for the build job only, leaving every other
job governed by `harden_runner_egress`. Build lanes fetch dependencies
from CDNs that are impractical to enumerate; the alternative was
dropping the entire workflow to audit.

### D7 — Pinning policy

Action pins are left to Dependabot, which applies a seven-day cooldown.
The `.github` allow-list coordinate is the exception: it must be current,
with no cooldown, because it gates network access.

Always pin the **commit** SHA, never the annotated tag object. The
`.github` repository has shipped three consecutive mis-tagged releases
(v0.8.0 and v0.9.0 both pointed at commits predating the changes they
advertised), so verify allow-list content by fetching the file at the
ref rather than trusting the tag.

### D8 — Gerrit posture is per lane

`openssf-scorecard.yaml` cannot support Gerrit. This is enforced
upstream, not chosen: `ossf/scorecard-action` restricts the steps
permitted in its job to `actions/checkout`, `actions/upload-artifact`,
`github/codeql-action/upload-sarif`, `ossf/scorecard-action` and
`step-security/harden-runner`. Its publish API rejects anything else
with HTTP 400, naming the offending step. A Gerrit checkout action
cannot run there, and the same restriction is why that lane carries a
curated inline allow-list instead of the shared loader.

Scorecard also scores a repository as a whole, so a per-change scan
would not be meaningful even were it permitted.

`codeql` and `zizmor` are partial: they can scan a Gerrit change, but
their SARIF lands in GitHub code scanning, so Gerrit receives a vote
rather than inline findings.

### D9 — The zizmor lane must expose `persona` and `min-severity`

The source workflow passes neither, relying on the action's defaults.
The organisation pipeline runs `auditor` at an `informational` floor, so
a lane using defaults would silently disagree with both the ruleset PR
gate and the SARIF publisher. Both become inputs, defaulting to match
the organisation pipeline.

This matters: at a `low` floor, zizmor discards informational findings
before they reach the SARIF. A scan of `python-workflows` produced
fourteen genuine `template-injection` findings that the floor discarded,
while the organisation report showed every repository as clean.

### D10 — Third-party action dependency

`package-hardening-audit` depends on
`jordanconway/package-manager-hardening`, the only non-Linux-Foundation
action across the six lanes. Accepted: the author is a team member. The
repository may relocate, so the pin should be reviewed if the coordinate
changes.

### D11 — Split pre-scan work between `build_type` and the scan action

The seven `composed-*-sonar-cloud` variants fall into two groups, and
only one of them needs a lane-level build stage.

`build_type` covers `maven`, `gradle`, `tox` and `go`. Each runs beside
the scanner and leaves something behind that the analyser reads: compiled
bytecode for the Java analyser, a JaCoCo report, a `coverage.xml`, a
`coverage.out`.

C and C++ take the other path. Their analyser needs a compilation
database captured by SonarSource's build-wrapper, which *wraps* the build
rather than running beside it, so it belongs to the scan action's
`build_wrapper_url`. The `autotools` and `cmake` variants both piped a
script from `releng-global-jjb`'s mutable `master` branch into `bash`;
`build_wrapper_url` replaces that with an input the caller pins. Anything
else uses `prescan_script_url`, and `generic` becomes `build_type: none`.

The three are mutually exclusive, and the lane says so in `validate`
rather than letting a project build twice.

| Source variant | Replacement |
| -------------- | ----------- |
| `composed-maven-sonar-cloud.yaml` | `build_type: maven` |
| `composed-tox-sonar-cloud.yaml` | `build_type: tox` |
| `composed-go-sonar-cloud.yaml` | `build_type: go` |
| `composed-autotools-sonar-cloud.yaml` | `build_wrapper_url` |
| `composed-cmake-sonar-cloud.yaml` | `build_wrapper_url` |
| `composed-prescan-sonar-cloud.yaml` | `prescan_script_url` |
| `composed-generic-sonar-cloud.yaml` | `build_type: none` |

There was no Gradle SonarCloud variant. The lane adds `build_type:
gradle` regardless, because the Java analyser's need for bytecode does
not depend on which build tool produced it, and the CLM lane already
carries the same pair.

### Analysis backend

`analysis_mode` selects between the Sonar Scanner CLI and
`sonar-maven-plugin`. Left empty it is **derived from `build_type`**: a
Maven build is analysed with the Maven plugin, everything else with the
CLI.

The two are not interchangeable on a Maven project, and the wrong one
fails quietly. The CLI walks the workspace, so after a build it also
reads `target/generated-sources` — generated OpenAPI, MapStruct and the
like — and reports findings against code nobody wrote. The Maven plugin
instead derives module structure, compiled binaries, coverage report
paths and exclusions from the project model.

Deriving rather than defaulting to `cli` is deliberate. ONAP
`cps/ncmp-dmi-plugin` had a CLI analysis move its branch from 0 bugs to
1157 without a line of code changing, and the run still reported
success. Nothing in the caller could correct it, because the action
exposed the input and this workflow did not pass it. A default that is
wrong for the commonest Java case, on a lane whose failure mode is a
plausible-looking number rather than an error, is not a safe default.

The derivation is sound because Maven mode needs an already-built
reactor, and `build_type: maven` is exactly when this lane has built
one.

### D12 — Sonar fails on build error; CLM does not

`build_permit_fail` defaults to `false` in `sonarqube-cloud.yaml` and
`true` in `sonatype-lifecycle.yaml`. The divergence is deliberate.

A partially built workspace still yields a useful CLM result: Nexus IQ
evaluates whatever dependencies resolved. Sonar behaves differently. A
failed build leaves no bytecode and no coverage report, so the scan
succeeds and reports a project with near-zero coverage and no
bytecode-derived findings. That is worse than a failure, because the
dashboard looks healthy. The Sonar default therefore matches the sibling
repositories; the CLM lane is the exception.

### D13 — SARIF publishing keeps its own job

`zizmor-scan-action` can upload SARIF to code scanning itself, via an
`upload-sarif` input. The lane does not expose it, and instead keeps the
source workflow's two-job split: `audit` holds `contents: read`, writes
the SARIF as an artifact, and a separate `upload` job holds
`security-events: write`.

Using the action's own upload would collapse that. Every run would need
the write scope, including pull requests raised from forks, for a
publish step that only fires on default-branch pushes. The artifact hop
is the cost of keeping the audit job unprivileged.

The publish step is `continue-on-error`. A repository without code
scanning enabled, or one that has hit a quota, should not fail a run
whose audit succeeded and whose findings are already in the job summary.

### D14 — The zizmor lane reports; it does not gate

In SARIF mode zizmor exits 0 whatever it finds — the finding exit codes
only apply to its plain output mode. `zizmor-scan-action` exposes a
`sarif-file` output but no findings count, so the lane has nothing to
branch on and deliberately carries no `scan_permit_fail` input.

Making the lane gateable belongs in the action, not here: a
`findings-count` output (or a `permit_fail` input) added to
`zizmor-scan-action` would let every consumer gate, whereas parsing the
SARIF inside the lane would put language-specific logic in a workflow
that should be action calls. Tracked as a follow-up.

### D15 — Scorecard's publish rules shape the whole lane

When `publish_results` is on, the Scorecard API validates the workflow
that produced the results and rejects anything outside a narrow shape.
Every way this lane differs from its siblings traces back to that.

The scan job may only run steps from `actions/checkout`,
`actions/upload-artifact`, `github/codeql-action/upload-sarif`,
`ossf/scorecard-action` and `step-security/harden-runner`. So the shared
`harden-runner-block-action` loader cannot run there, and the scan job
carries a curated inline allow-list, widened by
`extra_allowed_endpoints` rather than by forking. The summary job has no
such restriction and uses the shared loader.

The scan job may not declare job-level `env` or `defaults`, which is why
input validation sits in its own job. That constraint turned out to be
an improvement: the checks now run before the analysis starts, so a bad
input costs seconds rather than a full scan followed by an opaque API
rejection.

The rules also reach the whole file: no top-level `env` or `defaults`,
no workflow-level write permissions, and `id-token: write` on the scan
job alone. They reach the *caller* too, which is why the example spells
them out.

Two things were verified against a live run rather than assumed.
Publishing does work through the reusable-workflow indirection: the
Scorecard API returns a current score for this repository, produced by a
caller plus reusable pair. And `ghcr.io` is deliberately absent from the
curated allow-list even though `ossf/scorecard-action` is a Docker
action; the image pull was confirmed to succeed under that exact list,
so it must not be added speculatively.

There is no `repository` or `ref` input. Scorecard reads
`GITHUB_REPOSITORY` and queries the GitHub API, so checking out a
different repository would change the working tree without changing what
is scored — an input that appeared to work and silently did nothing.

### D16 — CodeQL takes languages as an input, not as a hardcoded matrix

The source workflow was Python-only despite carrying machinery for
other languages, and that machinery never ran. Its matrix held one
hardcoded entry, so the Swift branches in `runs-on` and
`timeout-minutes` were unreachable: no matrix entry could select them.

`languages` becomes an input and the matrix is built from it in the
`validate` job. The matrix has to come from a job output because GitHub
evaluates `strategy.matrix` before any step runs, so it cannot be
derived inside the analysis job.

One language per job is also what makes `build_mode` and `packs`
meaningful: CodeQL accepts both only when analysing a single language
per job. `fail-fast` is off, so a language whose extraction breaks does
not discard the others' results.

`build_mode` and `runs_on` still apply to every matrix entry, so a
project mixing interpreted and compiled languages needs one call per
build mode. That composes at the caller, consistent with the rest of
the repository, and the example shows it.

`build_mode: manual` is rejected outright. It requires build steps
between `init` and `analyze`, and a reusable workflow cannot accept
caller-supplied steps; permitting it would build an empty database and
report a clean result for code that was never compiled.

### D17 — CodeQL under Gerrit analyses but does not publish

Code scanning attributes SARIF to a GitHub ref, and a Gerrit patchset is
not one. Publishing a per-change scan would file alerts against the
target branch for code that has not merged, and those alerts would
outlive an abandoned change.

The lane therefore keeps `upload` as an input defaulting to `always`,
and the Gerrit example sets `upload: 'never'`, reporting the outcome as
a Verified vote instead. Projects wanting the dashboard populated as
well deploy a second, GitHub-native caller on default-branch pushes,
which scans merged code on a real ref.

This is what D8 means by "partial" Gerrit support for this lane: the
scan runs, but the results reach Gerrit as a vote rather than as inline
findings.

### D18 — `reuse-verify-github-actions` becomes `action-pin-audit`

The source name described the mechanism ("verify GitHub Actions") rather
than the control, and was generic enough to read as any workflow check.
What the lane actually asserts is narrow: every `uses:` coordinate in the
repository resolves, and each names a commit SHA rather than a tag or a
branch. `action-pin-audit.yaml` says that, and matches the `*-audit`
precedent set by `package-hardening-audit.yaml`.

The import is otherwise faithful. The source workflow is a wrapper around
`pinned-versions-action`, itself a wrapper around the `gha-workflow-linter`
tool, and the lane keeps that structure: no logic moves into the workflow.
Only the harden-runner allow-list coordinate changed, from `ca8ce369`
(86 endpoints) to the current `bf6642f6` (195). The `pinned-versions-action`
and harden-runner pins were already current.

Three things the source workflow lacked are added, all house vocabulary
rather than new behaviour:

- **Inputs.** The source declared `workflow_call:` with none at all, and
  hardcoded `ubuntu-24.04`. It was the only lane a caller could not
  configure.
- **Gerrit support.** Full, per D8: the linter reads files from the
  checkout and reports through the job's exit status, so nothing prevents
  it scanning a patchset. Requiring the lane to own the checkout is what
  makes that possible, so the lane passes `no_checkout: 'true'` to the
  action, as the CLM and Sonar lanes do.
- **`full_scan` and `linter_version`,** which the action already exposed
  and the source workflow did not forward.

Owning the checkout has one consequence worth stating. The action checks
out `github.event.pull_request.head.sha` on pull requests, whereas a plain
`actions/checkout` takes the merge ref. The lane reproduces the head-SHA
behaviour when `ref` is empty. Auditing the merge ref would surface pins
from the base branch that the change never touched, and on a repository
mid-cleanup that turns every pull request red.

That default is qualified to same-repository audits. A caller that sets
`repository` is auditing somewhere else, where the calling pull request's
head SHA does not exist; the lane leaves `ref` empty there so
`actions/checkout` takes the target's default branch.

### D19 — The pin audit gates; it has no `*_permit_fail`

`package-hardening-audit` defaults `audit_permit_fail: true` so a project
can adopt it as a required check before reaching zero findings. This lane
deliberately offers no equivalent, and the four migrating callers all
gated already.

The reasoning differs from D14, where the zizmor lane cannot gate because
the action exposes no findings count. Here the linter's exit status is the
entire signal: suppress it and the lane produces nothing a caller can act
on, because there is no summary table or SARIF to read instead. A pin
audit that passes while findings exist is indistinguishable from one that
found nothing.

The adoption problem D19 would have solved is better handled before the
lane is deployed: running `gha-workflow-linter lint --auto-fix` locally
pins the offenders in one pass. Scope the pull-request trigger with a
`paths` filter, as both examples do, so unrelated changes are not gated
on it.

### D20 — `sonatype-lifecycle.yaml` gets a `go` `build_type`

Added after the initial port, migrating ONAP `policy-opa-pdp` off its
Jenkins `gerrit-nexus-iq-go-clm` job. That job branches on
`nexus-iq-use-cli`: the CLI branch runs `go mod tidy` then points the
Nexus IQ CLI's build analyser at `go.sum`; the REST API branch (what
`policy-opa-pdp` actually ran) instead uploads a `cyclonedx-gomod`
SBOM. Both exist only because the legacy CLI release predates native
Go SBOM support.

The lane defaults to the CLI branch (`scan_mode: cli`): `go mod tidy`,
then `scan_targets` resolves to `go.sum` whenever `build_type: go`,
unconditionally and without a caller override — Go has no equivalent
of `scan_targets` for a reason. `tidy` rather than `download` is
deliberate and matches legacy: a scan job's checkout is never
committed back, so mutating go.sum in place is safe, and a drifting
go.sum should fail the scan rather than have a `download`-only step
silently tolerate it. Neither `go mod tidy` nor the `sbom`-mode steps
below carry `continue-on-error`, unlike the Maven/Gradle build steps:
a partial Maven build still leaves resolved artefacts behind, but a
failed `tidy` or SBOM generation leaves the scan target itself stale,
missing or empty, and letting the scan proceed regardless would be a
silently-incomplete result rather than a partial one.

`scan_mode: sbom` reinstates the REST branch as an opt-in alternative,
added on request to keep parity for projects that ran it
(`policy-opa-pdp` among them), rather than only the CLI branch this
lane originally shipped with. It runs `cyclonedx-gomod` (version
pinned via `go_sbom_tool_version`) to generate a CycloneDX SBOM, looks
up Nexus IQ's internal application UUID for the resolved `publicId`
(a separate value the CLI branch never needs), and `POST`s the SBOM to
`sources/cyclonedx` — replacing the `sonatype-lifecycle-scan-action`
step entirely rather than running alongside it. That upload has no
synchronous verdict the way the CLI's build analyser does, so
`fail_on_policy_warnings`, `ignore_scanning_errors`,
`ignore_system_errors` and the `iq_cli_version`/`iq_java_version`/
`iq_java_distribution` inputs are all inert in `sbom` mode — matching
why the legacy Jenkins job never voted on its own result either. This
mode should stay the exception rather than the default: reach for
`cli` unless matching a project's pre-existing REST-branch history is
the goal.

The input started life as `go_scan_mode`, Go-specific in name as well
as effect. PR #38 review pointed out that nothing about it actually is
Go-specific — it resolves an application UUID and `POST`s a CycloneDX
document, which any ecosystem this lane can produce one for could
reuse — so it was renamed to `scan_mode` before merge, while it still
only had one caller and renaming cost nothing. Only the Go path drives
`sbom` today; generalising the mechanism to other ecosystems, adopting
`lfreleng-actions/sbom-action` in place of a hand-rolled
`cyclonedx-gomod` call, and verifying Nexus IQ ingests syft-generated
CycloneDX as well are tracked separately (issues #39 and #40) rather
than folded into this decision.

That same review surfaced that Sonatype's own guidance has moved.
Their [Go Application Analysis][go-app-analysis] page, last modified
18 Feb 2026 (checked 2026-08), no longer mentions CycloneDX or an
SBOM route for Go at all, recommends a `go.list` file from
`go list -deps` as giving "the most accurate results", and describes
`go.sum` as "supported, but may include dependencies that are not
used by the application". That is a stronger version of the argument
this section already made: the vendor has not just stopped needing
the SBOM route for Go, it has stopped recommending it entirely, which
is further reason for `sbom` to stay the exception. Whether to adopt
`go.list` as the `cli`-mode scan target is tracked separately
(issue #41): it would change the migrated `policy-opa-pdp` job's
results from the Jenkins job it replaces, which is a decision for
whoever owns that migration rather than this record.

[go-app-analysis]: https://help.sonatype.com/en/go-application-analysis.html

Go's toolchain version takes no caller input at all: `Gather build
metadata` now runs for `build_type: 'go'` too, and `Setup Go` reads
`steps.metadata.outputs.go_go_version` -- the same `build-metadata-action`
already used to auto-detect `java_version` for Maven/Gradle, rather
than a second, Go-specific `go_version`/`go_version_file` pair reading
`go.mod` independently. Review on the PR pointed out `go-workflows`
already derives its Go version matrix through this action (at an
older pin), so this lane carrying its own separate detection was
redundant; tracked as issue #43 before landing here. This
intentionally diverges from `sonarqube-cloud.yaml`'s own Go path,
which still takes `go_version`/`go_version_file` inputs directly --
bringing that lane in line is left for #43 rather than done as a
side effect of this one.

### Legacy defects not carried forward

The audit of the source SonarCloud workflows found the following. None
reproduce in the lane, and each is worth knowing when comparing a
migrated project's results against its history.

- **The token never reached the scanner in four of seven variants.**
  `autotools`, `cmake` and `generic` passed `SONAR_TOKEN` as step-level
  `env` on the `uses:` step. The action sets `SONAR_TOKEN` from its own
  `sonar_token` input at step level, which takes precedence, so the
  inherited value was overwritten with an empty string. `tox` passed
  `SONAR_TOKEN` as a `with:` key the action does not declare.
- **`SONAR_ARGS` and `SONAR_PROJECTBASEDIR` were declared but unused** in
  `autotools`, `cmake`, `generic` and `prescan`. Callers setting them saw
  no effect.
- **`no_checkout` was unset in four variants** that had already checked
  out and built. The action's own checkout then ran over the workspace,
  discarding the build output the scan depended on.
- **`composed-tox` never delivered coverage to the scanner.** The tox run
  and the scan were separate jobs with no artefact transfer, so the
  report existed on a runner the scanner never saw.
- **`composed-maven` passed the token on the Maven command line** as
  `-Dsonar.login=<token>`, visible in process listings and frequently in
  build logs. It also used the deprecated `sonar.login` property.
- **Template injection** in `autotools`, `cmake`, `prescan` and
  `generic`: `PRE_BUILD_SCRIPT` and `PRE_BUILD_SCRIPT_PATH` interpolated
  straight into `run:` blocks and into `$GITHUB_ENV`. The `go` variant
  had already been fixed and is the shape the lane follows.
- **`generic` splatted secrets into the environment** via a third-party
  action, and guarded its pre-build step with
  `hashFiles(inputs.PRE_BUILD_SCRIPT)` while executing the same input as
  a command.
- No `timeout-minutes` anywhere, Python 3.8 hardcoded, and a mix of
  `ubuntu-latest` and `ubuntu-24.04`.

The CodeQL source workflow contributed two of its own:

- **A dead pip cache.** It restored `~/.cache/pip` into the analysis
  job. CodeQL stopped installing Python dependencies in action version
  3.25.0, and `setup-python-dependencies` has been ignored ever since,
  so nothing in that job populated or read the cache. Restoring a cache
  into a job holding `security-events: write` is also a cache-poisoning
  surface, so it bought a risk for no benefit. Dropped; CodeQL manages
  its own caching through `trap-caching` and `dependency-caching`.
- **A 360-minute timeout**, GitHub's maximum, on a `build-mode: none`
  Python scan that completes in minutes. A hung extraction burned six
  hours of runner time before failing. The lane defaults to 60 and
  exposes the value.

## Shared input vocabulary

Common to every lane, matching the sibling repositories:

`repository`, `ref`, `path_prefix`, `harden_runner_egress`,
`harden_runner_allowlist`, `gerrit_refspec`, `gerrit_project`,
`gerrit_branch`, `gerrit_url`, and lane-appropriate `*_permit_fail`
toggles.

The source workflows used three different idioms for the allow-list
(`harden_runner_config`, hardcoded, and hardcoded plus
`extra_allowed_endpoints`) and three for failure tolerance (`warn_only`,
bare `continue-on-error`, and nothing). Both are normalised here.

## Conventions inherited from the template

- Workflow `name:` prefixed `[R]`.
- All `workflow_call` inputs `required: false`, lowercase snake_case.
- Top-level `permissions: {}`; minimal per-job grants; `timeout-minutes`
  on every job.
- `gerrit-validate` as the DAG root, always running so gating dependents
  does not trip GitHub's skipped-need propagation.
- Dual checkout switched on `gerrit_refspec`, with
  `persist-credentials: false` on every checkout.
- Harden-runner triple per network-touching job; block is the
  default-safe branch and audit an explicit opt-in.
- Never `secrets: inherit`; declare secrets explicitly.
- Never interpolate `${{ }}` into `run:` blocks; env-mediate.
- Each lane, as it lands, ships
  `examples/<lane>/{github.yaml,gerrit.yaml}`; `testing.yaml` calls lanes
  by local `./` path.

## Validation gate

Every lane must pass, with no exceptions:

- `zizmor --persona auditor` — zero findings.
- `pre-commit run --all-files` — including yamllint, actionlint and
  workflow schema validation.

## Follow-ups

1. Port the six lanes (Phases 2–4), CLM first.
2. Reinstate `testing.yaml`, wired to real fixtures by local path.
3. Publish a migration map from the old `reuse-*` names.
4. Pilot the CLM lane on ONAP `usecase-ui`, then roll to the remaining
   repositories.
5. Deprecate `lfit/releng-reusable-workflows`.

Note on fixtures: pinned fixture repositories produce *decaying* audit
results, because advisory databases are queried live while the pin is
frozen. Audit legs against fixtures should be reported but not gated.
