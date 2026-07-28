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

Nine `composed-*` wrappers in the source repository (seven SonarCloud
variants, two Nexus IQ) are **not** ported as files. Each bundled a
build with a scan, and each was a source of intra-repository
cross-references. Their behaviour folds into a `build_type` input on the
relevant lane. Net: fifteen files become six lanes.

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
