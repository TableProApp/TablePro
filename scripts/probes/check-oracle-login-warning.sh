#!/usr/bin/env bash
#
# Check that a login whose password is in its grace period connects and reports the server's warning.
#
# Oracle answers such a login with ORA-28002 (ORA-28098 from 23ai) sent as a warning message, twice, ahead of the
# authentication reply (measured on 23.26). oracle-nio once read that message with the wrong field widths and waited
# for bytes that never came, so the login hung until its deadline. This creates a user whose password expires a second
# after it is set, waits for it to enter its grace period, logs in through the same OracleCoreConnection the app uses,
# and checks that the login succeeds within its deadline, that the warning names the expiry, that the session answers
# a query, and that an ordinary login reports no warning.
#
# Usage:
#   scripts/probes/check-oracle-login-warning.sh [host] [port] [service] [admin user] [admin password]
#
# Defaults suit a throwaway Oracle Free container, whose SYSTEM account can create users and profiles:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# Every object it creates is named TP_GRACE_PROBE and dropped again. Exits non-zero on a disagreement, 3 when a
# prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
ADMIN_USER="${4:-system}"
ADMIN_PASSWORD="${5:-probe_pw}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
let host = arguments[1]
let port = Int(arguments[2]) ?? 1_521
let service = arguments[3]
let probeUser = "TP_GRACE_PROBE"
let probePassword = "Grace_Probe_1"

func options(user: String, password: String) -> OracleConnectionOptions {
    OracleConnectionOptions(
        host: host, port: port, user: user, password: password,
        identifierMode: .service, serviceName: service, loginTimeoutSeconds: 15
    )
}

let admin = OracleCoreConnection(options: options(user: arguments[4], password: arguments[5]))
do {
    try await admin.connect()
} catch {
    print("cannot connect as \(arguments[4]): \(error)")
    exit(3)
}

func run(_ sql: String) async {
    _ = try? await admin.executeQuery(sql)
}

await run("DROP USER \(probeUser) CASCADE")
await run("DROP PROFILE \(probeUser)")
do {
    _ = try await admin.executeQuery(
        "CREATE PROFILE \(probeUser) LIMIT PASSWORD_LIFE_TIME 1/24/60/60 PASSWORD_GRACE_TIME 7"
    )
    _ = try await admin.executeQuery("CREATE USER \(probeUser) IDENTIFIED BY \"\(probePassword)\" PROFILE \(probeUser)")
    _ = try await admin.executeQuery("GRANT CREATE SESSION TO \(probeUser)")
} catch {
    print("cannot create the probe user and profile: \(error)")
    exit(3)
}
try? await Task.sleep(for: .seconds(3))

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

let graced = OracleCoreConnection(options: options(user: probeUser, password: probePassword))
let started = ContinuousClock.now
do {
    try await graced.connect()
    let elapsed = ContinuousClock.now - started
    check(elapsed < .seconds(10), "a login in its grace period connects (\(elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))))")
    let warning = graced.loginWarning ?? ""
    check(warning.hasPrefix("ORA-28002") || warning.hasPrefix("ORA-28098"), "the login reports \(String(reflecting: graced.loginWarning))")
    let answer = try? await graced.executeQuery("SELECT 'alive' FROM DUAL")
    check(answer?.rows.first?.first?.stringValue == "alive", "the session answers a query")
    graced.disconnect()
} catch {
    check(false, "a login in its grace period connects: \(error)")
}

check(admin.loginWarning == nil, "an ordinary login reports no warning")

await run("DROP USER \(probeUser) CASCADE")
await run("DROP PROFILE \(probeUser)")
admin.disconnect()
print(disagreements == 0 ? "\nall checks hold" : "\n\(disagreements) disagreement(s)")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$ADMIN_USER" "$ADMIN_PASSWORD" 2> /dev/null
