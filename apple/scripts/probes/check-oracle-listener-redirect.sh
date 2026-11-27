#!/usr/bin/env bash
#
# Check that a connect follows an Oracle listener's TNS redirect, and that one it may not follow names the target.
#
# A RAC SCAN listener, a shared server dispatcher or Connection Manager answers a CONNECT with a REDIRECT. From 19c the
# REDIRECT holds only the data length and the address comes in the DATA packet after it (measured on 23.26). This turns
# an Oracle Free container into a SCAN-style rig: a second listener on <redirect port> serves the instance, and the
# default listener on 1521 only knows it as a remote listener, so every connect to 1521 is redirected to
# 127.0.0.1:<redirect port>. It then connects through the same OracleCoreConnection the app uses and checks that the
# redirect is followed, that a tunneled connect refuses it and names the target, and that a refused port fails at once.
#
# Usage:
#   scripts/probes/check-oracle-listener-redirect.sh [container] [listener port] [redirect port]
#
# The container publishes 1521 on <listener port> and the redirect port on the same port number, since the Mac dials
# the address the listener names:
#   docker run -d --name oracle-redirect-probe -p 15211:1521 -p 15212:15212 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The listener settings are made in memory and do not survive a restart. Exits non-zero on a disagreement, 3 when a
# prerequisite is missing.

set -uo pipefail

CONTAINER="${1:-oracle-redirect-probe}"
LISTENER_PORT="${2:-15211}"
REDIRECT_PORT="${3:-15212}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v docker > /dev/null || {
    echo "docker not found" >&2
    exit 3
}
docker exec "$CONTAINER" true 2> /dev/null || {
    echo "container $CONTAINER is not running" >&2
    exit 3
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
command -v swift > /dev/null || {
    echo "swift not found" >&2
    exit 3
}

echo "Setting up LISTENER2 on $REDIRECT_PORT inside $CONTAINER"
docker exec -i "$CONTAINER" bash -s "$REDIRECT_PORT" <<'EOF' || exit 3
set -e
port="$1"
listener_ora="$ORACLE_HOME/network/admin/listener.ora"
if ! grep -q '^LISTENER2' "$listener_ora" 2> /dev/null; then
    printf '\nLISTENER2 = (DESCRIPTION_LIST=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=0.0.0.0)(PORT=%s))))\n' "$port" >> "$listener_ora"
fi
lsnrctl status LISTENER2 > /dev/null 2>&1 || lsnrctl start LISTENER2 > /dev/null
sqlplus -s / as sysdba > /dev/null <<SQL
whenever sqlerror exit failure
alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=$port))' scope=memory;
alter system set remote_listener='127.0.0.1:1521' scope=memory;
alter system register;
exit
SQL
EOF
sleep 5

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"
# Resolves to the dependency versions the app ships, not the newest ones.
cp "$ROOT/Packages/TableProOracle/Package.resolved" "$WORK/Package.resolved"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProOracle")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProOracleCore", package: "TableProOracle")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProOracleCore

let arguments = CommandLine.arguments
let listenerPort = Int(arguments[1]) ?? 15_211
let redirectPort = Int(arguments[2]) ?? 15_212

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

func options(port: Int, follows: Bool = true) -> OracleConnectionOptions {
    OracleConnectionOptions(
        host: "127.0.0.1", port: port, user: "probe", password: "probe_pw",
        identifierMode: .service, serviceName: "FREEPDB1", loginTimeoutSeconds: 15,
        followsListenerRedirects: follows
    )
}

let tunneled = OracleCoreConnection(options: options(port: listenerPort, follows: false))
do {
    try await tunneled.connect()
    check(false, "the listener on \(listenerPort) redirects (it accepted the connect instead)")
    tunneled.disconnect()
} catch let error as OracleCoreError {
    check(
        error == .listenerRedirectFailed(.throughTunnel, target: "127.0.0.1:\(redirectPort)"),
        "a connect that may not follow the redirect names its target: \(error.errorDescription ?? "")"
    )
} catch {
    check(false, "a connect that may not follow the redirect names its target: \(error)")
}

let followed = OracleCoreConnection(options: options(port: listenerPort))
do {
    try await followed.connect()
    let answer = try? await followed.executeQuery("SELECT 'redirected' FROM DUAL")
    check(answer?.rows.first?.first?.stringValue == "redirected", "the redirect is followed and the session answers")
    followed.disconnect()
} catch {
    check(false, "the redirect is followed: \((error as? OracleCoreError)?.errorDescription ?? "\(error)")")
}

let refused = OracleCoreConnection(options: options(port: 1))
let started = ContinuousClock.now
do {
    try await refused.connect()
    check(false, "a refused port fails")
} catch {
    let elapsed = ContinuousClock.now - started
    check(
        (error as? OracleCoreError) == .connectionRefused && elapsed < .seconds(3),
        "a refused port says so at once (\(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))): \(error)"
    )
}

print(disagreements == 0 ? "\nall checks hold" : "\n\(disagreements) disagreement(s)")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$LISTENER_PORT" "$REDIRECT_PORT" 2> /dev/null
