#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Executes steps lifted verbatim from the lanes' workflow files against
# generated inputs, so the validation and hook logic that gates every
# scan is exercised on each pull request rather than only on a
# credentialled dispatch of testing.yaml.
#
# Why extract rather than duplicate: a copy of a step tests the copy.
# yq pulls each step's run block out of the workflow as GitHub would
# see it, and bash runs it with the flags GitHub uses for 'shell: bash'
# (--noprofile --norc -eo pipefail), under an emptied environment so
# nothing leaks in from the caller's shell. A step that is renamed or
# removed fails the harness instead of being skipped.
#
# Why not testing.yaml: asserting that a lane REJECTS an input means
# asserting that a job fails, and 'continue-on-error' is not available
# on a job calling a reusable workflow, so a failing leg fails the whole
# run. Steps that only read their env are testable here instead.
#
# Usage: tests/workflow-steps.sh    (needs mikefarah yq v4 and bash)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

sonar='sonarqube-cloud.yaml'
clm='sonatype-lifecycle.yaml'
cases=0
failures=0
script=''
dir="${work}"
match=''

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/workflow-steps.sh needs mikefarah yq v4' >&2
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
  # An expression left in a run block would be interpolated by GitHub
  # before bash saw it, so this harness could not reproduce it.
  marker="\${{"
  if grep -qF -- "${marker}" "${script}"; then
    echo "::error::step '$3' interpolates an expression in its run" \
      "block; move it to env: so it can be tested" >&2
    exit 2
  fi
}

# expect <pass|fail> <label> [VAR=value ...]: runs $script in $dir.
# When $match is set, the output must also contain it, so a case
# rejected for the wrong reason does not count as rejected.
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

echo '== pre-scan hook combination (sonarqube-cloud validate)'
step "${sonar}" validate 'Validate pre-scan hook combination'
hooks() { expect "$1" "$2" BUILD_TYPE="$3" BUILD_WRAPPER_URL="$4" \
  PRESCAN_SCRIPT_URL="$5" PRESCAN_SCRIPT_PATH="$6"; }
hooks pass 'no hook at all' none '' '' ''
hooks pass 'prescan_script_url alone' none '' 'https://x/s.sh' ''
hooks pass 'build_wrapper_url alone' none 'https://x/w' '' ''
hooks pass 'prescan_script_path alone' none '' '' 'scripts/prescan.sh'
match='mutually exclusive'
hooks fail 'path with url' none '' 'https://x/s.sh' 'scripts/p.sh'
match='mutually exclusive'
hooks fail 'path with wrapper' none 'https://x/w' '' 'scripts/p.sh'
match='mutually exclusive'
hooks fail 'url with wrapper' none 'https://x/w' 'https://x/s.sh' ''
match='cannot combine'
hooks fail 'path with build_type maven' maven '' '' 'scripts/p.sh'
match='must be relative'
hooks fail 'absolute path' none '' '' '/abs/p.sh'
for bad in '..' '../p.sh' 'x/../p.sh' 'x/..'; do
  match="'..' segment"
  hooks fail "traversal '${bad}'" none '' '' "${bad}"
done
hooks pass "two dots inside a name ('setup..sh')" none '' '' 'x/setup..sh'

echo '== Maven POM inputs (both lanes answer alike)'
for lane in "${sonar}:validate:Validate Maven POM inputs" \
  "${clm}:gerrit-validate:Validate mvn_pom_file input"; do
  IFS=: read -r file job name <<< "${lane}"
  echo "-- ${file}"
  step "${file}" "${job}" "${name}"
  pom() { expect "$1" "$2" MVN_POM_FILE="$3" JAVA_VERSION="$4"; }
  pom pass 'unset' '' ''
  pom pass 'pom.xml needs no java_version' 'pom.xml' ''
  pom pass 'alternate POM with java_version' 'alt-build_2.xml' '17'
  pom pass "two dots inside a name ('pom..xml')" 'pom..xml' '17'
  match='requires java_version'
  pom fail 'alternate POM without java_version' 'alt.xml' ''
  for bad in 'sub/alt.xml' 'alt*.xml' "\$GITHUB_WORKSPACE.xml" 'a b.xml'; do
    match='only letters'
    pom fail "rejects '${bad}'" "${bad}" '17'
  done
  for bad in '.' '..'; do
    match='must name a file'
    pom fail "rejects '${bad}'" "${bad}" '17'
  done
done

echo '-- maven_args reaches the analysis only (sonarqube-cloud)'
step "${sonar}" validate 'Validate Maven POM inputs'
margs() { expect "$1" "$2" MVN_POM_FILE="$3" JAVA_VERSION=17 MAVEN_ARGS="$4"; }
for bad in '-f other.xml' '--file=other.xml' '-f=other.xml' '-B --file o.xml'; do
  match='must not name a POM'
  margs fail "rejects '${bad}' with no typed POM" '' "${bad}"
done
match='must not name a POM'
margs fail 'rejects -f alongside mvn_pom_file' 'alt.xml' '-f other.xml'
for ok in '-fae -DskipTests' '--fail-at-end' '-ff' '-fn' '-Dx=1'; do
  margs pass "keeps '${ok}'" '' "${ok}"
done

echo '== POM handed to sonar-maven-plugin (sonarqube-cloud scan)'
step "${sonar}" scan 'Provide Maven settings to the scan'
settings_args() {
  : > "${work}/gho"
  expect pass "$1" MVN_POM_FILE="$2" SETTINGS_CONTENT='' \
    RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/gho"
  check "  emits 'args=$3'" grep -qxF -- "args=$3" "${work}/gho"
}
settings_args 'no POM named' '' ''
settings_args 'alternate POM' 'alt.xml' '-f ./alt.xml'
# The allow-list permits a leading hyphen; without './' the scan
# action's word-splitting would read the name as a Maven option.
settings_args 'leading hyphen stays a filename' '-Dalt.xml' '-f ./-Dalt.xml'

echo '== pre-scan script execution (sonarqube-cloud scan)'
step "${sonar}" scan 'Run pre-scan script'
ws="${work}/ws"
mkdir -p "${ws}/proj/scripts/adir" "${work}/outside"
printf 'touch prescan-ran\n' > "${ws}/proj/scripts/good.sh"
printf 'touch "%s/escaped"\n' "${work}" > "${work}/outside/evil.sh"
ln -s "${work}/outside/evil.sh" "${ws}/proj/scripts/link.sh"
dir="${ws}/proj"
prescan() { expect "$1" "$2" GITHUB_WORKSPACE="${ws}" PRESCAN_SCRIPT_PATH="$3"; }
prescan pass 'runs a checked-in script' 'scripts/good.sh'
check '  its effect lands in path_prefix, where the scan reads' \
  test -e "${ws}/proj/prescan-ran"
match='resolves outside the workspace'
prescan fail 'rejects a symlink leaving the workspace' 'scripts/link.sh'
check '  and never executes it' test ! -e "${work}/escaped"
match='names no file'
prescan fail 'rejects a missing script' 'scripts/absent.sh'
match='names no file'
prescan fail 'rejects a directory' 'scripts/adir'
dir="${work}"

echo '== pre-scan script ordering (sonarqube-cloud scan)'
names="$(yq '.jobs.scan.steps[].name' "${root}/.github/workflows/${sonar}")"
at() { printf '%s\n' "${names}" | grep -nxF -- "$1" | cut -d: -f1; }
prescan_at="$(at 'Run pre-scan script')"
check 'runs after the plain checkout' test "${prescan_at}" -gt \
  "$(at 'Checkout repository')"
check 'runs after the Gerrit checkout' test "${prescan_at}" -gt \
  "$(at 'Checkout Gerrit change')"
check 'runs before the scan' test "${prescan_at}" -lt \
  "$(at 'SonarQube Cloud scan')"

echo '== build_type python (sonatype-lifecycle)'
step "${clm}" gerrit-validate 'Validate build_type input'
expect pass "accepts 'python'" BUILD_TYPE=python
match="'python'"
expect fail 'rejects an unknown build type, naming python among the choices' \
  BUILD_TYPE=python3
step "${clm}" gerrit-validate 'Validate scan_mode input'
match='requires'
expect fail "rejects scan_mode 'sbom' with python" BUILD_TYPE=python \
  SCAN_MODE=sbom

# Only the no-manifest case is testable offline: detection is ordered
# before anything is fetched precisely so that it is. Resolution itself
# needs PyPI and runs in testing.yaml.
step "${clm}" scan 'Resolve Python dependencies'
mkdir -p "${work}/py-empty"
dir="${work}/py-empty"
match="::error::build_type 'python' found nothing to resolve"
expect fail 'rejects a project with nothing to resolve' \
  RUNNER_TEMP="${work}" PYTHON_VERSION=''
check '  before creating an environment' test ! -e "${work}/clm-python"
dir="${work}"

clm_names="$(yq '.jobs.scan.steps[].name' "${root}/.github/workflows/${clm}")"
clm_at() { printf '%s\n' "${clm_names}" | grep -nxF -- "$1" | cut -d: -f1; }
check 'python resolves after checkout' test \
  "$(clm_at 'Resolve Python dependencies')" -gt \
  "$(clm_at 'Checkout repository')"
check 'python resolves before the scan' test \
  "$(clm_at 'Resolve Python dependencies')" -lt \
  "$(clm_at 'Sonatype Lifecycle scan')"
check 'the scan targets the resolved directory for python' \
  grep -qF "inputs.build_type == 'python' && format('{0}/.python-deps'" \
  "${root}/.github/workflows/${clm}"

# The Scorecard API re-verifies this file on every publish, and a
# rejection surfaces only as a warning in a green job, so a regression
# here goes unseen. These mirror the API's checks on the scan job; see
# verify_workflow.go in ossf/scorecard-infra.
echo '== publish restrictions (openssf-scorecard scan)'
scorecard="${root}/.github/workflows/openssf-scorecard.yaml"
# The API applies every check below to whichever job runs
# ossf/scorecard-action, and rejects the file if none does. Anchor them
# by requiring that job to be 'scan', and the only one.
scorecard_jobs="$(yq '[.jobs | to_entries[]
  | select(.value.steps[].uses // "" | test("^ossf/scorecard-action@"))
  | .key] | unique | join(",")' "${scorecard}")"
check "scan is the one job running ossf/scorecard-action ('${scorecard_jobs}')" \
  test "${scorecard_jobs}" = scan
runs_on="$(yq '.jobs.scan."runs-on" | select(tag == "!!str")' "${scorecard}")"
# isSupportedUbuntuRunner: the pattern, then a floor of 22.04 for any
# versioned label. The pattern fixes the width at NN.NN, so dropping
# the dot gives the same order as the verifier's string comparison.
hosted_ubuntu() {
  [[ "$1" =~ ^ubuntu-(latest|[0-9]{2}\.[0-9]{2})(-arm)?$ ]] || return 1
  local version="${BASH_REMATCH[1]}"
  [ "${version}" = latest ] || (( 10#${version/./} >= 2204 ))
}
not_hosted_ubuntu() { ! hosted_ubuntu "$1"; }
check "runs-on is a literal hosted Ubuntu label ('${runs_on}')" \
  hosted_ubuntu "${runs_on}"
for label in ubuntu-latest ubuntu-22.04 ubuntu-24.04-arm; do
  check "  the check accepts '${label}'" hosted_ubuntu "${label}"
done
for label in ubuntu-20.04 ubuntu-latest-8-cores ubuntu-buildbox; do
  check "  the check rejects '${label}'" not_hosted_ubuntu "${label}"
done
# Parenthesised: yq binds '|' looser than 'or', so without them only
# the first key would be tested against the job.
check 'scan job declares no env or defaults' test \
  "$(yq '.jobs.scan | (has("env") or has("defaults"))' "${scorecard}")" = false
check 'scan job declares no container or services' test \
  "$(yq '.jobs.scan | (has("container") or has("services"))' "${scorecard}")" = false
check 'the scan job holds id-token: write, which publishing needs' test \
  "$(yq '.jobs.scan.permissions."id-token"' "${scorecard}")" = write
check 'no other job holds id-token: write' test "$(yq \
  '[.jobs | to_entries[] | select(.key != "scan")
    | select(.value.permissions."id-token" == "write")] | length' \
  "${scorecard}")" = 0
unpermitted="$(yq '.jobs.scan.steps[] | (.uses // "(run step)") | sub("@.*", "")' \
  "${scorecard}" | grep -vxE 'actions/(checkout|create-github-app-token|upload-artifact)|ossf/scorecard-action|github/codeql-action/upload-sarif|step-security/harden-runner' || true)"
check "scan job uses only permitted actions${unpermitted:+ (not: ${unpermitted//$'\n'/, })}" \
  test -z "${unpermitted}"

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
