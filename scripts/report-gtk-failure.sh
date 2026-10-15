#!/usr/bin/env bash
set -euo pipefail

log_file=${1:?usage: report-gtk-failure.sh <log-file> <failure-status>}
status=${2:?usage: report-gtk-failure.sh <log-file> <failure-status>}

if ! [[ "$status" =~ ^[1-9][0-9]*$ ]]; then
  printf 'failure status must be a nonzero integer\n' >&2
  exit 2
fi

if [[ -r "$log_file" && -s "$log_file" ]]; then
  if matches=$(grep -aE '^passed:|^RETRY|^FAILED|scenario.s. failed|^AssertionError|^  File .*gtk_[a-z]*\.py", line [0-9]+, in ' "$log_file" | tail -30) && [[ -n "$matches" ]]; then
    printf '%s\n' "$matches"
  fi
  printf 'GTK suite diagnostic tail (%s):\n' "$log_file"
  tail -n 20 "$log_file" || true
else
  printf 'GTK suite produced no output (log unavailable: %s)\n' "$log_file"
fi

exit "$status"
