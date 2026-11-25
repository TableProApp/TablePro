#!/usr/bin/env bash
# T-DWN for the connection library (core ADR 0010, slices 1b and 2): the previous stable reads what this build wrote,
# and this build takes in what the previous stable wrote after it. Both apps run in one storage sandbox, one at a
# time. Each run shows which connections it read in the standing it records (SyncMetadataStorage), and the files and
# their integrity tags show what it wrote.
#
# Usage: check-library-downgrade.sh <this build's TablePro.app> <previous stable's TablePro.app>
set -euo pipefail

NEW_APP="$(cd "${1:?this build's TablePro.app}" && pwd)"
OLD_APP="$(cd "${2:?the previous stable's TablePro.app}" && pwd)"
if pgrep -x TablePro >/dev/null; then
    echo "Quit every TablePro first: a run here must be the only one" >&2
    exit 2
fi
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-library-downgrade.XXXXXX")"
SUPPORT="$SANDBOX/TablePro"
mkdir -p "$SUPPORT"
touch "$SUPPORT/.defaults-suite"

# PluginHostStorage.suiteName(forSandboxAt:): FNV-1a over the sandbox path.
SUITE="$(python3 -I -c '
import sys
h = 0xcbf29ce484222325
for b in sys.argv[1].encode():
    h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print("com.TablePro.uitest.%016x" % h)
' "$SANDBOX")"
STANDING=com.TablePro.sync.connectionsKnownToSync

cleanup() {
    [ -z "${PID:-}" ] || kill "$PID" 2>/dev/null || true
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

standing() {
    defaults read "$SUITE" "$STANDING" 2>/dev/null | tr -d ' (),"\n' | tr '[:lower:]' '[:upper:]' | fold -w 36 | sort | paste -sd, -
}

# Launches the app until it has read the library and recorded the standing of what it read, then stops it.
run() {
    local app="$1" expected="$2"
    defaults delete "$SUITE" "$STANDING" >/dev/null 2>&1 || true
    TABLEPRO_UI_TEST_SANDBOX="$SANDBOX" "$app/Contents/MacOS/TablePro" >/dev/null 2>&1 &
    PID=$!
    for _ in $(seq 1 90); do
        [ "$(standing)" = "$expected" ] && break
        sleep 1
    done
    sleep 3
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
    [ "$(standing)" = "$expected" ] || fail "$(basename "$(dirname "$(dirname "$app")")") read $(standing), expected $expected"
}

# Whether the file's integrity tag is the one TablePro writes with the sandbox's key.
tagged() {
    python3 -I - "$SUPPORT/keychain.json" "$1" <<'PY'
import base64, hashlib, hmac, json, sys
key = base64.b64decode(json.load(open(sys.argv[1]))["connectionStoreIntegrity"])
data = open(sys.argv[2], "rb").read()
try:
    tag = open(sys.argv[2] + ".hmac", "rb").read()
except FileNotFoundError:
    sys.exit(1)
sys.exit(0 if hmac.compare_digest(hmac.new(key, data, hashlib.sha256).digest(), tag) else 1)
PY
}

# The library as the previous stable decodes connections.json, or as the core keeps it.
names() {
    python3 -I - "$1" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
entries = document["connections"] if isinstance(document, dict) else document
print("|".join(sorted(entry["name"] for entry in entries)))
PY
}

orders() {
    python3 -I - "$1" "$2" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
entries = document["connections"] if isinstance(document, dict) else document
print(",".join(str(entry[sys.argv[2]]) for entry in sorted(entries, key=lambda entry: entry["name"])))
PY
}

GROUP=11111111-1111-1111-1111-111111111111
FIRST=22222222-2222-2222-2222-222222222222
SECOND=33333333-3333-3333-3333-333333333333
THIRD=44444444-4444-4444-4444-444444444444

# What the previous stable left: two connections in one group that never got a place, which this build numbers and
# saves at its first read, so it writes the previous stable's stores on its own.
python3 -I - "$SUPPORT/connections.json" "$FIRST" "$SECOND" "$GROUP" <<'PY'
import json, sys
path, first, second, group = sys.argv[1:]
def connection(id, name, host, level, color):
    return {"id": id, "name": name, "host": host, "port": 5432, "database": "app", "username": "app",
            "type": "PostgreSQL", "sshEnabled": False, "sshHost": "", "sshUsername": "", "sshAuthMethod": "Password",
            "sshPrivateKeyPath": "", "sslMode": "Disabled", "sslCaCertificatePath": "", "sslClientCertificatePath": "",
            "sslClientKeyPath": "", "color": color, "groupId": group, "tagIds": ["00000000-0000-0000-0000-000000000003"],
            "safeModeLevel": level, "externalAccess": "readOnly", "sortOrder": 0, "localOnly": False,
            "isSample": False, "isFavorite": False, "totpMode": "none", "totpAlgorithm": "SHA1", "totpDigits": 6,
            "totpPeriod": 30}
json.dump([connection(first, "billing", "billing.internal", "alertFull", "Red"),
           connection(second, "reports", "reports.internal", "readOnly", "Gray")], open(path, "w"))
PY
defaults write "$SUITE" com.TablePro.groups -data "$(python3 -I -c '
import json, sys
print(json.dumps([{"id": sys.argv[1], "name": "Clients", "color": "Purple", "sortOrder": 0}]).encode().hex())
' "$GROUP")"

run "$NEW_APP" "$FIRST,$SECOND"
[ -f "$SUPPORT/Core/connections.json" ] || fail "this build kept no library in the core"
[ "$(names "$SUPPORT/Core/connections.json")" = "billing|reports" ] || fail "the core holds another library"
[ "$(orders "$SUPPORT/connections.json" sortOrder)" = "0,1" ] || fail "this build's first write did not reach connections.json"
[ "$(orders "$SUPPORT/Core/connections.json" safe_mode)" = "alert_full,read_only" ] || fail "the core lost a Safe Mode level"
tagged "$SUPPORT/connections.json" || fail "this build wrote connections.json without a tag the previous stable trusts"
tagged "$SUPPORT/Core/connections.json" || fail "this build left the core's store untagged"
MIRRORED="$(shasum -a 256 "$SUPPORT/connections.json")"

run "$OLD_APP" "$FIRST,$SECOND"
[ "$(shasum -a 256 "$SUPPORT/connections.json")" = "$MIRRORED" ] || fail "the previous stable rewrote what this build mirrored"

# A write the previous stable makes itself: at launch it moves a library kept in UserDefaults into connections.json.
python3 -I - "$SUPPORT/connections.json" "$THIRD" <<'PY' > "$SANDBOX/legacy.json"
import json, sys
entries = json.load(open(sys.argv[1]))
entries[0]["name"] = "billing (edited on the previous stable)"
added = dict(entries[1], id=sys.argv[2], name="added on the previous stable", host="added.internal")
print(json.dumps(entries + [added]))
PY
defaults write "$SUITE" com.TablePro.connections -data "$(xxd -p "$SANDBOX/legacy.json" | tr -d '\n')"
defaults write "$SUITE" com.TablePro.connectionsMigratedToFile -bool false
run "$OLD_APP" "$FIRST,$SECOND,$THIRD"
EDITED="added on the previous stable|billing (edited on the previous stable)|reports"
[ "$(names "$SUPPORT/connections.json")" = "$EDITED" ] || fail "the previous stable did not write its edit"

run "$NEW_APP" "$FIRST,$SECOND,$THIRD"
[ "$(names "$SUPPORT/Core/connections.json")" = "$EDITED" ] || fail "this build did not take in the previous stable's edit"
# That build wrote connections.json without a tag, so the core must not vouch for what it brought.
! tagged "$SUPPORT/Core/connections.json" || fail "the core trusts a library written outside its tag"

run "$NEW_APP" "$FIRST,$SECOND,$THIRD"
[ "$(names "$SUPPORT/Core/connections.json")" = "$EDITED" ] || fail "the previous stable's edit did not stay in the core"

echo "PASS: both builds read one library across a downgrade and an upgrade"
