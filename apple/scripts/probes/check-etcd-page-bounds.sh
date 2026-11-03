#!/usr/bin/env bash
# Registry drivers have no unit-test target, so compile the real query parser to check page bounds.
# Usage: lockf -k -t 540 /tmp/tablepro-heavy.lock apple/scripts/probes/check-etcd-page-bounds.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "$ROOT/../.analysis/etcd-page-bounds.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PLUGIN="$ROOT/Plugins/EtcdDriverPlugin"
KIT_SOURCES=()
while IFS= read -r file; do KIT_SOURCES+=("$file"); done < <(rg --files "$ROOT/Plugins/TableProPluginKit" -g '*.swift')
xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name TableProPluginKit \
    -emit-module-path "$WORK/TableProPluginKit.swiftmodule" -o "$WORK/libTableProPluginKit.dylib" "${KIT_SOURCES[@]}"
xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name TableProEtcdCore \
    -emit-module-path "$WORK/TableProEtcdCore.swiftmodule" -o "$WORK/libTableProEtcdCore.dylib" \
    "$ROOT"/Packages/TableProCore/Sources/TableProEtcdCore/*.swift
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let builder = EtcdQueryBuilder()
for (limit, offset) in [(-1, 0), (1, -1), (Int.max, 1), (1, Int.max), (Int.min, Int.min)] {
    let query = builder.buildBrowseQuery(prefix: "", sortColumns: [], limit: limit, offset: offset)
    precondition(EtcdQueryBuilder.parseRangeQuery(query) == nil, "Accepted invalid page bounds")
}
for (limit, offset) in [(0, 0), (100, 0), (100, 100), (Int.max, 0), (0, Int.max)] {
    let query = builder.buildBrowseQuery(prefix: "/app/", sortColumns: [], limit: limit, offset: offset)
    guard let parsed = EtcdQueryBuilder.parseRangeQuery(query) else { fatalError("Rejected valid page bounds") }
    precondition(parsed.limit == limit && parsed.offset == offset && parsed.prefix == "/app/")
}
print("PASS: 10 page-bound cases")
SWIFT
xcrun swiftc -swift-version 6 -I "$WORK" -L "$WORK" -lTableProPluginKit -lTableProEtcdCore \
    -Xlinker -rpath -Xlinker "$WORK" \
    "$PLUGIN/EtcdCommandParser.swift" "$PLUGIN/EtcdRowFilter.swift" "$PLUGIN/EtcdQueryBuilder.swift" \
    "$PLUGIN/EtcdLeaseID.swift" \
    "$WORK/main.swift" -o "$WORK/probe"
"$WORK/probe"
