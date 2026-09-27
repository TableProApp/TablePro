#!/usr/bin/env bash
#
# Compare the MongoDB plugin's interruption codes against the server's own error code tables.
#
# A multi-document write that fails with ok: 0 and a code in the server's Interruption category
# may already have changed documents: the server fails the whole batch for exactly those codes,
# after writing the documents before the one it stopped at, and its reply does not say how many.
# The plugin reports that from MongoDBServerErrorCode.interruptionCategory, a hand-copied union of
# the category across every release. Releases keep adding to it (8.0 to 8.3 added six codes), and
# a code missing from the set reads as a write that changed nothing, so this diffs the set against
# every release branch of mongodb/mongo from 4.0 on.
#
# Usage:
#   scripts/check-mongodb-interruption-codes.sh
#
# Needs curl, git, python3 and network access to GitHub. Exits non-zero on a disagreement.

set -uo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/MongoDBDriverPlugin/MongoDBTimeoutPolicy.swift"
REPO="https://github.com/mongodb/mongo"
RAW="https://raw.githubusercontent.com/mongodb/mongo"

for tool in curl git python3; do
    command -v "$tool" > /dev/null || {
        echo "$tool not found" >&2
        exit 3
    }
done
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}

# A private directory, matching every sibling check script. /tmp is world-writable, so a fixed
# name is something another local user can pre-create and control.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git ls-remote --heads "$REPO" 'v[0-9]*' > "$WORK/heads" || {
    echo "could not list the branches of $REPO" >&2
    exit 3
}
BRANCHES=()
while IFS= read -r branch; do
    BRANCHES+=("$branch")
done < <(sed -n 's#.*refs/heads/\(v[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' "$WORK/heads" \
    | awk -F'[v.]' '$2 >= 4' \
    | sort -t. -k1.2,1n -k2,2n)
[ "${#BRANCHES[@]}" -gt 0 ] || {
    echo "no release branches from 4.0 on in $REPO" >&2
    exit 3
}

for branch in "${BRANCHES[@]}"; do
    if curl -fsS -o "$WORK/$branch.yml" "$RAW/$branch/src/mongo/base/error_codes.yml" 2> /dev/null; then
        continue
    fi
    rm -f "$WORK/$branch.yml"
    curl -fsS -o "$WORK/$branch.err" "$RAW/$branch/src/mongo/base/error_codes.err" || {
        echo "no error code table on $branch" >&2
        exit 3
    }
done

echo "Checking the interruption codes against ${#BRANCHES[@]} release branches"

python3 - "$SOURCE" "$WORK" "${BRANCHES[@]}" << 'PY'
import os
import re
import sys

source, work, branches = sys.argv[1], sys.argv[2], sys.argv[3:]


def uncommented(path):
    return re.sub(r"#.*", "", open(path).read())


def interruption_codes(branch):
    yml = os.path.join(work, branch + ".yml")
    if os.path.exists(yml):
        text = uncommented(yml)
        codes = {}
        for body in re.findall(r"-\s*\{(.*?)\}", text, re.S):
            code = re.search(r"\bcode:\s*(\d+)", body)
            name = re.search(r"\bname:\s*(\w+)", body)
            categories = re.search(r"\bcategories:\s*\[(.*?)\]", body, re.S)
            if code and name and categories and "Interruption" in re.findall(r"\w+", categories.group(1)):
                codes[int(code.group(1))] = name.group(1)
        return codes
    text = uncommented(os.path.join(work, branch + ".err"))
    numbers = {name: int(code) for name, code in re.findall(r'error_code\("(\w+)",\s*(\d+)', text)}
    listed = re.search(r'error_class\("Interruption",\s*\[(.*?)\]\)', text, re.S)
    return {numbers[name]: name for name in re.findall(r'"(\w+)"', listed.group(1))}


swift = open(source).read()
constants = {name: int(value.replace("_", "")) for name, value in re.findall(r"static let (\w+): UInt32 = ([\d_]+)", swift)}
listed = re.search(r"interruptionCategory: Set<UInt32> = \[(.*?)\]", swift, re.S)
if listed is None:
    print("interruptionCategory not found in " + source, file=sys.stderr)
    sys.exit(3)
ours = set()
for token in re.findall(r"[\w]+", listed.group(1)):
    ours.add(int(token.replace("_", "")) if token[0].isdigit() else constants[token])

first_seen = {}
for branch in branches:
    for code, name in interruption_codes(branch).items():
        first_seen.setdefault(code, (name, branch))

missing = sorted(set(first_seen) - ours)
extra = sorted(ours - set(first_seen))
for code in missing:
    name, branch = first_seen[code]
    print(f"missing: {code} {name} (Interruption since {branch})")
for code in extra:
    print(f"not an Interruption code on any release branch: {code}")
if missing or extra:
    sys.exit(1)
print(f"ok: {len(ours)} codes, the union across {branches[0]} to {branches[-1]}")
PY
