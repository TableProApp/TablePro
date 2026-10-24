#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
EVIDENCE="$ROOT/docs/evidence/large-result-grid-2026-10-24"

export GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=atspi XDG_CURRENT_DESKTOP=GNOME
dbus-update-activation-environment DISPLAY XAUTHORITY GDK_BACKEND GTK_A11Y
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >/dev/null
eval "$(printf 'bookie-test' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"

for scheme in prefer-light prefer-dark; do
  for rows in 5000 150000; do
    export ADW_DEBUG_COLOR_SCHEME="$scheme"
    export TABLEPRO_PROFILE_ROWS="$rows"
    export TABLEPRO_PROFILE_OUT="$TABLEPRO_GTK_ARTIFACT_DIR/profile-$scheme-$rows.jsonl"
    python3 "$EVIDENCE/capture.py" "$TABLEPRO_GTK_BINARY"
  done
done
