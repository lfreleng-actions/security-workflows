#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Covers how sonatype-lifecycle.yaml carries the scan action's results:
# the scan_summary input's validation, its route to the action, the
# scan step's outputs up to the workflow, and the job summary the
# 'sbom' path writes in the action's place. It follows
# tests/workflow-steps.sh exactly: yq extracts each run block, and bash
# runs it with GitHub's 'shell: bash' flags under an emptied
# environment. It lives in its own file only because that harness is an
# executable file this change could not edit; folding these cases into
# it is a mechanical follow-up.
#
# Usage: bash tests/scan-summary-steps.sh    (needs mikefarah yq v4)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

clm='sonatype-lifecycle.yaml'
clm_file="${root}/.github/workflows/${clm}"
cases=0
failures=0
script=''
match=''

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/scan-summary-steps.sh needs mikefarah yq v4' >&2
  exit 2
fi

# step <workflow> <job> <step name>: sets $script to the step's run block.
step() {
  local file="${root}/.github/workflows/$1" marker
  script="${work}/$(printf '%s' "$1-$2-$3" | tr -c 'A-Za-z0-9' '_').sh"
  if ! JOB="$2" NAME="$3" yq -e \
    '.jobs[strenv(JOB)].steps[] | select(.name == strenv(NAME)) | .run' \
    "${file}" > "${script}" 2> /dev/null; then
    echo "::error::no run step '$3' in job '$2' of $1" >&2
    exit 2
  fi
  marker="\${{"
  if grep -qF -- "${marker}" "${script}"; then
    echo "::error::step '$3' interpolates an expression in its run" \
      "block; move it to env: so it can be tested" >&2
    exit 2
  fi
}

# expect <pass|fail> <label> [VAR=value ...]: runs $script in $work.
# When $match is set, the output must also contain it, so a case
# rejected for the wrong reason does not count as rejected.
expect() {
  local want="$1" label="$2" got
  shift 2
  cases=$((cases + 1))
  if (cd -- "${work}" && env -i PATH="${PATH}" HOME="${HOME}" "$@" \
    bash --noprofile --norc -eo pipefail "${script}") \
    > "${work}/out" 2>&1; then
    got=pass
  else
    got=fail
  fi
  if [ "${got}" = "${want}" ] \
    && { [ -z "${match}" ] || grep -qF -- "${match}" "${work}/out"; }; then
    printf '  ok    %s\n' "${label}"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s (wanted %s, got %s%s)\n' "${label}" "${want}" \
      "${got}" "${match:+, expecting \"${match}\"}"
    sed 's/^/        | /' "${work}/out"
  fi
  match=''
}

# check <label> <command...>: a plain assertion about state.
check() {
  local label="$1"
  shift
  cases=$((cases + 1))
  if "$@"; then
    printf '  ok    %s\n' "${label}"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s\n' "${label}"
  fi
}

# q <expression>: evaluates a yq expression against the lane.
q() { yq "$1" "${clm_file}"; }

echo '== scan_summary input (sonatype-lifecycle gerrit-validate)'
check "the input defaults to 'outcome'" test \
  "$(q '.on.workflow_call.inputs.scan_summary.default')" = outcome
step "${clm}" gerrit-validate 'Validate scan_summary input'
for value in outcome full none; do
  expect pass "accepts '${value}'" SCAN_SUMMARY="${value}"
done
for value in '' Full 'outcome ' summary 'full;none'; do
  match="scan_summary must be 'outcome', 'full' or 'none'"
  expect fail "rejects '${value}'" SCAN_SUMMARY="${value}"
done
check '  with no if:, so it always runs' test "$(q '.jobs.gerrit-validate.steps[]
  | select(.name == "Validate scan_summary input") | has("if")')" = false

echo '== scan step wiring (sonatype-lifecycle scan)'
scan_step='.jobs.scan.steps[] | select(.name == "Sonatype Lifecycle scan")'
scan_id="$(q "${scan_step} | .id")"
check "the scan step has an id ('${scan_id}')" test "${scan_id}" != null
check 'it pins the action by a full commit SHA' grep -qE \
  '^lfreleng-actions/sonatype-lifecycle-scan-action@[0-9a-f]{40}$' \
  <(q "${scan_step} | .uses")
check 'it passes scan_summary to the action as summary' test \
  "$(q "${scan_step} | .with.summary")" = "\${{ inputs.scan_summary }}"

# output <workflow output> <action output>: the value climbs from the
# scan step to the job, and from the job to the workflow, unchanged.
output() {
  local job want
  job="$(NAME="$1" q '.jobs.scan.outputs[strenv(NAME)]')"
  want="\${{ steps.${scan_id}.outputs.$2 }}"
  check "job output $1 reads the scan step's $2" test "${job}" = "${want}"
  check "  and workflow output $1 reads the job's" test \
    "$(NAME="$1" q '.on.workflow_call.outputs[strenv(NAME)].value')" \
    = "\${{ jobs.scan.outputs.$1 }}"
  check '  and its description says it is data for env:' grep -qF \
    'never expand it in a run: block' \
    <(NAME="$1" q '.on.workflow_call.outputs[strenv(NAME)].description')
}
output scan_id scan_id
output report_url report_url
output result_category cli_exit_category

echo '== sbom summary (sonatype-lifecycle scan)'
summary_step='.jobs.scan.steps[] | select(.name == "Summarise Go SBOM upload")'
upload_step='.jobs.scan.steps[]
  | select(.name == "Upload Go SBOM to Nexus IQ (REST API)")'
check 'it runs exactly when the SBOM upload does' test \
  "$(q "${summary_step} | .if")" = "$(q "${upload_step} | .if")"
check '  and is not handed the Nexus IQ password' test \
  "$(q "${summary_step} | .env | to_entries[] | .value
    | select(test(\"secrets\\.\"))" | wc -l)" = 0
names="$(q '.jobs.scan.steps[].name')"
at() { printf '%s\n' "${names}" | grep -nxF -- "$1" | cut -d: -f1; }
check '  after the upload' test "$(at 'Summarise Go SBOM upload')" -gt \
  "$(at 'Upload Go SBOM to Nexus IQ (REST API)')"

step "${clm}" scan 'Summarise Go SBOM upload'
summary="${work}/summary.md"
: > "${summary}"
expect pass 'writes a section to the job summary' \
  GITHUB_STEP_SUMMARY="${summary}" PUBLIC_ID='onap-policy-opa-pdp'
check '  headed as the SBOM upload' grep -qxF '### Nexus IQ SBOM upload' \
  "${summary}"
check '  naming the application' grep -qF "\`onap-policy-opa-pdp\`" \
  "${summary}"
check '  and saying Nexus IQ evaluates it asynchronously' grep -qF \
  'evaluates it asynchronously' "${summary}"
check '  with the result on the server' grep -qF \
  'the result is on the Nexus IQ server' "${summary}"
: > "${summary}"
expect pass 'keeps a backtick in the id inside its code span' \
  GITHUB_STEP_SUMMARY="${summary}" PUBLIC_ID='a`b'
check '  by dropping it' grep -qF "\`ab\`" "${summary}"
expect pass 'passes with no job summary to write to' PUBLIC_ID='x'

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
