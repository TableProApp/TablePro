#!/usr/bin/env bash
set -euo pipefail

# Library name order gate.
#
# The core breaks a tie in the connection library's manual order the way the Mac's
# LibrarySorting does, with localizedStandardCompare, and pins Foundation's verdicts in
# core/crates/storage/src/cloudkit/values.rs (FOUNDATION). This asks Foundation, in English,
# whether each pair there still sorts first before second.
#
# Usage: scripts/probes/check-library-name-order.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.swift" <<'SWIFT'
import Foundation

let pairs: [(String, String)] = [
    ("é", "z"), ("a", "A"), ("a", "B"), ("Prod 9", "Prod 10"), ("e", "é"), ("é", "f"), ("work", "Work"),
    ("a", "ä"), ("ss", "ß"), ("é", "Z"), ("_a", "a"), ("a b", "ab"), ("ü", "v"), ("Ø", "p"), ("1", "a"),
    ("a1", "a01")
]
// localizedStandardCompare's options, in a fixed locale so the verdict does not follow the Mac's.
let options: String.CompareOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]
let english = Locale(identifier: "en_US")
var failed = 0
for (first, second) in pairs {
    let order = first.compare(second, options: options, range: nil, locale: english)
    if order != .orderedAscending {
        print("FAIL \(first) before \(second): Foundation says \(order.rawValue)")
        failed += 1
    }
}
print(failed == 0 ? "PASS \(pairs.count) pairs" : "FAIL \(failed) of \(pairs.count) pairs")
exit(failed == 0 ? 0 : 1)
SWIFT

xcrun swift "$WORK/probe.swift"
