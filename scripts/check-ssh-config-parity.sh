#!/bin/bash
#
# Diffs TablePro's ~/.ssh/config resolution against the ssh binary on this machine.
#
# The parser and the resolver are a hand-written reimplementation of ssh_config(5), and nothing at
# runtime checks that they still agree with ssh. Every case below is one that did not: each was a
# real divergence, found by running these two side by side.
#
# Builds the real Core/SSH sources with swiftc into a small harness, runs each fixture through both
# it and `ssh -G`, and reports every field that differs.
#
# Usage: scripts/check-ssh-config-parity.sh [--keep]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d)"
cleanup() { [[ "$KEEP" == "1" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
[[ "$KEEP" == "1" ]] && echo "Working directory: $WORK"

if ! command -v ssh >/dev/null 2>&1; then
    echo "FAIL: no ssh binary on PATH" >&2
    exit 2
fi
echo "Comparing against: $(ssh -V 2>&1)"

# Leave whatever `xcode-select` points at alone. Forcing a path here broke the script on a
# machine with only the standard Xcode installed, before a single fixture ran.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in /Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer; do
        if [[ -d "$candidate/usr/bin" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

SSH_DIR="$REPO_ROOT/TablePro/Core/SSH"
MODELS_DIR="$REPO_ROOT/TablePro/Models/Connection"

# Only the files the resolution path needs; pulling in the whole target would drag in AppKit.
SOURCES=(
    "$SSH_DIR/SSHConfigParser.swift"
    "$SSH_DIR/SSHConfigResolver.swift"
    "$SSH_DIR/SSHConfigDocument.swift"
    "$SSH_DIR/SSHConfigTokens.swift"
    "$SSH_DIR/SSHPathUtilities.swift"
    "$SSH_DIR/SSHHostPatternMatcher.swift"
    "$SSH_DIR/SSHHostnameCanonicalizer.swift"
    "$SSH_DIR/SSHMatchExecutor.swift"
    "$SSH_DIR/SSHUnsupportedDirective.swift"
    "$SSH_DIR/ResolvedSSHTarget.swift"
    "$REPO_ROOT/TablePro/Extensions/Sequence+HexEncoded.swift"
    "$MODELS_DIR/SSHTypes.swift"
    "$MODELS_DIR/TOTPConfiguration.swift"
)

for source in "${SOURCES[@]}"; do
    if [[ ! -f "$source" ]]; then
        echo "FAIL: missing source $source" >&2
        exit 2
    fi
done

cat > "$WORK/harness.swift" <<'SWIFT'
import Foundation

@main
enum ParityHarness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("usage: harness <config> <host>\n".utf8))
            exit(2)
        }
        let document = SSHConfigParser.parseDocument(path: arguments[1])
        var config = SSHConfiguration()
        config.enabled = true
        config.host = arguments[2]
        let resolved = SSHConfigResolver.resolve(config, document: document)
        if let failure = resolved.expansionFailure {
            print("error \(failure)")
            return
        }
        print("hostname \(resolved.host)")
        print("port \(resolved.port)")
        if !resolved.username.isEmpty { print("user \(resolved.username)") }
        for file in resolved.identityFiles { print("identityfile \(file)") }
        if !resolved.agentSocketPath.isEmpty { print("identityagent \(resolved.agentSocketPath)") }
    }
}
SWIFT

echo "Building the harness from the shipping sources…"
if ! xcrun swiftc -O -parse-as-library \
    "${SOURCES[@]}" "$WORK/harness.swift" \
    -o "$WORK/harness" 2> "$WORK/build.log"; then
    echo "FAIL: harness did not build" >&2
    tail -40 "$WORK/build.log" >&2
    exit 2
fi

FIXTURES="$WORK/fixtures"
mkdir -p "$FIXTURES"

# Each fixture is a config plus the host to resolve. The comment names the defect it guards.
add_fixture() {
    local name="$1" host="$2" body="$3"
    printf '%s\n' "$body" > "$FIXTURES/$name.conf"
    printf '%s' "$host" > "$FIXTURES/$name.host"
}

# Hostname %h reaching getaddrinfo as two literal characters. (#2687)
add_fixture passthrough 'db.example.com' 'Host *.*
    Hostname %h'

# %h inside Hostname is the original host, and never chains onto an earlier Hostname.
add_fixture hostname_token 'short' 'Host short
    Hostname box.%h.example.com'

# Hostname is first-wins.
add_fixture hostname_first_wins 't1' 'Host t1
    Hostname a.example.com
Host t1
    Hostname zzz-%h'

# A trailing comment is not part of the value.
add_fixture trailing_comment 'db' 'Host db
    HostName db.example.com   # production
    Port 7777 # the tunnel
    User bob   # not a comment reader'

# A "#" that does not start an argument stays in the value.
add_fixture embedded_hash 'db' 'Host db
    HostName db.example.com#keepme'

# Host patterns match the host the connection named, not a substituted HostName.
add_fixture host_block_scope 'jump' 'Host jump
    HostName bastion.internal.example.com
Host *.internal.example.com
    User internaluser
    Port 2200'

# Match host does see the substituted hostname, and folds case.
add_fixture match_host_scope 'alias' 'Host alias
    HostName real.example.com
Match host REAL.example.com
    User matched'

# A negated Match criterion must exclude the host it names.
add_fixture negated_match 'excluded' 'Match !host excluded
    Port 6666'

# Match final supplies a default; it does not override an earlier value.
add_fixture match_final_first_wins 'target' 'Host *
    User firstuser
    Port 2200
Match final host target
    User finaluser
    Port 9999'

# A Host line is whitespace-separated; a comma is an ordinary character.
add_fixture host_comma_list 'a' 'Host a,b
    Port 2401'

# Tokens in IdentityFile, including the %C hash.
add_fixture identity_tokens 'tok' 'Host tok
    Hostname 127.0.0.1
    Port 2222
    User bob
    IdentityFile /keys/id_%r_%p_%n_%h_%u.pem
    IdentityFile /keys/tok_%C.pem'

# Match exec hands ${...} to the shell rather than expanding it, and sees the effective port.
add_fixture match_exec_env 'h' 'Match exec "test x${TABLEPRO_PARITY_MODE:-dev} = xdev"
    Port 6001'

# %p inside Match exec is the effective port, 22 when nothing set one.
add_fixture match_exec_port 'h' 'Match exec "test x%p = x22"
    Port 6002'

# Match !final is evaluated on the ordinary pass, where final is false.
add_fixture negated_final 'h' 'Match !final
    Port 6003'

# HostKeyAlias supplies %k.
add_fixture host_key_alias 'tok' 'Host tok
    Hostname 10.0.0.4
    HostKeyAlias key-name
    IdentityAgent /tmp/%k.sock'

# IdentityAgent takes the tilde and the token set.
add_fixture identity_agent 'tok' 'Host tok
    Hostname 10.0.0.5
    IdentityAgent ~/.agent_%h.sock'

# ssh -G prints IdentityFile and ProxyJump raw, so those fields are compared only where the
# fixture leaves them untokenized. Anything tokenized there is checked by the unit tests instead.
RAW_FIELD_FIXTURES="identity_tokens identity_agent host_key_alias"

# `ssh -G` always reports a user, defaulting to the local one. TablePro leaves it empty when no
# `User` directive matches, because the connection form supplies it and `buildAuthenticatedChain`
# asks for it by name when neither does. So a bare local username on ssh's side is not a value to
# compare against. No fixture sets `User` to the local username, which would make this drop a real
# one.
LOCAL_USER="$(id -un)"

FAILURES=0
CHECKED=0

for conf in "$FIXTURES"/*.conf; do
    name="$(basename "$conf" .conf)"
    host="$(cat "$FIXTURES/$name.host")"

    if [[ " $RAW_FIELD_FIXTURES " == *" $name "* ]]; then
        fields='^(hostname|port|user) '
    else
        fields='^(hostname|port|user|identityfile|identityagent) '
    fi

    ssh_out="$(ssh -F "$conf" -G "$host" 2>/dev/null | grep -E "$fields" | grep -v '^identityfile ~/.ssh/id_' | grep -v "^user ${LOCAL_USER}\$" | sort || true)"
    app_out="$("$WORK/harness" "$conf" "$host" 2>/dev/null | grep -E "$fields" | sort || true)"

    CHECKED=$((CHECKED + 1))
    if [[ "$ssh_out" == "$app_out" ]]; then
        echo "  ok    $name"
    else
        FAILURES=$((FAILURES + 1))
        echo "  DIFF  $name (host: $host)"
        diff <(printf '%s\n' "$ssh_out") <(printf '%s\n' "$app_out") \
            | sed 's/^/          /' || true
    fi
done

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $FAILURES of $CHECKED fixtures disagree with ssh"
    exit 1
fi
echo "PASS: all $CHECKED fixtures agree with ssh"
