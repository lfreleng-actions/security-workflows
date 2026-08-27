<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🔐 Security Workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/security-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/security-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/security-workflows)
<!-- prettier-ignore-end -->

Reusable GitHub Actions workflows that scan and audit Linux Foundation
projects for security and supply-chain risk. Each workflow is a
standalone **lane**: a caller invokes it directly, alongside whatever
build pipeline the project already runs.

These lanes are ecosystem-agnostic. Nexus IQ CLM, for example, serves
Maven, Gradle and Node.js projects alike, which is why they live here
rather than in a language-specific repository such as
[`java-workflows`](https://github.com/lfreleng-actions/java-workflows).

## Status

**Under construction.** This repository starts from
`workflows-template`, drops its generic build/test/release skeletons,
and picks up the security lanes from
`lfit/releng-reusable-workflows`, which retires once they land.

<!-- markdownlint-disable MD013 -->

| Lane | Purpose | Status |
| ---- | ------- | ------ |
| `sonatype-lifecycle.yaml` | Nexus IQ CLM dependency scan, with optional pre-scan build | **Available** |
| `sonarqube-cloud.yaml` | SonarQube Cloud static analysis, with optional pre-scan build | **Available** |
| `zizmor.yaml` | GitHub Actions workflow audit, SARIF publishing | **Available** |
| `openssf-scorecard.yaml` | OpenSSF Scorecard supply-chain health | **Available** |
| `package-hardening-audit.yaml` | Package manager hardening audit | **Available** |
| `codeql.yaml` | CodeQL static analysis, matrix over languages | **Available** |
| `action-pin-audit.yaml` | GitHub Actions `uses:` pin and reference audit | **Available** |

<!-- markdownlint-enable MD013 -->

All seven lanes are now available, and they supersede
`lfit/releng-reusable-workflows`. A migration map ships with the first
release.

## Design

Read [`docs/BRIEF.md`](docs/BRIEF.md) for the design decisions: why the
lanes live in a dedicated repository, how they compose with build
pipelines, the input vocabulary they share, and the per-lane Gerrit
posture.

## Composition

Lanes are **standalone**. They never call one another, and they never
call a build workflow. Composition happens in the caller:

```text
.github/workflows/gerrit-clm.yaml     -> sonatype-lifecycle.yaml
.github/workflows/gerrit-verify.yaml  -> java-workflows/maven-build-test.yaml
```

This is deliberate. Reusable workflows that reference each other across
repositories must be SHA-pinned, so every release of one forces a bump
in the other; composing at the caller avoids that entirely. Where a lane
genuinely needs a build first (the CLM lane, which scans resolved
dependencies), it runs the build itself via a `build_type` input rather
than calling out to another workflow.

## Gerrit support

Lanes are Gerrit-aware: a caller that sets `gerrit_refspec` gets a
change checked out with `checkout-gerrit-change-action` in place of
`actions/checkout`. Vote and comment casting belong in the caller, never
inside the lanes themselves; each lane's `gerrit.yaml` example shows the
shape.

One exception, enforced upstream rather than by choice:
**`openssf-scorecard.yaml` cannot support Gerrit.** `ossf/scorecard-action`
restricts which steps may run in its job, and its publish API rejects
anything else with HTTP 400. A Gerrit checkout action cannot run there.
Scorecard also scores a GitHub repository as a whole, so a per-change
scan would tell you nothing useful in any case.

## Java test coverage

`sonarqube-cloud.yaml` runs `build_type: maven` builds through
[`maven-build-action`][mba], which aggregates JaCoCo coverage across a
reactor's subprojects. Callers need no extra input and no `pom.xml` glue.

Sonar reads coverage per subproject, so by default a subproject's report
counts the tests living in that same subproject and no others. Where tests
in one subproject exercise another's code — normal in a layered reactor —
Sonar drops that coverage without saying so. [Sonar's guidance][sonar-multi]
fixes this with a dedicated aggregator subproject, which in turn has to list
every subproject by hand; forget to add a new one and its coverage
disappears with no error. The action instead points every agent at one
execution-data file and reruns the report goal once the reactor has
finished, so nothing enumerates subprojects. Its README covers the cases
where it leaves a project's own arrangements alone.

One of those cases needs the caller's help. A parent POM that sets the
`jacoco.destFile` or `jacoco.dataFile` property reads as the project
placing its own execution data, and the action leaves the layout alone.
Where the project sets those properties but aggregates nothing itself,
coverage stays per subproject and Sonar reports a figure that looks
plausible rather than zero. Pass `jacoco_mode: 'shared'` to say the
reactor may write one file. OpenDaylight projects need this: `odlparent`
sets both properties.

**Migrating from Jenkins:** drop any JaCoCo flags the job passed in.
Carried over, they read as the project arranging coverage itself, and the
aggregation steps aside. Projects that merged execution data through a
property of their own (OpenDaylight's `odl.jacoco.aggregateFile`, and the
`pom.xml` profile behind it) need neither any more.

[mba]: https://github.com/lfreleng-actions/maven-build-action
[sonar-multi]: https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/test-coverage/java-test-coverage#add-coverage-in-a-multi-module-maven-project

## Usage

Each lane ships two callers under `examples/<lane>/`, added alongside
the lane itself. Copy one into your project's `.github/workflows/`
directory and replace the placeholder `uses:` SHA with a pinned release:

- `github.yaml` — a plain GitHub-native caller.
- `gerrit.yaml` — a Gerrit-wrapped caller for projects where Gerrit is
  the source of truth, integrating with `gerrit_to_platform`
  voting/commenting.

Inputs are optional and default to the canonical behaviour; read the
`inputs:` block at the top of each workflow for the documented list.

## Conventions

Shared with `python-`, `go-`, `node-` and `java-workflows`:

- Workflow `name:` prefixed `[R]`; no `reuse-` filename prefix.
- Top-level `permissions: {}`, explicit least-privilege per job, and
  `timeout-minutes` on every job.
- A `gerrit-validate` job as the DAG root, failing fast when a caller
  supplies `gerrit_refspec` without the project, branch and URL the
  Gerrit checkout also needs.
- Harden-runner on every network-touching job: block mode by default,
  with `harden_runner_egress: 'audit'` as an explicit opt-out. Anything
  other than `audit` means block, so a typo cannot weaken the posture.
- Every `uses:` pinned to a full **commit** SHA (never an annotated tag
  object) with a `# vX.Y.Z` comment.
- `persist-credentials: false` on every checkout.
- Never interpolate `${{ }}` into `run:` blocks; env-mediate instead.
- `zizmor --persona auditor` must report zero findings.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/security-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/security-workflows/main.svg
