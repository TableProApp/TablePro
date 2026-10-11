#!/usr/bin/env bash
set -euo pipefail

branch="${1:-$(git rev-parse --abbrev-ref HEAD)}"
target="${2:-$branch}"
remote="${FORGEJO_REMOTE:-forgejo}"
token_file="${FORGEJO_TOKEN_FILE:-$HOME/.config/forgejo/token}"
remote_url="$(git remote get-url "$remote")"
default_api="$(printf '%s' "$remote_url" | sed -E 's#^(https?://)([^/@]*@)?([^/]+)/(.+)\.git$#\1\3/api/v1/repos/\4#')"
api="${FORGEJO_API:-$default_api}"
timeout_minutes="${FORGEJO_GATE_TIMEOUT_MINUTES:-60}"

export GIT_ASKPASS="${GIT_ASKPASS:-$HOME/.config/forgejo/askpass.sh}"
sha="$(git rev-parse "$branch")"
token="$(cat "$token_file")"

docs_only() {
  git fetch --quiet "$remote" linux || return 1
  local changed
  changed="$(git diff --name-only "$remote/linux...$sha")"
  [ -n "$changed" ] && [ -z "$(printf '%s\n' "$changed" | grep -vE '(\.md$|^docs/)')" ]
}
if docs_only; then
  (cd "$(git rev-parse --show-toplevel)" &&
    python3 scripts/inventory-ignored-tests.py --check &&
    python3 scripts/check-doc-links.py &&
    python3 scripts/check-known-issues.py)
  echo "documentation only: no Forgejo run is needed for $sha; the documentation checks passed"
  exit 0
fi

exec 9>"${FORGEJO_GATE_LOCK:-/tmp/forgejo-gate.lock}"
if ! flock -n 9; then
  echo "another gate is running on this host; waiting for it to finish"
  flock 9
fi
latest_run_id() {
  curl -fsS -H "Authorization: token $token" "$api/actions/runs?limit=1" | python3 -c '
import json, sys
runs = json.load(sys.stdin)["workflow_runs"]
print(runs[0]["id"] if runs else 0)
'
}
remote_sha="$(git ls-remote "$remote" "refs/heads/$target" | cut -f1)"
if [ "$remote_sha" = "$sha" ]; then
  after=0
  echo "$target already points at $sha on $remote; using its latest ci run, which may be older than this check"
else
  after="$(latest_run_id)"
  git push --quiet "$remote" "$branch:$target"
fi
deadline=$((SECONDS + timeout_minutes * 60))

summarize() {
  curl -fsS -H "Authorization: token $token" "$api/actions/runs?limit=50" | python3 -c '
import json, sys
sha, after = sys.argv[1], int(sys.argv[2])
runs = [
    run for run in json.load(sys.stdin)["workflow_runs"]
    if run["commit_sha"] == sha and run["id"] > after and run.get("workflow_id") == "ci.yml"
]
if not runs:
    print("pending")
else:
    run = max(runs, key=lambda item: item["id"])
    print(run["status"], run["id"])
' "$sha" "$after"
}

while [ "$SECONDS" -lt "$deadline" ]; do
  read -r status run_id <<<"$(summarize)"
  case "$status" in
    success) echo "forgejo run $run_id passed for $sha"; exit 0 ;;
    failure|cancelled)
      report="$(curl -fsS -H "Authorization: token $token" "$api/actions/tasks?limit=100" | python3 -c '
import json, sys
run = int(sys.argv[1])
tasks = [task for task in json.load(sys.stdin).get("workflow_runs", []) if task.get("run_number") == run]
if any(task["status"] in ("running", "waiting") for task in tasks):
    print("RUNNING")
else:
    for task in tasks:
        if task["status"] != "success":
            print("  ", task["status"], task["name"])
' "$run_id")"
      if [ "$report" != "RUNNING" ]; then
        echo "forgejo run $run_id $status for $sha"
        [ -n "$report" ] && echo "$report"
        exit 1
      fi ;;
  esac
  sleep 30
done
echo "forgejo run for $sha did not finish within $timeout_minutes minutes" >&2
exit 2
