#!/usr/bin/env bash
#
# Check how AWSEndpointHost finds the RDS endpoint behind a custom DNS name, against the system resolver: the
# hop-by-hop CNAME walk TablePro signs and dials, beside what getaddrinfo's AI_CANONNAME reports, which is the end
# of the chain (an ec2, vpce or replica name) and never the name a token is signed for.
#
# Usage:
#   apple/scripts/probes/check-rds-cname-chain.sh [name...]
#
# With no names it uses public CNAMEs that point at RDS instances. Needs network access.
# Exits non-zero when a default name no longer leads to an RDS endpoint, 3 when a prerequisite is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AWS="$ROOT/Plugins/TableProPluginKit/AWS"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR
command -v xcrun > /dev/null || { echo "xcrun not found" >&2; exit 3; }

cat > "$WORK/main.swift" << 'SWIFT'
import Darwin
import Foundation

struct Hop: CNAMEResolving {
    let inner = SystemCNAMEResolver()

    func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup {
        let started = ContinuousClock.now
        let lookup = await inner.cnameTarget(of: name, within: timeout)
        print("  CNAME \(name) -> \(lookup) (\(started.duration(to: .now)))")
        return lookup
    }
}

func canonicalName(_ name: String) -> String {
    var hints = addrinfo()
    hints.ai_flags = AI_CANONNAME
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &result) == 0, let result else { return "lookup failed" }
    defer { freeaddrinfo(result) }
    return result.pointee.ai_canonname.map { String(cString: $0) } ?? "none"
}

@main
enum Probe {
    static func main() async {
        let checksDefaults = CommandLine.arguments.contains("--defaults")
        var failures = 0
        for name in CommandLine.arguments.dropFirst() where name != "--defaults" {
            print("== \(name)")
            print("  AI_CANONNAME: \(canonicalName(name))")
            switch await AWSEndpointHost.rdsEndpoint(behind: name, resolver: Hop(), within: .seconds(10)) {
            case .found(let endpoint):
                print("  signs and dials: \(endpoint), region \(AWSEndpointHost.rdsRegion(forHost: endpoint) ?? "none")")
            case .notFound:
                print("  signs and dials: the name as typed")
                if checksDefaults { failures += 1 }
            case .failed:
                print("  the lookup failed")
                failures += 1
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
SWIFT

xcrun swiftc -swift-version 6 -parse-as-library -module-name CNAMEProbe \
    "$AWS/AWSEndpointHost.swift" "$AWS/CNAMEResolver.swift" "$AWS/AWSPartition.swift" "$AWS/AWSAuthError.swift" \
    "$WORK/main.swift" -o "$WORK/probe" 2> "$WORK/build.log" || {
    cat "$WORK/build.log" >&2
    exit 3
}

if [ "$#" -eq 0 ]; then
    "$WORK/probe" --defaults \
        users-mysql-1.machines.pythonanywhere-services.com \
        users-mysql-3.machines.pythonanywhere-services.com
else
    "$WORK/probe" "$@"
fi
