#!/usr/bin/env bash
# T-DWN for the connection library and its profiles (core ADR 0010, slices 1b and 2): the previous stable reads what
# this build wrote, and this build takes in what the previous stable wrote after it. Both apps run in one storage
# sandbox, one at a time. The previous stable shows which connections it read in the standing it records
# (SyncMetadataStorage), this build in the core's store and its mirror record, and the files and their integrity tags
# show what each wrote.
#
# Usage: check-library-downgrade.sh <this build's TablePro.app> <previous stable's TablePro.app>
set -euo pipefail

NEW_APP="$(cd "${1:?the TablePro.app of this build}" && pwd)"
OLD_APP="$(cd "${2:?the TablePro.app of the previous stable}" && pwd)"
# Another copy of either app would hold the sandbox's files; an installed TablePro elsewhere keeps to its own.
for app in "$NEW_APP" "$OLD_APP"; do
    if pgrep -f "^$app/Contents/MacOS/TablePro" >/dev/null; then
        echo "Quit $app first: a run here must be the only one" >&2
        exit 2
    fi
done
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

# The ids this build holds in the core's store, once the mirror record says its last write reached both sides.
core_ids() {
    defaults export "$SUITE" - 2>/dev/null | python3 -I -c '
import hashlib, json, plistlib, sys
try:
    record = json.loads(plistlib.loads(sys.stdin.buffer.read())["com.TablePro.library.mirrorRecord"])
    data = open(sys.argv[1], "rb").read()
except Exception:
    sys.exit(0)
if record.get("legacyBehind", True) or record.get("core") != hashlib.sha256(data).hexdigest():
    sys.exit(0)
print(",".join(sorted(entry["id"].upper() for entry in json.loads(data)["connections"])))
' "$SUPPORT/Core/connections.json"
}

# What a run read: the previous stable records the standing of what it read, this build writes it to both sides.
read_ids() {
    if [ "$1" = "$OLD_APP" ]; then standing; else core_ids; fi
}

# Launches the app until it has read the library, then stops it.
run() {
    local app="$1" expected="$2"
    defaults delete "$SUITE" "$STANDING" >/dev/null 2>&1 || true
    TABLEPRO_UI_TEST_SANDBOX="$SANDBOX" "$app/Contents/MacOS/TablePro" >/dev/null 2>&1 &
    PID=$!
    for _ in $(seq 1 90); do
        [ "$(read_ids "$app")" = "$expected" ] && break
        sleep 1
    done
    sleep 3
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
    [ "$(read_ids "$app")" = "$expected" ] || fail "$(basename "$(dirname "$(dirname "$app")")") read $(read_ids "$app"), expected $expected"
}

# Whether the file's integrity tag is the one TablePro writes with the sandbox's key. The core's file is tagged over
# the digest the core returns for its bytes.
tagged() {
    python3 -I - "$SUPPORT/keychain.json" "$1" "${2:-bytes}" <<'PY'
import base64, hashlib, hmac, json, sys
key = base64.b64decode(json.load(open(sys.argv[1]))["connectionStoreIntegrity"])
data = open(sys.argv[2], "rb").read()
if sys.argv[3] == "digest":
    data = b"sha256:" + hashlib.sha256(data).hexdigest().encode()
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

# Profile names in a file: the core's library under `key`, or the previous stable's list.
profile_names() {
    python3 -I - "$1" "$2" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
entries = document.get(sys.argv[2], []) if isinstance(document, dict) else document
print("|".join(sorted(entry["name"] for entry in entries)))
PY
}

# The SSH profiles the previous stable keeps in UserDefaults.
ssh_profile_names() {
    defaults export "$SUITE" - 2>/dev/null | python3 -I -c '
import json, plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read()).get("com.TablePro.sshProfiles")
print("|".join(sorted(entry["name"] for entry in json.loads(data))) if data else "")
'
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
SSH_PROFILE=55555555-5555-5555-5555-555555555555
CREDENTIAL_PROFILE=66666666-6666-6666-6666-666666666666

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
# And the profiles it kept: SSH ones in UserDefaults, credential ones in their own file.
defaults write "$SUITE" com.TablePro.sshProfiles -data "$(python3 -I -c '
import json, sys
print(json.dumps([{"id": sys.argv[1], "name": "Bastion", "host": "bastion.internal", "port": 22, "username": "deploy",
    "authMethod": "Password", "privateKeyPath": "", "agentSocketPath": "", "jumpHosts": [], "totpMode": "none",
    "totpAlgorithm": "SHA1", "totpDigits": 6, "totpPeriod": 30}]).encode().hex())
' "$SSH_PROFILE")"
python3 -I - "$SUPPORT/credentialProfiles.json" "$CREDENTIAL_PROFILE" <<'PY'
import json, sys
json.dump([{"id": sys.argv[2], "name": "Readers", "username": "reader", "passwordMode": {"kind": "prompt"},
            "secureFieldIds": [], "sortOrder": 0}], open(sys.argv[1], "w"))
PY

run "$NEW_APP" "$FIRST,$SECOND"
[ -f "$SUPPORT/Core/connections.json" ] || fail "this build kept no library in the core"
[ "$(profile_names "$SUPPORT/Core/connections.json" ssh_profiles)" = "Bastion" ] || fail "the core holds no SSH profile"
[ "$(profile_names "$SUPPORT/Core/connections.json" credential_profiles)" = "Readers" ] || fail "the core holds no credential profile"
[ "$(profile_names "$SUPPORT/credentialProfiles.json" -)" = "Readers" ] || fail "credentialProfiles.json lost its profile"
[ "$(ssh_profile_names)" = "Bastion" ] || fail "the previous stable's SSH profiles were not kept"
[ "$(names "$SUPPORT/Core/connections.json")" = "billing|reports" ] || fail "the core holds another library"
[ "$(orders "$SUPPORT/connections.json" sortOrder)" = "0,1" ] || fail "this build's first write did not reach connections.json"
[ "$(orders "$SUPPORT/Core/connections.json" safe_mode)" = "alert_full,read_only" ] || fail "the core lost a Safe Mode level"
tagged "$SUPPORT/connections.json" || fail "this build wrote connections.json without a tag the previous stable trusts"
tagged "$SUPPORT/Core/connections.json" digest || fail "this build left the core's store untagged"
MIRRORED="$(shasum -a 256 "$SUPPORT/connections.json")"
PROFILES_MIRRORED="$(shasum -a 256 "$SUPPORT/credentialProfiles.json")"

run "$OLD_APP" "$FIRST,$SECOND"
[ "$(shasum -a 256 "$SUPPORT/connections.json")" = "$MIRRORED" ] || fail "the previous stable rewrote what this build mirrored"
[ "$(shasum -a 256 "$SUPPORT/credentialProfiles.json")" = "$PROFILES_MIRRORED" ] || fail "the previous stable rewrote the credential profiles"
[ "$(ssh_profile_names)" = "Bastion" ] || fail "the previous stable dropped the SSH profiles this build mirrored"

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
! tagged "$SUPPORT/Core/connections.json" digest || fail "the core trusts a library written outside its tag"

run "$NEW_APP" "$FIRST,$SECOND,$THIRD"
[ "$(names "$SUPPORT/Core/connections.json")" = "$EDITED" ] || fail "the previous stable's edit did not stay in the core"
[ "$(profile_names "$SUPPORT/Core/connections.json" credential_profiles)" = "Readers" ] || fail "the core lost the credential profile"
[ "$(ssh_profile_names)" = "Bastion" ] || fail "the SSH profiles did not stay in the previous stable's store"

echo "PASS: both builds read one library across a downgrade and an upgrade"
