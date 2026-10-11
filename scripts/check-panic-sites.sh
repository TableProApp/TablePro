#!/usr/bin/env bash
# A panic in production code takes the whole process with it: the GUI
# window disappears, or `tablepro-agentd` drops every MCP session mid
# request. `unwrap`, `expect`, `panic!`, `todo!`, `unimplemented!` and
# `unreachable!` are all that shape, so production Rust may not add new
# ones. Tests may panic freely: that is how a test reports failure.
#
# "Production" here means every crates/**/*.rs line that is not inside a
# `#[cfg(test)]` item, not in a `tests/` directory, and not in a
# `*-tests` support crate. `#[cfg(test)] mod name;` pulls a whole file
# in as a test module, so those files are excluded too.
#
# The count per file is ratcheted by panic-site-baselines.txt: existing
# sites do not block the build, but the number cannot grow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES="$ROOT/panic-site-baselines.txt"
CRATES="$ROOT/crates"

declare -A MAX_SITES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  path="${line%% *}"
  max="${line##* }"
  if [[ -z "$path" || -z "$max" || "$path" == "$max" ]]; then
    echo "error: malformed baseline line: $line" >&2
    exit 1
  fi
  MAX_SITES["$path"]="$max"
done <"$BASELINES"

# Module files a declaration inside `file` pulls in. When `gated_only` is
# 1 only `#[cfg(test)] mod name;` counts; when it is 0 every `mod name;`
# counts, which is what a file that is already test-only needs, because
# its children inherit the gate and do not repeat the attribute.
declared_module_files() {
  local file="$1" gated_only="$2" dir target
    dir="$(dirname "$file")"
    while IFS= read -r target; do
      if [[ -f "$dir/$target" ]]; then
        printf '%s\n' "$(realpath -m "$dir/$target")"
      elif [[ -f "$dir/${target%.rs}/mod.rs" ]]; then
        printf '%s\n' "$(realpath -m "$dir/${target%.rs}/mod.rs")"
      fi
    done < <(awk -v gated_only="$gated_only" '
      BEGIN { if (!gated_only) pending = 1 }
      /^[ \t]*#\[cfg\(test\)\]/ { pending = 1; path = ""; next }
      pending && /^[ \t]*#\[path[ \t]*=/ {
        if (match($0, /"[^"]+"/)) path = substr($0, RSTART + 1, RLENGTH - 2)
        next
      }
      pending && /^[ \t]*(pub[ \t]+)?mod[ \t]+[A-Za-z0-9_]+[ \t]*;/ {
        if (path != "") {
          print path
        } else if (match($0, /mod[ \t]+[A-Za-z0-9_]+/)) {
          name = substr($0, RSTART, RLENGTH)
          sub(/^mod[ \t]+/, "", name)
          print name ".rs"
        }
        pending = gated_only ? 0 : 1
        path = ""
        next
      }
      { if (gated_only) pending = 0; else path = "" }
    ' "$file")
}

declare -A TEST_ONLY=()
while IFS= read -r -d '' file; do
  while IFS= read -r path; do
    [[ -n "$path" ]] && TEST_ONLY["$path"]=1
  done < <(declared_module_files "$file" 1)
done < <(find "$CRATES" -type f -name '*.rs' -print0)

# A test-only file's own `mod` declarations are test-only too, however
# deep the chain goes. `guard_tests.rs` declares its two halves without
# repeating `#[cfg(test)]`, because the parent module already carries it.
while :; do
  added=0
  for known in "${!TEST_ONLY[@]}"; do
    [[ -f "$known" ]] || continue
    while IFS= read -r path; do
      if [[ -n "$path" && -z "${TEST_ONLY[$path]:-}" ]]; then
        TEST_ONLY["$path"]=1
        added=1
      fi
    done < <(declared_module_files "$known" 0)
  done
  [[ "$added" -eq 0 ]] && break
done

# Drops every `#[cfg(test)]` item, then counts panic sites on what is
# left. Sources are rustfmt-formatted, so the closing brace of a test
# item is a lone `}` at the indentation of its attribute.
count_panic_sites() {
  local file=$1
  awk '
    function flush_pending() { pending = 0; indent = "" }
    skipping {
      if ($0 == closer) skipping = 0
      next
    }
    /^[ \t]*#\[cfg\(test\)\]/ {
      pending = 1
      match($0, /^[ \t]*/)
      indent = substr($0, 1, RLENGTH)
      closer = indent "}"
      next
    }
    pending {
      if ($0 ~ /^[ \t]*(#\[|$)/) next
      if ($0 ~ /\{/) { skipping = 1; flush_pending(); next }
      if ($0 ~ /;[ \t]*$/) { flush_pending(); next }
      next
    }
    /^[ \t]*\/\// { next }
    {
      line = $0
      n = gsub(/\.unwrap\(\)/, "", line)
      n += gsub(/\.expect\(/, "", line)
      n += gsub(/panic!/, "", line)
      n += gsub(/todo!/, "", line)
      n += gsub(/unimplemented!/, "", line)
      n += gsub(/unreachable!/, "", line)
      total += n
    }
    END { print total + 0 }
  ' "$file"
}

errors=0
listed_seen=()

while IFS= read -r -d '' file; do
  rel="${file#"$ROOT"/}"
  case "$rel" in
    */tests/*) continue ;;
    crates/*-tests/*) continue ;;
  esac
  [[ -n "${TEST_ONLY[$file]:-}" ]] && continue

  sites=$(count_panic_sites "$file")
  ceiling="${MAX_SITES[$rel]:-0}"

  if (( sites > ceiling )); then
    if (( ceiling == 0 )); then
      echo "error: $rel has $sites panic site(s) in production code. Return a typed error instead." >&2
    else
      echo "error: $rel grew to $sites panic site(s) (baseline max $ceiling). Remove one before adding one." >&2
    fi
    errors=$((errors + 1))
  elif (( sites < ceiling )); then
    echo "note: $rel is down to $sites panic site(s) (baseline $ceiling). Lower the baseline after this cleanup."
  fi

  [[ -n "${MAX_SITES[$rel]:-}" ]] && listed_seen+=("$rel")
done < <(find "$CRATES" -type f -name '*.rs' -print0 | sort -z)

for rel in "${!MAX_SITES[@]}"; do
  found=0
  for seen in ${listed_seen[@]+"${listed_seen[@]}"}; do
    [[ "$seen" == "$rel" ]] && found=1 && break
  done
  if (( found == 0 )); then
    echo "error: baseline lists $rel, which is no longer scanned production code; remove the stale entry." >&2
    errors=$((errors + 1))
  fi
done

if (( errors > 0 )); then
  echo "panic-sites: $errors error(s)" >&2
  exit 1
fi

echo "panic-sites: ok (no new unwrap/expect/panic!/todo!/unimplemented!/unreachable! in production code)"
