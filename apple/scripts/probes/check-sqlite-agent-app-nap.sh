#!/usr/bin/env bash
#
# Shows whether App Nap delays the Remote SQLite heartbeat past the agent's 60 s watchdog.
#
# Builds the SQLite driver's sources into a small app, connects it to the shipped agent (local python3, the real
# watchdog) over the loopback relay the driver tests use, launches it in the background so it is never frontmost, and
# leaves it hidden and idle. It records each heartbeat as it reaches the relay, then runs one statement. A second
# copy with the heartbeat off is the control: the watchdog ends its session after about 60 s.
#
# The script prints the main thread's scheduling priority once the apps are hidden: 4 means App Nap took them.
# Exit 1 when the session with heartbeats did not survive, 3 when the probe cannot run.
#
# Usage:
#   scripts/probes/check-sqlite-agent-app-nap.sh [--minutes N]
#
#   --minutes   how long the app stays hidden, default 7

set -uo pipefail

MINUTES=7
while [ $# -gt 0 ]; do
    case "$1" in
        --minutes) MINUTES="${2:?}"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 3 ;;
    esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$ROOT/Libs/libsqlite3_vendored.a" ] || { echo "run scripts/download-libs.sh first" >&2; exit 3; }
command -v python3 > /dev/null || { echo "python3 not found" >&2; exit 3; }

WORK="$(mktemp -d)" || exit 3
[ -n "$WORK" ] || exit 3
cleanup() {
    pkill -f "$WORK/" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

SOURCES="$WORK/Sources/NapProbe"
mkdir -p "$SOURCES"
for source in "$ROOT"/Plugins/SQLiteDriverPlugin/*.swift "$ROOT"/Plugins/SharedSpill/*.swift; do
    ln -s "$source" "$SOURCES/driver_$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox; do
    [ -f "$ROOT/Plugins/Shared/$shared.swift" ] && ln -s "$ROOT/Plugins/Shared/$shared.swift" "$SOURCES/shared_$shared.swift"
done
for helper in TablePro/Core/RemoteSQLite/RemoteSQLiteAgentSource.swift TablePro/Core/RemoteSQLite/RemoteSQLiteWire.swift \
    Plugins/SQLiteDriverTests/SQLiteAgentLoopback.swift; do
    ln -s "$ROOT/$helper" "$SOURCES/agent_$(basename "$helper")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NapProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(
            name: "NapProbe",
            dependencies: [
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProSQLGrammar", package: "TableProCore"),
                .product(name: "TableProProcess", package: "TableProCore"),
                .product(name: "CSQLite", package: "TableProCore"),
                .product(name: "TableProSQLiteCore", package: "TableProCore"),
                .product(name: "TableProSQLQuoting", package: "TableProCore"),
                .product(name: "TableProSQLVocabulary", package: "TableProCore"),
                .product(name: "TableProWireIO", package: "TableProCore"),
            ],
            path: "Sources/NapProbe",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility")],
            linkerSettings: [.unsafeFlags(["$ROOT/Libs/libsqlite3_vendored.a"])]
        ),
    ]
)
MANIFEST

cat > "$SOURCES/main.swift" << 'SWIFT'
import AppKit
import Foundation
import TableProPluginKit

// Arguments: <log file> <minutes hidden> <heartbeat seconds>.
final class NapProbe: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logPath: String
    private let minutes: Double
    private let heartbeat: TimeInterval
    private let started = ContinuousClock.now

    init(arguments: [String]) {
        logPath = arguments[1]
        minutes = Double(arguments[2]) ?? 7
        heartbeat = TimeInterval(arguments[3]) ?? 15
    }

    func log(_ line: String) {
        let elapsed = (ContinuousClock.now - started).components
        let text = String(format: "%8.2f %@\n", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, line)
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await self.run() }
    }

    private func run() async {
        let path = NSTemporaryDirectory() + "nap-probe-\(UUID().uuidString).db"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let loopback = try SQLiteAgentLoopback()
            defer { loopback.close() }
            let fields = [SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue]
            guard let budget = SQLiteAgentHelloBudget.forAgent(additionalFields: fields) else { return }
            let backend = SQLiteAgentBackend(
                host: "127.0.0.1", port: loopback.port, path: path, token: loopback.token,
                helloBudget: budget, heartbeatInterval: heartbeat
            )
            let driver = SQLitePluginDriver(
                config: DriverConnectionConfig(
                    host: "127.0.0.1", port: loopback.port, username: "", password: "", database: path,
                    additionalFields: fields
                ),
                backend: backend
            )
            try await driver.connect()
            _ = try await driver.execute(query: "SELECT 1")
            await MainActor.run { NSApp.hide(nil) }
            log("connected and hidden, heartbeat \(heartbeat) s")

            let deadline = ContinuousClock.now + .seconds(minutes * 60)
            var lastCount = loopback.heartbeats
            var lastBeat = ContinuousClock.now
            var maxGap: Duration = .zero
            var reported = false
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(500))
                if loopback.heartbeats != lastCount {
                    maxGap = max(maxGap, ContinuousClock.now - lastBeat)
                    lastCount = loopback.heartbeats
                    lastBeat = .now
                }
                if !reported, !loopback.agentIsRunning {
                    reported = true
                    log("agent exited \(ContinuousClock.now - lastBeat) after the last heartbeat")
                }
            }
            let answer: String
            do {
                answer = try await driver.execute(query: "SELECT 2").rows.first?.first?.asText ?? "no row"
            } catch {
                answer = "failed: \(error)"
            }
            log("heartbeats \(loopback.heartbeats), longest gap \(maxGap), agent running \(loopback.agentIsRunning), SELECT 2: \(answer)")
            await backend.close()
        } catch {
            log("probe failed: \(error)")
        }
        await MainActor.run { NSApp.terminate(nil) }
    }
}

let probe = NapProbe(arguments: CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = probe
app.run()
SWIFT

echo "building the probe (the first build takes a few minutes)"
(cd "$WORK" && swift build -c release > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -30 >&2
    exit 3
}

for name in NapProbe NapProbeControl; do
    mkdir -p "$WORK/$name.app/Contents/MacOS"
    cp "$WORK/.build/release/NapProbe" "$WORK/$name.app/Contents/MacOS/NapProbe"
    cat > "$WORK/$name.app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NapProbe</string>
<key>CFBundleIdentifier</key><string>local.probe.$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
    codesign -s - --force "$WORK/$name.app" > /dev/null 2>&1
    : > "$WORK/$name.log"
done

# -g keeps them out of the front: the frontmost app never naps.
open -g -n "$WORK/NapProbe.app" --args "$WORK/NapProbe.log" "$MINUTES" 15
open -g -n "$WORK/NapProbeControl.app" --args "$WORK/NapProbeControl.log" 2 3600
sleep 90
for name in NapProbe NapProbeControl; do
    pid="$(pgrep -f "$WORK/$name.app/Contents" | head -1)"
    [ -n "$pid" ] && echo "$name main thread priority after 90 s hidden: $(ps -M -o pri -p "$pid" | awk 'NR == 2 { print $NF }')"
done
echo "waiting $MINUTES minutes"
while pgrep -f "$WORK/NapProbe.app/Contents" > /dev/null || pgrep -f "$WORK/NapProbeControl.app/Contents" > /dev/null; do
    sleep 5
done
echo "with heartbeats:"
cat "$WORK/NapProbe.log"
echo "control, heartbeat off:"
cat "$WORK/NapProbeControl.log"
grep -q "agent running true, SELECT 2: 2" "$WORK/NapProbe.log" || exit 1
