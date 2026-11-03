#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Executes sonarqube-cloud.yaml's tox steps, lifted verbatim from the
# workflow, against generated inputs: the 'Validate tox inputs' check
# and the 'Plan tox Python' step that keeps callers on Python older
# than 3.11 working with tox-run-action v1. It follows
# tests/workflow-steps.sh exactly: yq extracts the run block, and bash
# runs it with GitHub's 'shell: bash' flags under an emptied
# environment. It lives in its own file only because that harness is
# an executable file this change could not edit.
#
# It also checks that the 'tox-python' job of workflow-tests.yaml,
# which runs these steps for real against a fixture project, wires
# tox-run-action exactly as the lane does.
#
# Usage: bash tests/tox-python-steps.sh    (needs mikefarah yq v4)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

sonar='sonarqube-cloud.yaml'
sonar_file="${root}/.github/workflows/${sonar}"
tests_file="${root}/.github/workflows/workflow-tests.yaml"
cases=0
failures=0
script=''
match=''

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/tox-python-steps.sh needs mikefarah yq v4' >&2
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

# expect <pass|fail> <label> [VAR=value ...]: runs $script with a fresh
# GITHUB_OUTPUT and GITHUB_STEP_SUMMARY. When $match is set, the
# output must also contain it.
expect() {
  local want="$1" label="$2" got
  shift 2
  cases=$((cases + 1))
  : > "${work}/github_output"
  : > "${work}/summary"
  if (cd -- "${work}" && env -i PATH="${PATH}" HOME="${HOME}" \
    GITHUB_OUTPUT="${work}/github_output" \
    GITHUB_STEP_SUMMARY="${work}/summary" "$@" \
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

no_outputs() { ! [ -s "${work}/github_output" ]; }
no_warning() { ! grep -qF -- '::warning' "${work}/out"; }
outputs_are() { diff -u -- - "${work}/github_output" > /dev/null; }

echo '== tox_envs and tox_parallel (sonarqube-cloud validate)'
step "${sonar}" validate 'Validate tox inputs'
expect pass 'accepts the defaults' TOX_ENVS= TOX_PARALLEL=auto
expect pass 'accepts one environment' TOX_ENVS=py312 TOX_PARALLEL=
expect pass 'accepts environments with dots, dashes and plus signs' \
  TOX_ENVS='py3.12-cov,lint+x,_x' TOX_PARALLEL=off
for parallel in auto all off 4 ''; do
  expect pass "accepts tox_parallel '${parallel}'" TOX_ENVS= \
    TOX_PARALLEL="${parallel}"
done
for envs in 'py312, lint' 'py312 lint' 'py312,' ',py312' '--notest' \
  'py312,-x' 'py3 12'; do
  match='tox_envs must be environment names'
  expect fail "rejects tox_envs '${envs}'" TOX_ENVS="${envs}" \
    TOX_PARALLEL=auto
done
for parallel in 'yes' '-1' '4 --notest' 'auto,4' '1.5'; do
  match="tox_parallel must be"
  expect fail "rejects tox_parallel '${parallel}'" TOX_ENVS= \
    TOX_PARALLEL="${parallel}"
done
check "runs only when build_type is 'tox'" test \
  "$(yq '.jobs.validate.steps[]
    | select(.name == "Validate tox inputs") | .if' "${sonar_file}")" \
  = "inputs.build_type == 'tox'"

echo '== Python for tox (sonarqube-cloud scan)'
step "${sonar}" scan 'Plan tox Python'

for version in '' '3.11' '3.11.9' '3.12.12' '3.13.0-rc.2' '3.14t' \
  '4.0.0' 'pypy3.10.16' 'not a version'; do
  expect pass "leaves '${version}' unchanged" RESOLVED_PYTHON="${version}"
  check '  writes no outputs' no_outputs
  check '  emits no ::warning' no_warning
done

old() {
  local version="$1" spec="$2"
  match="::warning title=tox runs on Python 3.13::"
  expect pass "splits tox from environments for ${version}" \
    RESOLVED_PYTHON="${version}"
  check '  lists the caller Python first and 3.13 last' outputs_are <<EOF
versions<<TOX_PYTHON_VERSIONS
${version}
3.13
TOX_PYTHON_VERSIONS
override=testenv.default_base_python=${spec}
EOF
  check '  names the requested Python in the warning' \
    grep -qF -- "requested Python ${version}, which has reached end" \
    "${work}/out"
  check '  repeats the warning in the step summary' \
    grep -qF -- 'tox runs on Python 3.13, as it needs 3.11' \
    "${work}/summary"
}
old '3.10.18' 'python3.10'
old '3.10' 'python3.10'
old '3.9.23' 'python3.9'
old '3.8.18' 'python3.8'

# A version carrying a newline would forge a second output line.
expect pass 'leaves a multi-line version unchanged' \
  RESOLVED_PYTHON=$'3.10.1\noverride=x'
check '  writes no outputs' no_outputs

echo '== tox-run-action wiring (sonarqube-cloud scan)'
# with <file> <job> <step> <expression prefix>: the step's uses, with
# and env, with that prefix replaced by 'input.' so the lane and the
# test job compare equal.
wiring() {
  JOB="$2" NAME="$3" yq '.jobs[strenv(JOB)].steps[]
    | select(.name == strenv(NAME))
    | {"uses": .uses, "with": .with, "env": .env}' "$1" \
    | sed "s/$4\./input./g"
}
for name in 'Resolve tox Python' 'Plan tox Python' 'Tox run'; do
  lane="$(wiring "${sonar_file}" scan "${name}" inputs)"
  test_job="$(wiring "${tests_file}" tox-python "${name}" matrix)"
  check "workflow-tests.yaml wires '${name}' as the lane does" \
    test "${lane}" = "${test_job}"
done
scan_step() {
  NAME="$1" FIELD="$2" yq '.jobs.scan.steps[]
    | select(.name == strenv(NAME)) | .[strenv(FIELD)]' "${sonar_file}"
}
check 'resolves the caller Python for every tox build' test \
  "$(scan_step 'Resolve tox Python' if)" = "inputs.build_type == 'tox'"
check 'build_permit_fail covers resolving the caller Python' test \
  "$(scan_step 'Resolve tox Python' continue-on-error)" \
  = "$(scan_step 'Tox run' continue-on-error)"
check "plans only when build_type is 'tox'" test \
  "$(scan_step 'Plan tox Python' if)" = "inputs.build_type == 'tox'"
scan_names="$(yq '.jobs.scan.steps[].name' "${sonar_file}")"
scan_at() { printf '%s\n' "${scan_names}" | grep -nxF -- "$1" | cut -d: -f1; }
check 'resolves, then plans, then runs tox' test \
  "$(scan_at 'Resolve tox Python')" -lt "$(scan_at 'Plan tox Python')" \
  -a "$(scan_at 'Plan tox Python')" -lt "$(scan_at 'Tox run')"

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
