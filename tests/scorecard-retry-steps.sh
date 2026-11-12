#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Holds the shape of openssf-scorecard.yaml's analysis retry. The scan
# job runs ossf/scorecard-action twice at most, because the Scorecard
# API forbids every way of waiting for harden-runner's agent; see the
# 'Run analysis' step. The retry only helps while both steps run the
# same action the same way, one straight after the other, so this
# checks that they do. The race itself cannot be forced in CI.
#
# It sits beside tests/workflow-steps.sh, which holds the scan job's
# other publish restrictions, only because that harness is an
# executable file this change could not edit; folding these checks
# into it is a mechanical follow-up.
#
# Usage: bash tests/scorecard-retry-steps.sh    (needs mikefarah yq v4)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scorecard="${root}/.github/workflows/openssf-scorecard.yaml"
cases=0
failures=0

if ! yq --version 2> /dev/null | grep -q 'mikefarah'; then
  echo '::error::tests/scorecard-retry-steps.sh needs mikefarah yq v4' >&2
  exit 2
fi

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

# scan <expression>: evaluates a yq expression against the scan job.
scan() { yq ".jobs.scan | $1" "${scorecard}"; }

echo '== analysis retry (openssf-scorecard scan)'
# Zero-based indices of the steps running ossf/scorecard-action
indices="$(scan '.steps | to_entries[]
  | select(.value.uses // "" | test("^ossf/scorecard-action@")) | .key')"
check "the scan job runs ossf/scorecard-action in exactly two steps" \
  test "$(printf '%s\n' "${indices}" | grep -c .)" = 2
first="$(printf '%s\n' "${indices}" | sed -n 1p)"
second="$(printf '%s\n' "${indices}" | sed -n 2p)"
first="${first:-0}"
second="${second:-0}"
check 'no step sits between the two attempts' \
  test "$((second - first))" = 1

check 'both attempts use the same ref' test \
  "$(scan ".steps[${first}].uses")" = "$(scan ".steps[${second}].uses")"
# Compared as YAML so key order and quoting count, as a reviewer sees it
check 'both attempts pass the same inputs' test \
  "$(scan ".steps[${first}].with")" = "$(scan ".steps[${second}].with")"
check 'the inputs are not empty' test \
  "$(scan ".steps[${first}].with | length")" -gt 0

id="$(scan ".steps[${first}].id")"
check "the first attempt has an id ('${id}')" test "${id}" != null
check 'the first attempt sets continue-on-error: true' test \
  "$(scan ".steps[${first}].\"continue-on-error\"")" = true
check 'the first attempt carries no if:' test \
  "$(scan ".steps[${first}] | has(\"if\")")" = false

check 'the retry runs only when the first attempt failed' test \
  "$(scan ".steps[${second}].if")" = "steps.${id}.outcome == 'failure'"
# Without this the job would pass with no analysis at all
check 'the retry does not set continue-on-error' test \
  "$(scan ".steps[${second}] | has(\"continue-on-error\")")" = false

echo
if [ "${failures}" -gt 0 ]; then
  echo "${failures} of ${cases} cases FAILED"
  exit 1
fi
echo "All ${cases} cases passed"
