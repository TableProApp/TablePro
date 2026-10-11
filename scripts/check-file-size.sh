#!/usr/bin/env bash
# Enforce Rust source file size limits under crates.
#
# New files above 1200 lines require an explicit baseline. Unlisted files above
# 1800 lines fail. Listed files may shrink but cannot grow past their ceiling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES="$ROOT/file-size-baselines.txt"
CRATES="$ROOT/crates"
WARN_LIMIT=1200
ERROR_LIMIT=1800

declare -A MAX_LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  path="${line%% *}"
  max="${line##* }"
  if [[ -z "$path" || -z "$max" || "$path" == "$max" ]]; then
    echo "error: malformed baseline line: $line" >&2
    exit 1
  fi
  MAX_LINES["$path"]="$max"
done <"$BASELINES"

errors=0

while IFS= read -r -d '' file; do
  rel="${file#"$ROOT"/}"
  lines=$(wc -l <"$file")
  ceiling="${MAX_LINES[$rel]:-}"

  if [[ -n "$ceiling" ]]; then
    if (( lines > ceiling )); then
      echo "error: $rel grew to $lines lines (baseline max $ceiling). Split the file or restore size." >&2
      errors=$((errors + 1))
    elif (( lines < ceiling )); then
      echo "note: $rel is $lines lines (baseline $ceiling). Lower the baseline after this shrink."
    fi
    continue
  fi

  if (( lines > ERROR_LIMIT )); then
    echo "error: $rel has $lines lines (hard limit $ERROR_LIMIT). Split before merging." >&2
    errors=$((errors + 1))
  elif (( lines > WARN_LIMIT )); then
    echo "error: $rel has $lines lines (soft limit $WARN_LIMIT). Split the file, or add it to file-size-baselines.txt with that exact line count." >&2
    errors=$((errors + 1))
  fi
done < <(find "$ROOT/crates" "$ROOT/apps" "$ROOT/tests" -type f -name '*.rs' -print0 | sort -z)

for rel in "${!MAX_LINES[@]}"; do
  if [[ ! -f "$ROOT/$rel" ]]; then
    echo "error: baseline lists missing file $rel; remove the stale entry." >&2
    errors=$((errors + 1))
  fi
done

if (( errors > 0 )); then
  echo "file-size: $errors error(s)" >&2
  exit 1
fi

echo "file-size: ok (soft>$WARN_LIMIT requires baseline, hard>$ERROR_LIMIT)"
