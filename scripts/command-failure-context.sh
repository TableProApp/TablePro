#!/usr/bin/env bash

bookie_report_command_failure() {
  local status=$?
  printf 'command failed at %s:%s: %s (exit %s)\n' \
    "${BASH_SOURCE[1]:-$0}" "${BASH_LINENO[0]:-$LINENO}" "$BASH_COMMAND" "$status" >&2
  exit "$status"
}

bookie_enable_command_failure_context() {
  trap bookie_report_command_failure ERR
}
