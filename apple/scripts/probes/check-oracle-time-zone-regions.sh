#!/usr/bin/env bash
#
# Check that a TIMESTAMP WITH TIME ZONE stored with a region name reads as its wall clock and Oracle's name, and that
# the grid's write-back masks parse that text again.
#
# Such a value carries an id into the server's time zone file. OracleTimeZoneRegions reads the ids once per connection
# from SYS.V_$TIMEZONE_NAMES and assumes a layout no Oracle document states: 0x80 in byte 11 marks a region, the id is
# 13 bits over bytes 11 and 12 with the low two bits of byte 12 unused, and bytes 1 to 7 are UTC. This reads the wire
# bytes through oracle-nio and the cell text through the same OracleCoreConnection the app uses, and checks:
#   1. whether the account can read the view; ORA-00942 is a normal answer, and the cells then read as UTC
#   2. the map query's rows, for AT TIME ZONE and FROM_TZ: every row a region, no id repeated, the low bits clear
#   3. which names Foundation's TimeZone does not know
#   4. stored region values: wire bytes against SYS_EXTRACT_UTC and DUMP, cell text against TO_CHAR and EXTRACT
#   5. a session zone set to a region: CURRENT_TIMESTAMP and friends read with it, and the map outlives the ALTER
#   6. the masks in OracleRowWriter.swift parse the region, offset and zone-less spellings, into TSTZ and LTZ
#
# Usage:
#   scripts/probes/check-oracle-time-zone-regions.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# Hand-run only, never in CI. The user needs CREATE TABLE. Every object it creates is prefixed TP_TZR_ and dropped
# again. Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-probe}"
PASSWORD="${5:-probe_pw}"
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

MASK="$(sed -n 's/.*static let timestampWithTimeZoneMask = "\(.*\)"$/\1/p' "$ROOT/Plugins/OracleDriverPlugin/OracleRowWriter.swift")"
OFFSET_MASK="$(sed -n 's/.*static let timestampWithOffsetMask = "\(.*\)"$/\1/p' "$ROOT/Plugins/OracleDriverPlugin/OracleRowWriter.swift")"
NIO_REVISION="$(sed -n 's/.*revision: "\([0-9a-f]*\)".*/\1/p' "$ROOT/Packages/TableProOracle/Package.swift")"
if [ -z "$MASK" ] || [ -z "$OFFSET_MASK" ] || [ -z "$NIO_REVISION" ]; then
    echo "cannot read the writer's mask or the oracle-nio pin" >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProOracle"),
        .package(url: "https://github.com/TableProApp/oracle-nio", revision: "$NIO_REVISION"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
    ],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [
                .product(name: "TableProOracleCore", package: "TableProOracle"),
                .product(name: "OracleNIO", package: "oracle-nio"),
                .product(name: "NIOCore", package: "swift-nio")
            ]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import NIOCore
import OracleNIO
import TableProOracleCore

let arguments = CommandLine.arguments
let host = arguments[1]
let port = Int(arguments[2]) ?? 1_521
let service = arguments[3]
let user = arguments[4]
let password = arguments[5]
let regionMask = arguments[6]
let offsetMask = arguments[7]
let view = "SYS.V_$TIMEZONE_NAMES"

let connection = OracleCoreConnection(options: OracleConnectionOptions(
    host: host, port: port, user: user, password: password, identifierMode: .service, serviceName: service
))
do {
    try await connection.connect()
} catch {
    print("cannot connect: \(error)")
    exit(3)
}

func dialRaw() async -> OracleNIO.OracleConnection {
    do {
        return try await OracleNIO.OracleConnection.connect(
            configuration: OracleNIO.OracleConnection.Configuration(
                host: host, port: port, service: .serviceName(service), username: user, password: password
            ),
            id: 1
        )
    } catch {
        print("cannot connect through oracle-nio: \(error)")
        exit(3)
    }
}

let raw = await dialRaw()

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

func info(_ line: String) {
    print("info \(line)")
}

func attempt(_ sql: String) async -> (result: OracleRawResult?, failure: String?) {
    do {
        return (try await connection.executeQuery(sql), nil)
    } catch {
        return (nil, String(describing: error))
    }
}

@MainActor
func result(_ sql: String) async -> OracleRawResult? {
    let answer = await attempt(sql)
    if let failure = answer.failure {
        print("FAIL \(sql.prefix(80)): \(failure)")
        disagreements += 1
    }
    return answer.result
}

func scalar(_ sql: String) async -> String? {
    await attempt(sql).result?.rows.first?.first?.stringValue
}

func run(_ sql: String) async {
    _ = await attempt(sql)
}

// The cells as oracle-nio hands them over, before the core decodes anything.
func rawRows(_ sql: String) async throws -> [[OracleCell]] {
    let stream = try await raw.execute(
        OracleStatement(unsafeSQL: sql), options: StatementOptions(prefetchRows: 1_000, arraySize: 1_000)
    )
    var rows: [[OracleCell]] = []
    for try await row in stream {
        rows.append(Array(row))
    }
    return rows
}

func bytes(of cell: OracleCell) -> [UInt8] {
    cell.bytes.map { Array($0.readableBytesView) } ?? []
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func listed(_ items: [String]) -> String {
    items.isEmpty ? "" : " (\(items.count): \(items.prefix(5).joined(separator: "; ")))"
}

// The writer's own choice: a region name after a blank takes the region mask, anything else the offset mask.
func mask(for text: String) -> String {
    text.split(separator: " ").last?.first?.isLetter == true ? regionMask : offsetMask
}

func parsed(_ text: String) -> String {
    "TO_TIMESTAMP_TZ('\(text)', '\(mask(for: text))')"
}

guard let release = connection.serverRelease else {
    print("the login reply carried no server release")
    exit(3)
}
print("Oracle \(release.major).\(release.update), writer masks '\(regionMask)' and '\(offsetMask)'")

print("\n1. Who can read \(view)")
let roles = await result("SELECT ROLE FROM SESSION_ROLES ORDER BY ROLE")?.rows.compactMap { $0.first?.stringValue } ?? []
info("session roles: \(roles.isEmpty ? "none" : roles.joined(separator: ", "))")
let publicGrants = await scalar("""
    SELECT COUNT(*) FROM ALL_TAB_PRIVS
    WHERE TABLE_SCHEMA = 'SYS' AND TABLE_NAME = 'V_$TIMEZONE_NAMES' AND GRANTEE = 'PUBLIC'
    """)
info("PUBLIC grants on \(view) in ALL_TAB_PRIVS: \(publicGrants ?? "unreadable")")
let access = await attempt("SELECT COUNT(*) FROM \(view)")
let mapReadable = access.result != nil
if let count = access.result?.rows.first?.first?.stringValue {
    check(true, "\(user) reads \(view): \(count) rows")
} else {
    let failure = access.failure ?? ""
    check(failure.contains("ORA-00942"), "\(user) is refused \(view) with ORA-00942: \(failure.prefix(120))")
}
if let file = await scalar("SELECT FILENAME || ' version ' || VERSION FROM SYS.V_$TIMEZONE_FILE") {
    info("time zone file \(file)")
}

print("\n2. The map query, read raw")
var mapRows: [(name: String, wire: [UInt8])] = []
var idsByForm: [String: [String: Int]] = [:]
let fromTZQuery = "SELECT TZNAME, FROM_TZ(TIMESTAMP '2000-01-01 00:00:00', TZNAME) FROM "
    + "(SELECT DISTINCT TZNAME FROM \(view)) ORDER BY TZNAME"
if mapReadable {
    for (form, sql) in [("AT TIME ZONE", OracleTimeZoneRegions.query), ("FROM_TZ", fromTZQuery)] {
        let started = ContinuousClock.now
        let rows: [[OracleCell]]
        do {
            rows = try await rawRows(sql)
        } catch {
            check(false, "\(form): the map query runs: \(error)")
            continue
        }
        info("\(form): \(rows.count) rows in \(ContinuousClock.now - started)")
        let pairs = rows.compactMap { cells -> (name: String, wire: [UInt8])? in
            guard cells.count == 2, let name = try? cells[0].decode(String.self) else { return nil }
            return (name, bytes(of: cells[1]))
        }
        let unflagged = pairs.filter { OracleTimeZoneRegions.regionID(wire: $0.wire) == nil }.map { "\($0.name) \(hex($0.wire))" }
        check(unflagged.isEmpty, "\(form): every row carries a region id\(listed(unflagged))")
        var namesByID: [Int: [String]] = [:]
        for pair in pairs {
            guard let id = OracleTimeZoneRegions.regionID(wire: pair.wire) else { continue }
            namesByID[id, default: []].append(pair.name)
        }
        let shared = namesByID.filter { $0.value.count > 1 }.map { "\($0.key): \($0.value.joined(separator: ", "))" }
        check(shared.isEmpty, "\(form): no two names share an id\(listed(shared))")
        let lowBits = pairs.filter { $0.wire.count >= 13 && $0.wire[12] & 0x03 != 0 }.map { "\($0.name) \(hex($0.wire))" }
        check(lowBits.isEmpty, "\(form): the low two bits of byte 12 are clear\(listed(lowBits))")
        var ids: [String: Int] = [:]
        for pair in pairs {
            ids[pair.name] = OracleTimeZoneRegions.regionID(wire: pair.wire)
        }
        idsByForm[form] = ids
        if form == "AT TIME ZONE" {
            mapRows = pairs
            let utcFields: [UInt8] = [0x78, 0x64, 0x01, 0x01, 0x01, 0x01, 0x01]
            let moved = pairs.filter { Array($0.wire.prefix(7)) != utcFields }.map { "\($0.name) \(hex($0.wire))" }
            check(moved.isEmpty, "AT TIME ZONE: bytes 1 to 7 of every row are 2000-01-01 00:00:00 UTC\(listed(moved))")
        }
    }
    if idsByForm.count == 2 {
        check(idsByForm["AT TIME ZONE"] == idsByForm["FROM_TZ"], "AT TIME ZONE and FROM_TZ give each name the same id")
    }
    info("OracleTimeZoneRegions keeps \(OracleTimeZoneRegions(rows: mapRows).count) of \(mapRows.count) rows")
} else {
    info("skip: \(view) is not readable, so every region value reads as UTC")
}

// The first name per id, as the map keeps it: the query orders by name.
var nameByID: [Int: String] = [:]
for row in mapRows {
    guard let id = OracleTimeZoneRegions.regionID(wire: row.wire), nameByID[id] == nil else { continue }
    nameByID[id] = row.name
}

print("\n3. Names Foundation does not know")
let unknownNames = mapRows.map { $0.name }.filter { TimeZone(identifier: $0) == nil }
info("\(unknownNames.count) of \(mapRows.count) names read as UTC instead")
for name in unknownNames {
    info("Foundation does not know \(name)")
}

print("\n4. Stored region values")
let samples: [(id: Int, literal: String)] = [
    (1, "TIMESTAMP '2024-01-02 03:04:05.5 Europe/Paris'"),
    (2, "TIMESTAMP '2024-07-01 14:00:00 Europe/Paris'"),
    (3, "TIMESTAMP '2024-03-10 01:30:00 America/Los_Angeles'"),
    (4, "TIMESTAMP '2024-11-03 12:00:00 US/Pacific'"),
    (5, "TIMESTAMP '2024-06-15 08:00:00 UTC'"),
    (6, "TIMESTAMP '2024-06-15 08:00:00 Etc/GMT+5'"),
    (7, "TIMESTAMP '1880-06-01 12:00:00 Europe/Paris'"),
    (8, "TIMESTAMP '2024-10-27 02:30:00 Europe/Paris CEST'"),
]
let overlapRow = 8
await run("DROP TABLE TP_TZR_T PURGE")
if let failure = await attempt("CREATE TABLE TP_TZR_T (ID NUMBER PRIMARY KEY, TZ TIMESTAMP(6) WITH TIME ZONE)").failure {
    print("cannot create TP_TZR_T: \(failure)")
    exit(3)
}
var literalByID: [Int: String] = [:]
for sample in samples {
    if let failure = await attempt("INSERT INTO TP_TZR_T VALUES (\(sample.id), \(sample.literal))").failure {
        info("skip \(sample.literal): \(failure.prefix(100))")
    } else {
        literalByID[sample.id] = sample.literal
    }
}
_ = await result("COMMIT")

var wireByID: [Int: [UInt8]] = [:]
do {
    for cells in try await rawRows("SELECT TO_CHAR(ID), TZ, SYS_EXTRACT_UTC(TZ), DUMP(TZ) FROM TP_TZR_T ORDER BY ID") {
        guard cells.count == 4, let row = (try? cells[0].decode(String.self)).flatMap({ Int($0) }) else { continue }
        let wire = bytes(of: cells[1])
        let utc = bytes(of: cells[2])
        let dump = (try? cells[3].decode(String.self)) ?? ""
        let dumped = dump.split(separator: ":", maxSplits: 1).dropFirst().first.map {
            $0.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        } ?? []
        let id = OracleTimeZoneRegions.regionID(wire: wire)
        let lowBits = wire.count >= 13 ? String(wire[12] & 0x03) : "?"
        info("row \(row): \(hex(wire)), region id \(id.map { String($0) } ?? "none"), byte 12 low bits \(lowBits)")
        check(id != nil, "row \(row): the stored value carries a region id")
        check(Array(wire.prefix(7)) == Array(utc.prefix(7)), "row \(row): wire bytes 1 to 7 are SYS_EXTRACT_UTC's \(hex(Array(utc.prefix(7))))")
        check(dump.hasPrefix("Typ=181") && dumped == wire, "row \(row): DUMP of the column matches the wire bytes: \(dump)")
        wireByID[row] = wire
    }
} catch {
    check(false, "the stored values read raw: \(error)")
}

let textQuery = """
    SELECT TO_CHAR(ID), TZ, TO_CHAR(TZ, 'YYYY-MM-DD HH24:MI:SS.FF6') || ' ' || EXTRACT(TIMEZONE_REGION FROM TZ),
           TO_CHAR(SYS_EXTRACT_UTC(TZ), 'YYYY-MM-DD HH24:MI:SS.FF6') || '+00:00',
           EXTRACT(TIMEZONE_REGION FROM TZ), TO_CHAR(TZ, 'TZR')
    FROM TP_TZR_T ORDER BY ID
    """
var cellTextByID: [Int: String] = [:]
var regionByID: [Int: String] = [:]
for values in await result(textQuery)?.rows ?? [] {
    guard values.count == 6, let row = values[0].stringValue.flatMap({ Int($0) }) else { continue }
    let cell = values[1].stringValue ?? "NULL"
    let server = values[2].stringValue ?? ""
    let utcText = values[3].stringValue ?? ""
    let region = values[4].stringValue ?? ""
    let tzr = values[5].stringValue ?? ""
    let mapName = wireByID[row].flatMap { OracleTimeZoneRegions.regionID(wire: $0) }.flatMap { nameByID[$0] }
    if let mapName, mapName != region {
        check(false, "row \(row): the map names its id \(mapName), the server \(region)")
    }
    let expected = mapName.map { TimeZone(identifier: $0) != nil } == true ? server : utcText
    check(cell == expected, "row \(row) \(literalByID[row] ?? ""): reads \(cell)\(cell == expected ? "" : ", expected \(expected)")")
    if tzr != region {
        info("row \(row): TO_CHAR TZR spells \(tzr), EXTRACT spells \(region)")
    }
    cellTextByID[row] = cell
    regionByID[row] = region
}

print("\n5. A session zone set to a region")
_ = await result("ALTER SESSION SET TIME_ZONE = 'Europe/Paris'")
let sessionSuffix = nameByID.values.contains("Europe/Paris") ? " Europe/Paris" : "+00:00"
let regionForms = [
    "CURRENT_TIMESTAMP",
    "FROM_TZ(TIMESTAMP '2024-01-02 03:04:05', 'Europe/Paris')",
    "TIMESTAMP '2024-01-02 02:04:05 UTC' AT TIME ZONE 'Europe/Paris'",
    "TIMESTAMP '2024-01-02 02:04:05 UTC' AT LOCAL",
    "CAST(CAST(TIMESTAMP '2024-01-02 02:04:05 UTC' AS TIMESTAMP WITH LOCAL TIME ZONE) AS TIMESTAMP WITH TIME ZONE)",
]
if let values = await result("SELECT \(regionForms.joined(separator: ", ")) FROM DUAL")?.rows.first {
    for (form, value) in zip(regionForms, values) {
        let text = value.stringValue ?? "NULL"
        check(text.hasSuffix(sessionSuffix), "\(form) reads \(text)")
    }
}
if let first = cellTextByID.keys.min(), let before = cellTextByID[first] {
    let after = await scalar("SELECT TZ FROM TP_TZR_T WHERE ID = \(first)")
    check(after == before, "after the ALTER, row \(first) still reads \(after ?? "NULL")")
}

print("\n6. Write-back through the writer's masks")
for (row, text) in cellTextByID.sorted(by: { $0.key < $1.key }) {
    let matched = await scalar("SELECT COUNT(*) FROM TP_TZR_T WHERE ID = \(row) AND TZ = \(parsed(text))")
    if row == overlapRow {
        let resolved = await scalar("SELECT TO_CHAR(\(parsed(text)), 'YYYY-MM-DD HH24:MI:SS TZR TZD') FROM DUAL")
        info("the repeated hour: \(text) matches \(matched ?? "no") stored row and resolves to \(resolved ?? "an error")")
        continue
    }
    check(matched == "1", "\(text) parses back to the stored instant")
    guard !text.hasSuffix("+00:00") else { continue }
    let kept = await scalar("SELECT EXTRACT(TIMEZONE_REGION FROM \(parsed(text))) FROM DUAL")
    check(kept == regionByID[row], "\(text) keeps its region: \(kept ?? "NULL")")
}

let spellings: [(text: String, literal: String)] = [
    ("2024-01-02 03:04:05.123456-05:30", "TIMESTAMP '2024-01-02 03:04:05.123456 -05:30'"),
    ("2000-01-01 00:00:00.000000+00:00", "TIMESTAMP '2000-01-01 00:00:00 +00:00'"),
    ("2000-01-01 00:00:00", "FROM_TZ(TIMESTAMP '2000-01-01 00:00:00', SESSIONTIMEZONE)"),
    ("2024-01-02 03:04:05.500000 Europe/Paris", "TIMESTAMP '2024-01-02 03:04:05.5 Europe/Paris'"),
]
await run("DROP TABLE TP_TZR_L PURGE")
_ = await result("CREATE TABLE TP_TZR_L (ID NUMBER PRIMARY KEY, L TIMESTAMP(6) WITH LOCAL TIME ZONE)")
for (index, spelling) in spellings.enumerated() {
    let compared = await attempt("SELECT CASE WHEN \(parsed(spelling.text)) = \(spelling.literal) THEN 1 ELSE 0 END FROM DUAL")
    let equal = compared.result?.rows.first?.first?.stringValue
    check(equal == "1", "TIMESTAMP WITH TIME ZONE: '\(spelling.text)' parses to \(spelling.literal)\(compared.failure.map { ": \($0.prefix(100))" } ?? "")")
    let inserted = await attempt("INSERT INTO TP_TZR_L VALUES (\(index), \(parsed(spelling.text)))")
    var stored: String?
    if inserted.failure == nil {
        stored = await scalar("SELECT COUNT(*) FROM TP_TZR_L WHERE ID = \(index) AND L = \(spelling.literal)")
    }
    check(stored == "1", "TIMESTAMP WITH LOCAL TIME ZONE: '\(spelling.text)' writes \(spelling.literal)\(inserted.failure.map { ": \($0.prefix(100))" } ?? "")")
}

await run("DROP TABLE TP_TZR_T PURGE")
await run("DROP TABLE TP_TZR_L PURGE")
try? await raw.close()
print(disagreements == 0 ? "\nall checks hold" : "\n\(disagreements) disagreement(s)")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" "$MASK" "$OFFSET_MASK" 2> /dev/null
