#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Checks that nothing in the job's environment chooses the interpreter
# uv runs in sonatype-lifecycle.yaml's Python lane. setup-uv runs the
# interpreter 'uv python find' returns, and 'uv venv' without an
# absolute --python takes one from PATH, UV_PYTHON and similar
# variables, which any earlier step can set through GITHUB_ENV or
# GITHUB_PATH. The lane disables setup-uv's lookup, installs Python
# with uv under 'env -i', and hands the absolute path on.
#
# It follows tests/workflow-steps.sh: yq extracts each run block, and
# bash runs it with GitHub's 'shell: bash' flags under an emptied
# environment, with a stub uv that records how it was called. It lives
# in its own file because that harness is an executable file this
# change could not edit.
#
# Usage: bash tests/uv-interpreter-steps.sh    (needs mikefarah yq v4)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

clm='sonatype-lifecycle.yaml'
clm_file="${root}/.github/workflows/${clm}"
cases=0
failures=0
script=''
dir="${work}"
match=''

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/uv-interpreter-steps.sh needs mikefarah yq v4' >&2
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

# expect <pass|fail> <label> [VAR=value ...]: runs $script in $dir.
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

not_grep() { ! grep -q -- "$1" "$2" 2> /dev/null; }

# field <step name> <yq path>: prints that field of a scan job step.
field() {
  NAME="$1" yq ".jobs.scan.steps[] | select(.name == strenv(NAME)) | $2" \
    "${clm_file}"
}

# The literal expressions, which the shell must not expand
temp="\${{ runner.temp }}"
install_dir="${temp}/uv-python"

echo '== setup-uv cannot run an interpreter (sonatype-lifecycle scan)'
for var in UV_NO_CONFIG UV_NO_PROJECT; do
  check "Setup uv sets ${var}" test \
    "$(field 'Setup uv' ".env.${var}")" = 1
done
check '  and an invalid UV_PYTHON_PREFERENCE, so uv looks nothing up' test \
  "$(field 'Setup uv' '.env.UV_PYTHON_PREFERENCE')" = 'lookup-disabled'
check '  and clears UV_PYTHON_ARCH' test \
  "$(field 'Setup uv' '.env | has("UV_PYTHON_ARCH")')" = true
check '  to the empty string' test \
  "$(field 'Setup uv' '.env.UV_PYTHON_ARCH')" = ''
check '  and pins UV_PYTHON_INSTALL_DIR under runner.temp' test \
  "$(field 'Setup uv' '.env.UV_PYTHON_INSTALL_DIR')" = "${install_dir}"
check '  with tool-bin-dir under runner.temp' test \
  "$(field 'Setup uv' '.with["tool-bin-dir"]')" = "${temp}/uv-tool-bin"
check '  with the cache off' test \
  "$(field 'Setup uv' '.with["enable-cache"]')" = false
check '  and no python-version, which would export UV_PYTHON' test \
  "$(field 'Setup uv' '.with | has("python-version")')" = false
check '  and an id for its uv-path output' test \
  "$(field 'Setup uv' '.id')" = 'setup-uv'

names="$(yq '.jobs.scan.steps[].name' "${clm_file}")"
at() { printf '%s\n' "${names}" | grep -nxF -- "$1" | cut -d: -f1; }
install_at="$(at 'Install Python' || true)"
check 'Install Python runs after Setup uv' test \
  "${install_at:-0}" -gt "$(at 'Setup uv')"
check '  and before Resolve Python dependencies' test \
  "${install_at:-0}" -lt "$(at 'Resolve Python dependencies')"
check '  in runner.temp, outside the checkout' test \
  "$(field 'Install Python' '."working-directory"')" = "${temp}"
check "  only when build_type is 'python'" test \
  "$(field 'Install Python' '.if')" = "inputs.build_type == 'python'"
check '  runs setup-uv by path' test \
  "$(field 'Install Python' '.env.UV')" \
  = "\${{ steps.setup-uv.outputs.uv-path }}"
check '  installs where setup-uv was told to' test \
  "$(field 'Install Python' '.env.INSTALL_DIR')" = "${install_dir}"
check '  and takes python_version through env' test \
  "$(field 'Install Python' '.env.PYTHON_VERSION')" \
  = "\${{ inputs.python_version }}"
check '  with an id for its path output' test \
  "$(field 'Install Python' '.id')" = 'python'
# Without the mapping, the PYTHON:- fallback in the resolve step would
# silently let uv choose again.
check 'Resolve Python dependencies maps PYTHON from Install Python' test \
  "$(field 'Resolve Python dependencies' '.env.PYTHON')" \
  = "\${{ steps.python.outputs.path }}"

echo '== Install Python (sonatype-lifecycle scan)'
step "${clm}" scan 'Install Python'
mkdir -p "${work}/stub-bin" "${work}/ws/proj" "${work}/runner"
installs="${work}/uv-python"
# The stub records each call's arguments and environment, then answers
# 'python find' with the path in ${work}/find-answer.
sed "s|@WORK@|${work}|g" > "${work}/stub-bin/uv" << 'STUB'
#!/bin/sh
printf '%s\n' "$*" >> '@WORK@/uv-calls'
env | sort > '@WORK@/uv-env'
if [ "$2" = find ]; then
  cat '@WORK@/find-answer'
fi
STUB
chmod +x "${work}/stub-bin/uv"

# install <label> <pass|fail> [VAR=value ...]: runs the step with the
# stub; the project is ${work}/ws/proj.
install() {
  local want="$1" label="$2"
  shift 2
  rm -f "${work}/uv-calls" "${work}/uv-env" "${work}/output"
  dir="${work}/runner"
  expect "${want}" "${label}" UV="${work}/stub-bin/uv" \
    INSTALL_DIR="${installs}" RUNNER_TEMP="${work}" \
    GITHUB_WORKSPACE="${work}/ws" PATH_PREFIX=proj \
    GITHUB_OUTPUT="${work}/output" "$@"
  dir="${work}"
}
requested() {
  grep -qxF -- "python install --quiet --no-bin -- $1" "${work}/uv-calls" \
    && grep -qxF -- "python find --managed-python --system -- $1" \
      "${work}/uv-calls"
}

printf '%s\n' "${installs}/cpython-3.12/bin/python3.12" > "${work}/find-answer"
printf '%s\n' '[project]' 'name = "p"' 'requires-python = ">=3.10,<3.13"' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'installs python_version when set' PYTHON_VERSION=3.11 \
  UV_PYTHON=/bait/python VIRTUAL_ENV=/bait CONDA_PREFIX=/bait
check '  requesting it from uv' requested 3.11
check '  under env -i, so UV_PYTHON does not reach uv' \
  not_grep '^UV_PYTHON=' "${work}/uv-env"
check '  nor VIRTUAL_ENV or CONDA_PREFIX' \
  not_grep '^\(VIRTUAL_ENV\|CONDA_PREFIX\)=' "${work}/uv-env"
check '  nor PATH' not_grep '^PATH=' "${work}/uv-env"
check '  with the install directory set' \
  grep -qxF -- "UV_PYTHON_INSTALL_DIR=${installs}" "${work}/uv-env"
check '  and outputs the absolute interpreter' grep -qxF -- \
  "path=${installs}/cpython-3.12/bin/python3.12" "${work}/output"

install pass 'requests requires-python when python_version is empty' \
  PYTHON_VERSION=''
check '  as written in pyproject.toml' requested '>=3.10,<3.13'

printf '%s\n' '[project]' "requires-python = '>=3.9'" '' \
  '[tool.other]' 'requires-python = "==2.7"' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'reads a single-quoted requires-python' PYTHON_VERSION=''
check '  from [project], not another table' requested '>=3.9'

printf '%s\n' '[project]' 'requires-python = """>=3.10,<3.13"""' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'reads a multi-line basic string' PYTHON_VERSION=''
check '  as its value' requested '>=3.10,<3.13'

printf '%s\n' '[project]' '"requires-python" = ">=3.11"' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'reads a quoted key' PYTHON_VERSION=''
check '  as its value' requested '>=3.11'

printf '%s\n' 'project.requires-python = ">=3.12"' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'reads a dotted key' PYTHON_VERSION=''
check '  as its value' requested '>=3.12'

printf '%s\n' '[tool.other]' 'requires-python = "==2.7"' \
  > "${work}/ws/proj/pyproject.toml"
install pass 'falls back to 3.13 without requires-python in [project]' \
  PYTHON_VERSION=''
check '  requesting 3.13' requested 3.13

printf '%s\n' '[project]' 'name = "p"' > "${work}/ws/proj/pyproject.toml"
install pass 'falls back to 3.13 when [project] has no requires-python' \
  PYTHON_VERSION=''
check '  requesting 3.13' requested 3.13

printf '%s\n' '[project' 'requires-python = ">=3.10"' \
  > "${work}/ws/proj/pyproject.toml"
match='::error::could not parse proj/pyproject.toml as TOML'
install fail 'fails on a pyproject.toml that is not valid TOML' \
  PYTHON_VERSION=''
check '  without asking uv for anything' test ! -e "${work}/uv-calls"

# The Python yq wrapper (kislyuk) shares the name and not the syntax
mkdir -p "${work}/other-yq"
printf '%s\n' '#!/bin/sh' 'echo "yq 3.4.3"' > "${work}/other-yq/yq"
chmod +x "${work}/other-yq/yq"
printf '%s\n' '[project]' 'requires-python = ">=3.10"' \
  > "${work}/ws/proj/pyproject.toml"
match='::error::reading requires-python needs mikefarah yq v4'
install fail 'fails clearly when yq is not mikefarah v4' PYTHON_VERSION='' \
  PATH="${work}/other-yq:${PATH}"

rm -f "${work}/ws/proj/pyproject.toml"
install pass 'falls back to 3.13 without a pyproject.toml' PYTHON_VERSION=''
check '  requesting 3.13' requested 3.13

printf '%s\n' '/usr/bin/python3' > "${work}/find-answer"
match='::error::uv found Python outside its install directory'
install fail 'rejects an interpreter outside the install directory' \
  PYTHON_VERSION=3.12
check '  without outputting it' not_grep '^path=' "${work}/output"

echo '== Resolve Python dependencies passes the interpreter by path'
step "${clm}" scan 'Resolve Python dependencies'
mkdir -p "${work}/py-req"
printf 'six==1.16.0\n' > "${work}/py-req/requirements.txt"
printf '%s\n' '#!/bin/sh' "printf '%s\n' \"\$@\" > '${work}/venv-args'" \
  'exit 3' > "${work}/stub-bin/uv"
dir="${work}/py-req"
expect fail 'stops at the stubbed uv' RUNNER_TEMP="${work}" \
  PYTHON=/opt/py/bin/python3 PATH="${work}/stub-bin:${PATH}"
dir="${work}"
check '  which it ran as uv venv' test \
  "$(head -n 1 "${work}/venv-args" 2> /dev/null)" = venv
check '  with --python' grep -qxF -- '--python' "${work}/venv-args"
check '  naming that interpreter' test \
  "$(grep -xF -A1 -- '--python' "${work}/venv-args" | tail -n 1)" \
  = /opt/py/bin/python3
check '  and --no-config' grep -qxF -- '--no-config' "${work}/venv-args"
# uv export needs PyPI, so its arguments are checked as written
check 'uv export takes --no-config' grep -qF \
  -- "uv export --quiet --locked --no-config \\" "${script}"
check '  and the same --python' grep -qF \
  -- "\"\${python_args[@]}\" --format requirements-txt \\" "${script}"

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
