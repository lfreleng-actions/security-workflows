<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Interim Evaluation: Security Workflows Development Cycle

Dated 2026-09-30. A break-point review of `security-workflows` against
`docs/BRIEF.md`, taken after the merge of PR #114, with v0.9.1 the
latest published release. It records what this cycle delivered against
the plan the previous revision of this document set out on
2026-08-19 (after PR #38, v0.3.0), what that plan got wrong, what the
estate adoption survey found, and the work that remains before the
repository can be called done for ONAP, O-RAN-SC and OpenDaylight.

## Where we are

All seven lanes from the BRIEF's inventory are ported and shipping:
`sonatype-lifecycle`, `sonarqube-cloud`, `zizmor`, `openssf-scorecard`,
`package-hardening-audit`, `codeql` and `action-pin-audit`, each with
GitHub and (where the posture allows) Gerrit examples.

Between v0.3.0 and v0.9.1 the cycle closed **20 issues** across twelve
releases, and **no issue is open**. All seven open when the previous
revision was written are closed, as is every issue raised since. The
last two, #39 and #40 on the SBOM transport, closed as a decision
rather than a feature (D25). What remains is not tracked as issues:
it is proving the lanes against live servers, rolling them out, and
the structural work below.

The two scan lanes gained, in outline:

- **CLM lane:** `go.list` as the default Go scan target (D23), a
  `python` `build_type` (D24), toolchain selection from `go.mod`
  (D21), `fetch_depth` and `submodules` checkout inputs, and
  `mvn_pom_file`.
- **Sonar lane:** aggregate JaCoCo coverage handed to the scanner
  (D22), `scanner_args` exposed as a lane output, `prescan_script_path`
  for a checked-in pre-scan script, and `mvn_pom_file`.
- **Both:** the migration-audit input regressions settled (#58–#61),
  with evidence of what callers actually set recorded in the BRIEF.
- **SBOM mode** stays Go-only on `cyclonedx-gomod`: a syft-generated
  SBOM identifies the same modules but scans more than the build uses
  (D25).

Self-testing changed shape. `tests/workflow-steps.sh` runs on every
pull request via `workflow-tests.yaml`, extracting the lanes'
validation and hook steps verbatim with `yq` and executing them against
generated inputs — 70 cases on `main`, with mutation testing used to
prove each check can fail. `testing.yaml` gained credentialled legs
that scan a submodule fixture through both lanes and ask the servers
which levels arrived (#74). Both were a response to a finding covered
below: `testing.yaml` itself is dispatch-only and has never been
dispatched.

## Adoption

The previous revision sequenced deployment as ONAP first, then
O-RAN-SC and OpenDaylight after the ONAP wave. Adoption overtook that
plan. A GitHub code search on 2026-09-30 finds **55 repositories**
outside this organisation calling the lanes, from 61 workflow files:

| Org          | Lane                 | Repositories |
| ------------ | -------------------- | ------------ |
| ONAP         | `sonatype-lifecycle` | 39           |
| ONAP         | `sonarqube-cloud`    | 3            |
| ONAP         | `openssf-scorecard`  | 2            |
| OpenDaylight | `sonarqube-cloud`    | 16           |
| O-RAN-SC     | —                    | 0            |

OpenDaylight onboarded its Sonar estate in parallel with ONAP rather
than after it. O-RAN-SC has not started.

The pins are spread across five releases, and the oldest is still
among the largest groups:

| Pinned release | Calls |
| -------------- | ----- |
| v0.3.0         | 18    |
| v0.5.0         | 3     |
| v0.7.0         | 19    |
| v0.8.0         | 16    |
| v0.9.0         | 5     |

**18 calls are still pinned to v0.3.0**, the release the previous
revision reviewed — down from 21 a week earlier, as callers move to
v0.8.0 and v0.9.0. Those that remain run without everything this cycle
fixed, including D21's toolchain correction. Pinning is correct and
deliberate (D7); what it needs is Dependabot, or a coordinated bump,
reaching them. That is rollout work in the consuming repositories, not
here, but it is the largest gap between what this repository ships and
what the estate runs.

## Progress against the previous plan

### What closed

<!-- markdownlint-disable MD013 -->

| Issue    | Outcome                                                                                                                              | Delivered by                        |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| #41      | `go_scan_target`, default `go.list`; `'sum'` kept for parity (D23)                                                                   | PR #90                              |
| #42      | `build_type: 'python'` resolving `requirements.txt`, `uv.lock` or project metadata (D24)                                             | PR #113 (v0.9.0)                    |
| #43      | **Closed the opposite way** — build metadata is not used for Go; the CLM lane now reads `go.mod`, as the Sonar lane always did (D21) | PR #76                              |
| #44      | BRIEF's Node.js CLM claim corrected                                                                                                  | PR #73                              |
| #50      | Gerrit example gains the Go variant; `policy-opa-pdp` cut over with `scan_mode: 'sbom'` pinned                                       | PR #90; ONAP                        |
| #54      | Workspace variables in Maven parameters expanded                                                                                     | `maven-build-action`                |
| #55, #56 | Multi-module JaCoCo coverage                                                                                                         | `maven-build-action` v0.4.0; PR #53 |
| #57      | CLM lane accepts `fetch_depth` and `submodules`                                                                                      | PR #73                              |
| #58      | `prescan_script_path`, containment-checked against the checkout                                                                      | PR #99                              |
| #59, #60 | `ENV_VARS`/`ENV_SECRETS` and `op_secret_reference` **stay dropped**, on evidence; design recorded                                    | PR #99                              |
| #61      | `mvn_pom_file` on both lanes                                                                                                         | PR #99                              |
| #70      | `coverage_report_paths` wired into the Sonar scan (D22)                                                                              | PR #76                              |
| #75      | Go fixture gains a `toolchain` directive; assertion asserts on it                                                                    | `test-go-project`; PR #82           |
| #77      | CLI-mode coverage self-test able to fail                                                                                             | PR #89                              |
| #100     | Per-PR harness for the lanes' validation and hook steps                                                                              | PR #113                             |
| #39      | syft-generated CycloneDX identifies Go modules identically to `cyclonedx-gomod`, but scans `go.sum` and a thinner graph (D25)        | PR #115                             |
| #40      | **Closed as a decision** — `sbom` stays Go-only on `cyclonedx-gomod`; every other `build_type` has a CLI path (D25)                  | PR #115                             |
| #74      | Submodule fixture, and legs asserting which levels reached each scan                                                                 | `test-python-submodules`; PR #114   |

<!-- markdownlint-enable MD013 -->

### Where the plan was wrong

Five outcomes departed from what the previous revision predicted, and
each is worth knowing before trusting the rest of this document's
forecasts.

**#43 was reversed, not completed.** The plan proposed extending
`build-metadata-action`'s Go version detection to the Sonar lane for
consistency. Investigation found the CLM lane's use of it was itself a
defect: its `go_go_version` output is the `go` directive alone, and
passing it to `setup-go` as `go-version` suppressed the `toolchain`
directive, silently building on a Go the project had moved away from.
The CLM lane now reads `go.mod` through `go-version-file`; the Sonar
lane always had, through `go-test-action`, and was never affected.
Following the plan would have spread the defect to it. D21 records it.

**#41 was not blocked for long.** Its sequencing behind the
`policy-opa-pdp` cutover assumed the cutover was pending. It had
already happened, with `scan_mode: 'sbom'` pinned — the REST path, which
never reads the CLI's scan target — so the default flip could not
disturb its comparison. Both #41 and #50 closed together in PR #90.

**#59 and #60 closed as decisions, not features.** The migration
audit found no caller setting `ENV_SECRETS` and none setting
`OP_SECRET_REFERENCE`, and the `ENV_VARS` values in use were either
already served by typed inputs or inert. The BRIEF's "Dropped inputs"
section records the evidence and the design to build if a consumer
appears. #60 reversed an earlier recommendation to keep it open.

**#42's "identify consumers first" gate passed.** The previous
revision expected Python CLI demand to be unproven. Three O-RAN-SC
projects — `pti-o2`, `smo-ves` and `ric-plt-xapp-frame-py` — still run
the legacy `gerrit-tox-nexus-iq-clm` job, so the CLI path was built
rather than closed as covered by SBOM mode. `pti-o2` pins two of its
eighteen requirement lines exactly, so a manifest scan would evaluate
two components where resolution yields 56.

**#39 needed no upload, and #40 did not follow from it.** The plan
treated #39 as a spike requiring SBOM uploads to the shared Nexus IQ
server, and #40 as the build that would follow a positive result.
Nexus IQ's component-details API answered the identification question
read-only, and the answer split: identification was identical — all 80
shared `policy-opa-pdp` modules matched the same way, with the same
vulnerabilities — but syft reads `go.sum`, adding 23 modules outside the
build and test graph plus the project's own CI actions, and records a
thinner dependency graph. So Go stays on `cyclonedx-gomod`, and
generalising `sbom` lost its driver once Python gained a CLI path. D25
records the evidence.

## Course check against the BRIEF

The BRIEF's strategy still holds: nothing argues for revisiting the
repository split, the lane inventory, or the `build_type` collapse.
The previous revision raised two course corrections. Neither was acted
on, and one got worse.

**1. Inline shell in the CLM lane grew rather than shrank.** The
previous revision counted ~50 lines of SBOM generation and Nexus IQ
REST upload shell and called for extraction. Since then the lane's
`run:` blocks went from 127 lines across 9 steps (v0.3.0) to 323 lines
across 15, and the file from 769 to 1,184 lines. Much of the growth is
justified validation — the checks the per-PR harness now tests — and
the Python resolution step, but the REST upload the previous revision
singled out is still inline, and no extraction has started. The
per-PR harness makes an extraction safer than it was: every step it
covers would need moving with its cases.

**2. The build↔scan interface is still the structural gap.** No
`build-artifact-action` exists. Each `build_type` still rebuilds the
project inside the scan job, and this cycle added one more
(`python`). The design below is unchanged and still unstarted.

## Open issue inventory

No issue is open. The last three closed this week:

- **#74 (PR #114).** `lfreleng-actions/test-python-submodules` nests
  three levels in one repository on one branch, each submodule pinning
  an earlier commit of the same `main`, each level carrying a distinct
  package pin and marker file. `testing.yaml` scans it through both
  lanes with `submodules: 'recursive'` and, as a negative control,
  `'true'`, then asks Nexus IQ and SonarCloud which levels reached the
  result. Each result is attributed to its own scan by the server's
  record, not the runner's clock.
- **#39 and #40 (PR #115).** See D25 and "Where the plan was wrong"
  above.

The work that remains is not a backlog of defects. It is proving what
shipped against live servers, rolling it out, and the structural
improvements below, none of which has an issue yet.

## Remaining work

```mermaid
graph TD
    I1["Provision the fixture's Sonar project and IQ application"]
    I2["Dispatch testing.yaml end to end"]
    I3["Publish v0.9.2 (#114)"]
    R1["Bump the 18 v0.3.0 callers"]
    R2["O-RAN-SC onboarding"]
    A1["Extract the Nexus IQ upload action"]
    B1["build-artifact-action"]
    B2["CLM lane artifact_name input"]
    I1 --> I2
    I2 --> R2
    A1 --> B2
    B1 --> B2
```

### Immediate — prove what already shipped

This is the most important section of the document. The credentialled
self-test has never verified the lanes it covers.

1. **Dispatch `testing.yaml` and make it pass.** It has run six times
   ever, all on 2026-07-28, before it became dispatch-only, and not
   once since. The fixture applications on the Nexus IQ server show
   the consequence: the Go and Python applications hold **zero**
   reports, and the Maven and Node applications do not exist. So none
   of its credentialled legs — including every assertion added this
   cycle — has completed a scan in its current form. The per-PR harness
   proves the lanes' logic; only a dispatch proves they reach the
   servers. The workflow runs one at a time across all refs and never
   cancels mid-flight, because every leg scans into server-side
   projects shared by every run.
2. **Provision the submodule fixture's server-side projects** before
   that dispatch: a SonarCloud project
   `lfreleng-actions_test-python-submodules` and a Nexus IQ application
   `lfreleng-actions-test-python-submodules`. Neither exists as of
   2026-09-30. The #74 legs fail at their first assertion until both
   do, naming which is missing.
3. **Settle the Nexus IQ credential.** Locally, the IQ username returns
   HTTP 401 and only the user code authenticates. CI's
   `NEXUS_IQ_USERNAME` matches neither local identity, so it is likely
   a separate service account, and only a dispatch will show whether
   it authenticates. If it does not, every CLM leg fails at the first
   request.
4. **Publish v0.9.2.** PR #114 is merged but unreleased, waiting in the
   v0.9.2 draft. It changes only the self-test, so no caller needs it,
   but tagging it keeps the released tree and the tested one the same.

### Rollout

1. **Bring the 18 v0.3.0 callers forward.** They miss D21's toolchain
   fix among everything else. The count fell from 21 in a week, so
   Dependabot is reaching some of them; the remainder may need a
   coordinated bump.
2. **O-RAN-SC onboarding**, the one estate that has not started. The
   three Python CLM projects are the first candidates, now that v0.9.0
   carries the `python` `build_type`; they will need `python_version`,
   since two resolve only under Python 3.11 (D24). Its two Sonar
   pre-scan jobs point `PRE_BUILD_SCRIPT_URL` at the `master` branch
   of `ci-management` — a mutable ref — and `prescan_script_path`
   exists to replace exactly that.
3. **Deprecate `lfit/releng-reusable-workflows`** once the ONAP and
   O-RAN-SC waves complete (BRIEF follow-up 5). OpenDaylight's Sonar
   jobs have already moved.

### Phase 2 — extract the Nexus IQ upload

D25 settled that `scan_mode: 'sbom'` stays Go-only on
`cyclonedx-gomod`, so the SBOM transport the previous revision planned
to generalise no longer needs generalising, and `go_sbom_tool_version`
stays. One part of that plan survives on its own merits: the REST
upload is the largest block of inline shell in the CLM lane, and the
course check above calls for moving it out.

1. Extract the application UUID lookup and `POST` into a composite
   action — `nexus-iq-sbom-upload-action` preferred, extending
   `sonatype-lifecycle-scan-action` acceptable if a single Nexus IQ
   surface is judged more valuable. Follow `grype-scan-action`'s
   `scripts/*.py` pattern, as `tests/scan_contents.py` does here.
2. Move the steps the per-PR harness covers with their cases, so the
   extraction cannot quietly drop a check.
3. Decide separately whether `sbom` mode should pass
   `cyclonedx-gomod mod -test`. D25 records that it omits the test-only
   modules the CLI path includes; changing it alters
   `policy-opa-pdp`'s results, so it waits on that project's agreement.

### Phase 3 — new ecosystems

1. **Node.js** — no issue; `onap/portal-ng-ui` already runs the CLM
   lane with no pre-scan build. File one only if a consumer needs more;
   `node-build-action`'s `node_modules` makes a CLI path cheap if
   fidelity demands it.

### Phase 4 — strategic: the build↔scan artefact interface

Unstarted, and still the largest structural improvement available.

1. Create `build-artifact-action` (pack/unpack) per the design below,
   in its own repository, from `actions-template`, lifting
   `docker-save-images-action` v0.2.0's validation blocks.
2. Add an optional `artifact_name` consumption path to
   `sonatype-lifecycle.yaml`, with a caller example showing a producer
   job composed with the CLM lane. The artifact branch must skip both
   checkout paths and restore into a fresh, dedicated extraction root
   (not `path_prefix` itself, which defaults to the workspace root).
   `validate` rejects `artifact_name` combined with a non-`none`
   `build_type`, since `build_type` defaults to `'none'` and strict
   mutual exclusion would break every caller omitting it.
3. Add an opt-in "publish packed workspace" step to the `*-workflows`
   build lanes, so their reusable build workflows can act as producers.
4. Adopt in the `sbom-files` hops across the `*-workflows`
   repositories opportunistically.

Phase 4 can start in parallel with Phase 2 — the write scopes are
disjoint — but its `security-workflows` integration should land after
Phase 2. Both restructure the CLM lane's scan steps, so the lane is
reworked once rather than twice.
The action must land before its CLM integration: the CLM job holds
Nexus IQ credentials and would accept another job's artifact, so
prototyping unpack there with a raw `tar` extraction would expose the
traversal surface the design exists to close.

### Outside this repository

- **`test-python-project`'s Sonar key is stale.** Its
  `sonar-project.properties` names `test-python-project`, but
  SonarCloud names auto-created projects `<organization>_<repository>`,
  and knows it only as `lfreleng-actions_test-python-project`. The
  same mistake was copied into `test-python-submodules` and corrected
  there.

## Estate research findings

### Sibling action versions

| Action                           | Previous revision | Now    |
| -------------------------------- | ----------------- | ------ |
| `sbom-action`                    | v0.0.2            | v0.2.0 |
| `python-sbom-action`             | v0.1.2            | v0.1.2 |
| `grype-scan-action`              | v0.0.1            | v0.2.0 |
| `docker-save-images-action`      | v0.2.0            | v0.2.0 |
| `build-metadata-action`          | v0.8.0            | v0.8.3 |
| `sonatype-lifecycle-scan-action` | —                 | v0.2.2 |
| `maven-xml-settings-action`      | —                 | v0.1.1 |

Neither `build-artifact-action` nor `nexus-iq-sbom-upload-action`
exists. `maven-xml-settings-action` v0.1.1 was re-tagged on
2026-09-25 after its first release failed; both lanes were repinned to
the new commit, whose action interface is unchanged.

### `sbom-action` and `python-sbom-action`

`sbom-action` is a facade over pluggable backends. `syft` performs
static analysis of lockfiles and filesystem content, covering Go,
Node.js, containers and binaries. `cyclonedx`, new since the previous
revision, drives the CycloneDX project's own build-tool plugins —
today `cyclonedx-maven-plugin`, with the Gradle plugin to join it —
because for Java the file syft reads is an input to dependency
resolution rather than its product. `cyclonedx-npm`, `cyclonedx-gomod`
and an environment-based Python backend remain planned.
`python-sbom-action` mirrors the interface and adds
`dependency_manager` detection (uv/pdm/poetry/pipenv/pip). Both emit
CycloneDX JSON and XML at caller-set spec versions and paths, and
neither uploads anywhere itself.

This lane does not adopt either. D25 found syft's Go output identifies
the same modules as `cyclonedx-gomod` but scans `go.sum` and records a
thinner graph, and `sbom-action` has no `cyclonedx-gomod` backend to
switch to. The finding would need revisiting only if one were added.

### The Nexus IQ REST upload belongs in a composite action

The UUID-lookup-and-POST shell in `sonatype-lifecycle.yaml` is
ecosystem-agnostic and will be needed by every `sbom` consumer. Two
placements are viable: extend `sonatype-lifecycle-scan-action` with an
`sbom_file` input, or create a small `nexus-iq-sbom-upload-action`.
The second fits the estate's single-responsibility pattern better and
keeps the CLI action's input surface honest, since none of its `iq_*`
gating inputs apply to an asynchronous upload.

### `build-metadata-action` is deliberately not used for Go

It emits `java_version`, Go versions and matrices,
`python_build_version`/`python_matrix_json`,
`javascript_requires_node`, and `project_type`/`build_tool`. Both lanes
use it for the JDK. For Go they deliberately do not: its
`go_go_version` output is the `go` directive alone, and D21 records
why passing it to `setup-go` was a defect. It also detects the JDK by
reading `pom.xml`, which is why `mvn_pom_file` with a non-default name
requires an explicit `java_version`.

### Artefact transport: the gap and the model

No estate action packages generic build output into an archive and
attaches it to a run; the `*-workflows` repositories hand-roll raw
`actions/upload-artifact`/`download-artifact` pairs.

`docker-save-images-action` v0.2.0 is the model for the pack half:
`mode: 'single' | 'per-image'`, `artifact-name`, `output-directory`,
`retention-days`, `overwrite` and `fail-on-empty` inputs; outputs for
the archive count, directory and paths; and hardened validation worth
lifting verbatim — strict booleans, allowlisted artifact names and
output paths, symlink-aware workspace containment checked before and
after `mkdir`, refusal to write through symlinks, collision detection
on slugged filenames, and uploading an explicit written-paths list so
pre-existing files are never swept in. It still lacks the
download/load counterpart.

**Proposal: `build-artifact-action`**, one composite action with
`mode: pack | unpack`, following `actions-template` conventions:

- **pack:** `paths`, `path_prefix`, a required `artifact-name`,
  `retention-days` (default 1), `fail-on-empty` (default `true`) and
  `overwrite`; tar-based so permissions and symlinks survive the
  artifact zip envelope. Pack adds **source containment** — every
  matched path, and every symlink target it resolves through, must sit
  inside `path_prefix` before the tar is written — and guards
  **credential leakage**, excluding `.git/` by default, because
  `actions/checkout` persists its token until post-job cleanup unless
  `persist-credentials: false` is set.
- **unpack:** `artifact-name` and a destination `path`, with **safe
  extraction**: entries with absolute or parent-traversal paths, and
  link targets resolving outside the destination, fail the step; and
  because member checks alone do not stop `tar` following a link
  already present below the destination, the extraction root must be
  newly created and empty. Pattern-based fan-in is out of v0.1 scope,
  since `download-artifact` is last-writer-wins for duplicate
  filenames under `merge-multiple: true`. Scope is same-run hand-offs
  only.

Docker image archives are not a consumer: they must stay intact and be
imported with `docker load`, which belongs beside
`docker-save-images-action`.

### `grype-scan-action` validates the scoping rule

`grype-scan-action` (now v0.2.0) replaces duplicated Grype shell
across the `*-workflows` families with a composite that scans SBOM
files or a Grype target reference, including `docker-archive:`. It
confirms rather than changes the BRIEF's scoping rule: SBOM and Grype
jobs stay in the `*-workflows` verify lanes, and no new lane belongs
here. Its `scripts/*.py` layout — logic too complex for bash in a
typed helper invoked from a thin step — is the template for the Nexus
IQ upload extraction, and `tests/scan_contents.py` follows it for this
repository's own submodule assertion. Reuse across action
repositories is by borrowing idioms, not shared code.

## Risks and open decisions

- **The credentialled self-test is unproven.** Every assertion added
  this cycle against a live server — the Go toolchain check, coverage
  forwarding, the submodule legs — has only ever been exercised
  offline or not at all. Until `testing.yaml` passes end to end, the
  lanes' behaviour against Nexus IQ and SonarCloud is inferred, not
  observed. This is the highest-priority item in the document.
- **The submodule legs depend on provisioning.** They need a
  SonarCloud project and a Nexus IQ application that do not exist yet,
  and fail loudly, naming the missing one, until both do. The first
  dispatch should not be read as a lane regression if they are absent.
- **Pin drift in the estate.** A security fix released here reaches
  only the callers that bump. With 18 calls on v0.3.0, the effective
  security posture of the estate lags the repository by a cycle.
- **Inline shell keeps growing.** Each new capability has added to
  `sonatype-lifecycle.yaml`. The per-PR harness contains the risk but
  not the size; the Nexus IQ upload extraction is the natural first
  cut.
- **Dependency on v0.x sibling actions.** `grype-scan-action` (v0.2.0)
  and the SBOM actions are young. Borrow their idioms; do not couple to
  unreleased pins; re-check each interface before Phase 2 and Phase 4
  review.
