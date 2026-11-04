#!/usr/bin/env bash
# Checks what Run Ledger Plugins off promises for a Beancount connection, against real beancount and rledger.
#
# Beancount is a registry plugin with no test target, so this is its check.
#
# Python backend: beancount 3.2.3 in a throwaway venv runs the projection script taken verbatim from
# BeancountPluginDriver+PythonScript.swift, the way the driver runs it (cwd /, a minimal environment).
# - A bundled plugin given a config never runs: commodity_attr evals it, so the payload would write a marker.
# - A beancount module outside beancount.plugins never runs: with insert_pythonpath, beancount.projects.export
#   would import a planted csv.py.
# - A plugin that does run never imports from the ledger's folder: insert_pythonpath is undone for it.
# - A bundled plugin with no config, and a ledger with no plugin, still load.
#
# rledger, when on PATH (network denied, writes kept to the temp folder):
# - A BQL query such as -F<file> after `--` is read as a query, and `check` takes `--`.
# - The cwd pair: rledger looks up a module name with the host python3, which imports from the cwd.
#
# Every payload writes only inside the probe's temp folder. Needs python3 and network for pip. Run after
# changing the projection script, the Beancount launch, or rledger.
# Exits 0 when every case passes, 1 on a failure, 3 when a tool is missing or a control did not reproduce.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/BeancountDriverPlugin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_WORK="$(cd "$WORK" && pwd -P)"

inconclusive() {
    echo "INCONCLUSIVE: $1" >&2
    exit 3
}

failures=0
controls_missed=0
skipped=0
pass() { echo "PASS  $1"; }
fail() {
    echo "FAIL  $1" >&2
    failures=$((failures + 1))
}
control() { echo "CONTROL  $1"; }
control_missed() {
    echo "CONTROL MISSED  $1" >&2
    controls_missed=$((controls_missed + 1))
}

PYTHON=""
for candidate in "${BEANCOUNT_PROBE_PYTHON:-}" python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    [ -n "$candidate" ] || continue
    PYTHON="$(command -v "$candidate" 2> /dev/null)" && break
done
[ -n "$PYTHON" ] || inconclusive "no python3 found; set BEANCOUNT_PROBE_PYTHON"

"$PYTHON" -I -m venv "$WORK/venv" > /dev/null 2>&1 || inconclusive "$PYTHON could not create a venv"
"$WORK/venv/bin/python" -I -m pip install --quiet --disable-pip-version-check "beancount==3.2.3" > "$WORK/pip.log" 2>&1 ||
    inconclusive "pip could not install beancount 3.2.3 (offline?): $(tail -n 1 "$WORK/pip.log")"
VENV_PYTHON="$WORK/venv/bin/python"

# The script as Swift hands it to python3: the text of the multi-line literal with its escapes resolved.
"$VENV_PYTHON" -I - "$PLUGIN/BeancountPluginDriver+PythonScript.swift" "$WORK/projection.py" << 'EOF' ||
import re, sys
source = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'static let pythonProjectionScript = """\n(.*?)\n"""', source, re.S)
if match is None:
    sys.exit("pythonProjectionScript not found")
body = match.group(1)
if "\\(" in body:
    sys.exit("the script interpolates a Swift value")
escapes = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t", "r": "\r", "0": "\0"}
def unescape(m):
    if m.group(1).startswith("u{"):
        return chr(int(m.group(1)[2:-1], 16))
    return escapes[m.group(1)]
body = re.sub(r'\\(u\{[0-9A-Fa-f]+\}|[\\"\'ntr0])', unescape, body)
open(sys.argv[2], "w", encoding="utf-8").write(body + "\n")
EOF
    inconclusive "could not extract the projection script"
SCRIPT="$(cat "$WORK/projection.py")"

mkdir -p "$WORK/home"
run_projection() {
    local allow="$1" ledger="$2"
    (cd / && env -i PATH="/usr/bin:/bin" HOME="$WORK/home" TMPDIR="$WORK" LANG="en_US.UTF-8" \
        TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS="$allow" "$VENV_PYTHON" -c "$SCRIPT" "$ledger") \
        > "$WORK/out.json" 2> "$WORK/err.txt"
}

# --- Python backend ---------------------------------------------------------------------------------------

PY="$WORK/py"
mkdir -p "$PY/eval" "$PY/currency" "$PY/bundled" "$PY/plain" "$PY/pythonpath" "$PY/autotest"
MARKER="$WORK/MARKER"
cat > "$PY/eval/main.beancount" << EOF
plugin "beancount.plugins.commodity_attr" "__import__('os').system('touch \\"$MARKER\\"')"
2024-01-01 open Assets:Cash USD
EOF
cat > "$PY/currency/main.beancount" << 'EOF'
plugin "beancount.plugins.currency_accounts" "Equity:CurrencyAccounts"
2024-01-01 open Assets:Cash USD
2024-01-01 open Assets:Euro EUR
2024-01-02 * "Exchange"
  Assets:Cash  -110 USD @ 0.90909 EUR
  Assets:Euro   100.00 EUR
EOF
cat > "$PY/bundled/main.beancount" << 'EOF'
plugin "beancount.plugins.auto_accounts"
2024-01-02 * "Opened by auto_accounts"
  Assets:Cash   10 USD
  Equity:Opening
EOF
cat > "$PY/plain/main.beancount" << 'EOF'
2024-01-01 open Assets:Cash USD
2024-01-01 open Equity:Opening
2024-01-02 * "Plain"
  Assets:Cash   10 USD
  Equity:Opening
EOF
cat > "$PY/pythonpath/main.beancount" << 'EOF'
option "insert_pythonpath" "TRUE"
plugin "beancount.projects.export"
2024-01-01 open Assets:Cash USD
EOF
cat > "$PY/pythonpath/csv.py" << 'EOF'
import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "MARKER"), "w").write("planted csv.py ran\n")
raise ImportError("probe")
EOF
# A plugin the allowlist keeps: only taking the ledger folder off sys.path stops its import of unittest.
cat > "$PY/autotest/main.beancount" << 'EOF'
option "insert_pythonpath" "TRUE"
plugin "beancount.plugins.auto_test"
2024-01-01 open Assets:Cash USD
EOF
cat > "$PY/autotest/unittest.py" << 'EOF'
import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "MARKER"), "w").write("planted unittest.py ran\n")
raise ImportError("probe")
EOF

rm -f "$MARKER"
run_projection 1 "$PY/eval/main.beancount"
if [ -e "$MARKER" ]; then
    control "commodity_attr evals its config when Run Ledger Plugins is on"
else
    control_missed "commodity_attr did not run the payload with Run Ledger Plugins on"
fi

rm -f "$MARKER"
run_projection 0 "$PY/eval/main.beancount"
status=$?
if [ -e "$MARKER" ]; then
    fail "a config-carrying bundled plugin ran with Run Ledger Plugins off"
elif [ "$status" -ne 0 ]; then
    fail "the ledger with commodity_attr did not load (exit $status): $(head -c 300 "$WORK/err.txt")"
elif ! grep -F -q "not run: beancount.plugins.commodity_attr" "$WORK/out.json"; then
    fail "commodity_attr was not reported as not run"
else
    pass "commodity_attr with a config is not run and is reported"
fi

run_projection 0 "$PY/currency/main.beancount"
status=$?
if [ "$status" -ne 0 ]; then
    fail "the ledger with currency_accounts did not load (exit $status): $(head -c 300 "$WORK/err.txt")"
elif ! grep -F -q "not run: beancount.plugins.currency_accounts" "$WORK/out.json"; then
    fail "currency_accounts was not reported as not run"
else
    pass "currency_accounts with a config loads and is reported"
fi

run_projection 0 "$PY/bundled/main.beancount"
status=$?
if [ "$status" -ne 0 ]; then
    fail "a bundled plugin with no config did not run (exit $status): $(head -c 300 "$WORK/err.txt")"
elif grep -F -q "not run:" "$WORK/out.json"; then
    fail "auto_accounts with no config was reported as not run"
else
    pass "a bundled plugin with no config still runs"
fi

run_projection 0 "$PY/plain/main.beancount"
status=$?
if [ "$status" -ne 0 ]; then
    fail "a ledger with no plugin did not load (exit $status): $(head -c 300 "$WORK/err.txt")"
else
    pass "a ledger with no plugin loads"
fi

rm -f "$PY/pythonpath/MARKER"
run_projection 1 "$PY/pythonpath/main.beancount"
if [ -e "$PY/pythonpath/MARKER" ]; then
    control "with Run Ledger Plugins on, insert_pythonpath lets beancount.projects.export import a planted csv.py"
else
    control_missed "the planted csv.py did not run with Run Ledger Plugins on"
fi
rm -f "$PY/pythonpath/MARKER"
run_projection 0 "$PY/pythonpath/main.beancount"
status=$?
if [ -e "$PY/pythonpath/MARKER" ]; then
    fail "a planted csv.py ran through insert_pythonpath with Run Ledger Plugins off"
elif [ "$status" -ne 0 ]; then
    fail "the insert_pythonpath ledger did not load (exit $status): $(head -c 300 "$WORK/err.txt")"
elif ! grep -F -q "not run: beancount.projects.export" "$WORK/out.json"; then
    fail "beancount.projects.export was not reported as not run"
else
    pass "beancount.projects.export with insert_pythonpath is not run, and the planted csv.py stays unread"
fi

rm -f "$PY/autotest/MARKER"
run_projection 1 "$PY/autotest/main.beancount"
if [ -e "$PY/autotest/MARKER" ]; then
    control "with Run Ledger Plugins on, insert_pythonpath lets beancount.plugins.auto_test import a planted unittest.py"
else
    control_missed "the planted unittest.py did not run with Run Ledger Plugins on"
fi
rm -f "$PY/autotest/MARKER"
run_projection 0 "$PY/autotest/main.beancount"
if [ -e "$PY/autotest/MARKER" ]; then
    fail "a planted unittest.py ran through insert_pythonpath with Run Ledger Plugins off"
else
    pass "beancount.plugins.auto_test runs without the ledger folder on sys.path, so the planted unittest.py stays unread"
fi

# --- rledger -------------------------------------------------------------------------------------------

RLEDGER="$(command -v rledger 2> /dev/null || true)"
if [ -z "$RLEDGER" ]; then
    echo "SKIP  rledger is not on PATH"
    skipped=$((skipped + 1))
fi

SANDBOX=""
PROFILE="(version 1)(allow default)(deny network*)
(deny file-write* (require-all (require-not (subpath \"$REAL_WORK\")) (require-not (subpath \"/dev\"))))"
if [ -n "$RLEDGER" ] && command -v sandbox-exec > /dev/null 2>&1 &&
    sandbox-exec -p "$PROFILE" /usr/bin/true 2> /dev/null; then
    SANDBOX="yes"
elif [ -n "$RLEDGER" ]; then
    echo "SKIP  sandbox-exec is unavailable, so rledger plugin rows do not run (they would download a runtime)"
    skipped=$((skipped + 1))
fi

query_options=(query -f json --no-errors)
if [ -n "$RLEDGER" ]; then
    case "$("$RLEDGER" query --help 2>&1)" in *--no-cache*) query_options+=(--no-cache) ;; esac
fi
mkdir -p "$WORK/rhome"
# The app's argv, environment and cwd. The venv comes first on PATH, so rledger's own python3 lookup works
# without the Command Line Tools.
run_rledger_in() {
    local cwd="$1"
    shift
    (cd "$cwd" && sandbox-exec -p "$PROFILE" env -i PATH="$WORK/venv/bin:/usr/bin:/bin" HOME="$WORK/rhome" \
        TMPDIR="$WORK" "$RLEDGER" "$@") > "$WORK/rledger.txt" 2>&1
}
run_rledger_plain() {
    (cd / && env -i PATH="/usr/bin:/bin" HOME="$WORK/rhome" TMPDIR="$WORK" "$RLEDGER" "$@") > "$WORK/rledger.txt" 2>&1
}
# The driver runs both: `query` refuses a ledger with a parse error, while `check` still runs its plugins.
rledger_runs_plugin() {
    run_rledger_in "${2:-/}" "${query_options[@]}" -- "$1" "SELECT account FROM #accounts"
    grep -E -q "Loading Python plugin runtime|WASM plugin" "$WORK/rledger.txt" && return 0
    run_rledger_in "${2:-/}" check --no-cache -f json -- "$1"
    grep -E -q "Loading Python plugin runtime|WASM plugin" "$WORK/rledger.txt"
}

if [ -n "$RLEDGER" ]; then
    SECRET="tablepro-probe-secret-$$"
    echo "$SECRET" > "$WORK/secret.txt"
    run_rledger_plain "${query_options[@]}" "$PY/plain/main.beancount" "-F$WORK/secret.txt"
    if grep -F -q "$SECRET" "$WORK/rledger.txt"; then
        control "without --, the query -F<file> reads that file"
    else
        control_missed "without --, the query -F<file> did not read the file on this rledger"
    fi
    run_rledger_plain "${query_options[@]}" -- "$PY/plain/main.beancount" "-F$WORK/secret.txt"
    status=$?
    if grep -F -q "$SECRET" "$WORK/rledger.txt"; then
        fail "rledger read the file a -F query named, even after --"
    elif [ "$status" -eq 0 ]; then
        fail "rledger accepted -F<file> as a BQL query"
    else
        pass "after --, rledger reads -F<file> as a query and refuses it"
    fi
    run_rledger_plain "${query_options[@]}" -- "$PY/plain/main.beancount" "SELECT account FROM #accounts"
    if [ $? -eq 0 ] && grep -F -q "Assets:Cash" "$WORK/rledger.txt"; then
        pass "a BQL query after -- still runs"
    else
        fail "a BQL query after -- did not run: $(head -c 300 "$WORK/rledger.txt")"
    fi
    run_rledger_plain check --no-cache -f json -- "$PY/plain/main.beancount"
    if grep -F -q '"diagnostics"' "$WORK/rledger.txt"; then
        pass "rledger check takes -- before the ledger"
    else
        fail "rledger check did not take --: $(head -c 300 "$WORK/rledger.txt")"
    fi
fi

# rledger looks a module plugin name up with the host python3's find_spec, which imports the parent package
# from the cwd, so the driver runs it in `/`.
FX="$WORK/fx"
mkdir -p "$FX/cwd"
printf '%s\n' 'plugin "probepkg.mod"' "2024-01-01 open Assets:Cash USD" > "$FX/cwd/main.beancount"
cat > "$FX/cwd/probepkg.py" << 'EOF'
import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "CWDMARKER"), "w").write("imported from the cwd\n")
EOF

if [ -n "$SANDBOX" ]; then
    rm -f "$FX/cwd/CWDMARKER"
    rledger_runs_plugin "$FX/cwd/main.beancount" "$FX/cwd"
    if [ -e "$FX/cwd/CWDMARKER" ]; then
        control "with cwd at the ledger folder, rledger's python3 imports a module planted beside the ledger"
    else
        control_missed "with cwd at the ledger folder, the planted module was not imported"
    fi
    rm -f "$FX/cwd/CWDMARKER"
    rledger_runs_plugin "$FX/cwd/main.beancount" /
    if [ -e "$FX/cwd/CWDMARKER" ]; then
        fail "with cwd /, rledger's python3 still imported the module planted beside the ledger"
    else
        pass "with cwd /, rledger's python3 does not import a module planted beside the ledger"
    fi
fi

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures case(s) failed." >&2
    exit 1
fi
if [ "$controls_missed" -ne 0 ]; then
    inconclusive "$controls_missed control(s) did not reproduce, so a pass above proves less"
fi
if [ "$skipped" -ne 0 ]; then
    inconclusive "$skipped part(s) were skipped"
fi
echo "PASS: every case holds."
