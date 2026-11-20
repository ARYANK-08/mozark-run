#!/usr/bin/env bash
# Upload a build, run an App Studio suite, wait, publish results.
# Exit: 0 passed · 1 tests failed · 2 errored (auth, config, infrastructure, no verdict) · 3 timed out
set -euo pipefail

readonly EXIT_PASSED=0 EXIT_FAILED=1 EXIT_ERRORED=2 EXIT_TIMEOUT=3
readonly POLL_SECONDS="${MOZARK_POLL_SECONDS:-15}"
readonly BUILD_POLL_SECONDS=10
readonly TRANSIENT_RETRIES=5
readonly SECONDS_PER_MINUTE=60
readonly CI_API="${MOZARK_API_URL%/}/ci/v1"
readonly RESULTS_DIR="${MOZARK_RESULTS_DIR:-results}"
APP_URL="${MOZARK_APP_URL:-}"
readonly APP_URL="${APP_URL%/}"
# App Studio opens a link with these ids in the same org, app and project, instead of whatever the viewer last picked.
readonly REPORT_QUERY="orgId=${MOZARK_ORG_ID:-}&appId=${MOZARK_APP_ID:-}&projectId=${MOZARK_PROJECT_ID:-}"

first_set() {
  local name
  for name in "$@"; do [[ -n "${!name:-}" ]] && { echo "${!name}"; return; }; done
  echo ""
}

# GitHub Actions, Bitbucket Pipelines, Jenkins or GitLab CI; the run key is per attempt, so this script's own retries never book twice.
COMMIT_SHA=$(first_set GITHUB_SHA BITBUCKET_COMMIT GIT_COMMIT CI_COMMIT_SHA)
BRANCH=$(first_set GITHUB_REF_NAME BITBUCKET_BRANCH BITBUCKET_TAG BRANCH_NAME GIT_BRANCH CI_COMMIT_REF_NAME)
readonly COMMIT_SHA BRANCH
export COMMIT_SHA BRANCH
if [[ -n ${GITHUB_RUN_ID:-} ]]; then
  readonly RUN_KEY="github-$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}"
elif [[ -n ${BITBUCKET_BUILD_NUMBER:-} ]]; then
  readonly RUN_KEY="bitbucket-$BITBUCKET_BUILD_NUMBER-${BITBUCKET_STEP_UUID:-1}"
elif [[ -n ${BUILD_TAG:-} ]]; then
  readonly RUN_KEY="$BUILD_TAG"
elif [[ -n ${CI_JOB_ID:-} ]]; then
  readonly RUN_KEY="gitlab-$CI_JOB_ID"
else
  readonly RUN_KEY="local-$(date +%s)"
fi

fail() {
  echo "::error::$1" >&2
  exit "${2:-$EXIT_ERRORED}"
}

require() {
  local name
  for name in "$@"; do [[ -n "${!name:-}" ]] || fail "missing input: $name"; done
}

server_message() {
  jq -r '(.message // .error // .) | if type == "array" then join("; ") else tostring end' "$1" 2>/dev/null || head -c 300 "$1"
}

# 2xx prints the body; 4xx stops with the server's reason; 5xx and network errors are retried.
api() {
  local attempt status body
  body=$(mktemp)
  for ((attempt = 1; attempt <= TRANSIENT_RETRIES; attempt++)); do
    status=$(curl -sS -o "$body" -w '%{http_code}' \
      -H "Authorization: Bearer $MOZARK_TOKEN" \
      -H "x-org-id: $MOZARK_ORG_ID" -H "x-app-id: $MOZARK_APP_ID" -H "x-project-id: $MOZARK_PROJECT_ID" \
      "$@") || status=000
    if [[ $status == 2* ]]; then cat "$body"; rm -f "$body"; return 0; fi
    [[ $status == 4* ]] && fail "App Studio refused the request ($status): $(server_message "$body")"
    echo "App Studio unavailable ($status), retry $attempt/$TRANSIENT_RETRIES" >&2
    sleep $((attempt * 5))
  done
  fail "App Studio unavailable after $TRANSIENT_RETRIES attempts"
}

check_deadline() {
  ((SECONDS < DEADLINE)) || fail "no result after ${MOZARK_TIMEOUT_MINUTES} min${1:+ (run $1)}" "$EXIT_TIMEOUT"
}

wait_until_ready() {
  local id=$1 status=$2
  while [[ $status == processing ]]; do
    check_deadline
    sleep "$BUILD_POLL_SECONDS"
    status=$(api "${MOZARK_API_URL%/}/app-uploads/$id/status" | jq -r .status)
  done
  [[ $status == ready ]] || fail "build $id is $status"
}

# build-path uploads a new .apk/.ipa; build-id reuses one already in App Studio; neither runs the suite's own build.
resolve_build() {
  if [[ -n "${MOZARK_BUILD_PATH:-}" ]]; then
    [[ -f "$MOZARK_BUILD_PATH" ]] || fail "build-path not found: $MOZARK_BUILD_PATH"
    echo "Uploading $MOZARK_BUILD_PATH" >&2
    local upload id
    upload=$(api -F "file=@$MOZARK_BUILD_PATH" "${MOZARK_API_URL%/}/app-uploads")
    id=$(jq -r .id <<<"$upload")
    wait_until_ready "$id" "$(jq -r .status <<<"$upload")"
    echo "Build $id is ready" >&2
    echo "$id"
  elif [[ -n "${MOZARK_BUILD_ID:-}" ]]; then
    wait_until_ready "$MOZARK_BUILD_ID" "$(api "${MOZARK_API_URL%/}/app-uploads/$MOZARK_BUILD_ID/status" | jq -r .status)"
    echo "Using build $MOZARK_BUILD_ID" >&2
    echo "$MOZARK_BUILD_ID"
  fi
}

build_label() {
  if [[ -n "${MOZARK_BUILD_PATH:-}" ]]; then echo "uploaded \`$(basename "$MOZARK_BUILD_PATH")\` as \`$1\`"
  elif [[ -n "${MOZARK_BUILD_ID:-}" ]]; then echo "existing build \`$1\`"
  else echo "the suite’s own build"; fi
}

trigger() {
  local build_id=$1 body
  body=$(jq -n --arg buildId "$build_id" --arg commitSha "$COMMIT_SHA" --arg branch "$BRANCH" \
    --arg appVersion "${MOZARK_APP_VERSION:-}" --arg timeZone "${MOZARK_TIME_ZONE:-}" \
    '{buildId: $buildId, commitSha: $commitSha, branch: $branch, appVersion: $appVersion, timeZone: $timeZone} | with_entries(select(.value != ""))')
  # The build is part of the key: matrix legs testing different builds of one suite are different runs.
  api -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $RUN_KEY-$MOZARK_SUITE_ID-${build_id:-suite-build}" -d "$body" \
    "$CI_API/suites/$MOZARK_SUITE_ID/runs"
}

wait_for_result() {
  local run_id=$1 view
  while :; do
    view=$(api "$CI_API/runs/$run_id")
    [[ $(jq -r .status <<<"$view") == FINISHED ]] && { echo "$view"; return 0; }
    echo "  $(date +%H:%M:%S) $(jq -r '[.jobs[] | "\(.platform) \(.verdict)"] | join(", ")' <<<"$view")" >&2
    check_deadline "$run_id"
    sleep "$POLL_SECONDS"
  done
}

publish() {
  local view=$1 build_id=$2 run_id result
  run_id=$(jq -r .id <<<"$view")
  result=$(jq -r .result <<<"$view")
  mkdir -p "$RESULTS_DIR"
  echo "$view" >"$RESULTS_DIR/run.json"
  api "$CI_API/runs/$run_id/junit" >"$RESULTS_DIR/junit.xml"

  jq -r --arg ui "$APP_URL" --arg query "$REPORT_QUERY" \
    '.jobs[] | "  \(.platform) \(.verdict) \(.summary.passed // 0)/\(.summary.total // 0)  \($ui)\(.reportPath)?\($query)"' <<<"$view" >&2
  # The summary is a convenience: failing to render it must never change the run's exit code.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    MOZARK_ELAPSED=$SECONDS MOZARK_BUILD_LABEL=$(build_label "$build_id") MOZARK_REPORT_QUERY=$REPORT_QUERY \
      python3 "$(dirname "$0")/summary.py" "$RESULTS_DIR" >>"$GITHUB_STEP_SUMMARY" ||
      echo "::warning::Could not write the job summary; results are in $RESULTS_DIR"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "run-id=$run_id" >>"$GITHUB_OUTPUT"
    echo "result=$result" >>"$GITHUB_OUTPUT"
  fi
}

main() {
  require MOZARK_TOKEN MOZARK_API_URL MOZARK_ORG_ID MOZARK_APP_ID MOZARK_PROJECT_ID MOZARK_SUITE_ID
  command -v jq >/dev/null || fail "jq is required"
  # Only GitHub hides this line; anywhere else it would print the key.
  [[ ${GITHUB_ACTIONS:-} == true ]] && echo "::add-mask::$MOZARK_TOKEN"
  DEADLINE=$((SECONDS + ${MOZARK_TIMEOUT_MINUTES:-45} * SECONDS_PER_MINUTE))

  local build_id run run_id view result
  build_id=$(resolve_build)
  run=$(trigger "$build_id")
  run_id=$(jq -r .id <<<"$run")
  echo "Run $run_id started: $(jq -r '[.jobs[].jobId] | join(", ")' <<<"$run")" >&2
  jq -r --arg ui "$APP_URL" --arg query "$REPORT_QUERY" '.jobs[] | "Report: \($ui)\(.reportPath)?\($query)"' <<<"$run" >&2
  view=$(wait_for_result "$run_id")
  result=$(jq -r .result <<<"$view")
  publish "$view" "$build_id"
  echo "Result: $result" >&2

  case $result in
    PASSED) exit "$EXIT_PASSED" ;;
    FAILED) exit "$EXIT_FAILED" ;;
    *) exit "$EXIT_ERRORED" ;;
  esac
}

main "$@"
