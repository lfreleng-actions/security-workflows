#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Executes sonatype-lifecycle.yaml's 'Check for an unresolved Python
# project' step, lifted verbatim from the workflow, against generated
# project directories. It follows tests/workflow-steps.sh exactly: yq
# extracts the run block, and bash runs it with GitHub's 'shell: bash'
# flags under an emptied environment. It lives in its own file only
# because that harness is an executable file this change could not
# edit; folding these cases into it is a mechanical follow-up.
#
# Usage: bash tests/python-warning-steps.sh    (needs mikefarah yq v4)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

clm='sonatype-lifecycle.yaml'
cases=0
failures=0
script=''
dir="${work}/runner"
prefix=''
match=''
mkdir -p -- "${dir}"

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/python-warning-steps.sh needs mikefarah yq v4' >&2
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

# expect <pass|fail> <label> [VAR=value ...]: runs $script in $dir,
# which is not the project: the step must enter PATH_PREFIX itself.
# When $match is set, the output must also contain it.
expect() {
  local want="$1" label="$2" got
  shift 2
  cases=$((cases + 1))
  if (cd -- "${dir}" && env -i PATH="${PATH}" HOME="${HOME}" "$@" \
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

no_warning() { ! grep -qF -- '::warning' "${work}/out"; }

# project <name> <file...>: creates a project directory holding empty
# files of those names and makes it $prefix, the step's PATH_PREFIX.
project() {
  prefix="${work}/$1"
  shift
  mkdir -p -- "${prefix}"
  local name
  for name in "$@"; do
    : > "${prefix}/${name}"
  done
}

echo '== unresolved Python project warning (sonatype-lifecycle scan)'
step "${clm}" scan 'Check for an unresolved Python project'
annotation='::warning title=Python dependencies not resolved::'

warns() {
  local label="$1"
  shift
  project "$@"
  : > "${work}/summary"
  match="${annotation}"
  expect pass "warns, and passes, for ${label}" PATH_PREFIX="${prefix}" \
    SCAN_TARGETS=. GITHUB_STEP_SUMMARY="${work}/summary"
  check '  recommends build_type python' \
    grep -qF -- "Set build_type: 'python', with python_version" "${work}/out"
  check '  repeats the warning in the step summary' \
    grep -qF -- "Set build_type: 'python'" "${work}/summary"
}
warns 'uv.lock and pyproject.toml' py-uv uv.lock pyproject.toml
check '  names both files found' \
  grep -qF -- 'Found pyproject.toml, uv.lock with' "${work}/out"
warns 'pyproject.toml alone' py-pyproject pyproject.toml
check '  names the file found' \
  grep -qF -- 'Found pyproject.toml with' "${work}/out"
warns 'requirements.txt alone' py-requirements requirements.txt
check "  says only '==' lines of requirements.txt are read" \
  grep -qF -- "reads only the '==' lines of requirements.txt" "${work}/out"
warns 'setup.py alone' py-setup setup.py
warns 'setup.cfg alone' py-setupcfg setup.cfg

quiet() {
  local label="$1" targets="$2"
  shift 2
  project "$@"
  expect pass "passes without a warning for ${label}" \
    PATH_PREFIX="${prefix}" SCAN_TARGETS="${targets}"
  check '  emits no ::warning' no_warning
}
quiet 'pyproject.toml with poetry.lock' . py-poetry pyproject.toml \
  poetry.lock
quiet 'Pipfile.lock' . py-pipenv Pipfile Pipfile.lock
quiet 'an empty directory' . py-empty
quiet "scan_targets other than '.'" dist py-targets pyproject.toml uv.lock

project py-nosummary pyproject.toml
match="${annotation}"
expect pass 'warns without a step summary file' PATH_PREFIX="${prefix}" \
  SCAN_TARGETS=.

expect pass 'passes when PATH_PREFIX does not exist' \
  PATH_PREFIX="${work}/no-such-dir" SCAN_TARGETS=.
check '  emits no ::warning' no_warning
project py-relative pyproject.toml uv.lock
dir="${prefix}"
match="${annotation}"
expect pass "warns for the default PATH_PREFIX '.'" PATH_PREFIX=. \
  SCAN_TARGETS=.
dir="${work}"

clm_file="${root}/.github/workflows/${clm}"
check "runs only when build_type is 'none'" test \
  "$(yq '.jobs.scan.steps[]
    | select(.name == "Check for an unresolved Python project") | .if' \
    "${clm_file}")" = "inputs.build_type == 'none'"
# GitHub fails a step whose working directory is missing before its
# script runs, so the step must enter path_prefix itself.
check 'sets no working-directory' test \
  "$(yq '.jobs.scan.steps[]
    | select(.name == "Check for an unresolved Python project")
    | ."working-directory"' "${clm_file}")" = 'null'
# The literal expression, which the shell must not expand.
expected_prefix="\${{ inputs.path_prefix }}"
check 'passes path_prefix through env' test \
  "$(yq '.jobs.scan.steps[]
    | select(.name == "Check for an unresolved Python project")
    | .env.PATH_PREFIX' "${clm_file}")" = "${expected_prefix}"
clm_names="$(yq '.jobs.scan.steps[].name' "${clm_file}")"
clm_at() { printf '%s\n' "${clm_names}" | grep -nxF -- "$1" | cut -d: -f1; }
warn_at="$(clm_at 'Check for an unresolved Python project')"
check 'warns after the plain checkout' test "${warn_at}" -gt \
  "$(clm_at 'Checkout repository')"
check 'warns after the Gerrit checkout' test "${warn_at}" -gt \
  "$(clm_at 'Checkout Gerrit change')"
check 'warns before the scan' test "${warn_at}" -lt \
  "$(clm_at 'Sonatype Lifecycle scan')"

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
