import Foundation
import Testing
@testable import TableProSyncTransport

/// macOS and iOS map a synced record with two separate `SyncRecordMapper` implementations, because
/// the two platforms cannot share one `DatabaseConnection`: the macOS `DatabaseType` resolves
/// through the plugin registry and is open-ended by design, while iOS carries a fixed list. So the
/// wire contract is the only thing holding them together, and nothing checked that both ends
/// actually use it.
///
/// A connection's colour reached users that way: macOS wrote `ConnectionColor`'s name to `color`
/// and iOS wrote hex to `colorTag`, each read only its own field, and a colour set on one device
/// was invisible on the other. Every asymmetry left is listed below, so a new one fails here
/// instead of shipping.
@Suite("Sync field parity between the two mappers")
struct SyncFieldParityTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let macMapper = "TablePro/Core/Sync/SyncRecordMapper.swift"
    private static let iosMapper = "Packages/TableProCore/Sources/TableProSync/SyncRecordMapper.swift"

    /// Record types both apps sync. Every field of these has to survive a trip in either direction.
    private static let sharedRecordTypes: [String: [String]] = [
        "ConnectionSyncField": ConnectionSyncField.allCases.map(\.rawValue),
        "ConnectionGroupSyncField": ConnectionGroupSyncField.allCases.map(\.rawValue),
        "ConnectionTagSyncField": ConnectionTagSyncField.allCases.map(\.rawValue),
    ]

    /// Record types only the Mac syncs, because the iPhone app has no feature that owns them.
    /// Listed rather than ignored so half-adding one to iOS fails instead of going unnoticed.
    private static let macOnlyRecordTypes: Set<String> = [
        "AppSettingsSyncField",
        "FavoriteTableSyncField",
        "FavoriteDatabaseSyncField",
        "SQLFavoriteSyncField",
        "SQLFavoriteFolderSyncField",
        "SSHProfileSyncField",
    ]

    /// Connection fields only one platform has a model property for. Each is a feature the other
    /// app does not have, and `CKModifyRecordsOperation.savePolicy = .changedKeys` means the
    /// platform that does not write one also cannot erase it.
    private static let connectionMacOnly: Set<String> = [
        "aiPolicy", "aiRules", "aiAlwaysAllowedTools",
        "redisDatabase", "startupCommands", "sshProfileId", "isFavorite",
    ]

    private static let connectionIosOnly: Set<String> = [
        "queryTimeoutSeconds", "sshEnabled", "sslEnabled",
    ]

    /// Written by whichever mapper owns the value and never read back by it.
    private static let writeOnly: Set<String> = ["modifiedAtLocal", "schemaVersion"]

    /// Read for backwards compatibility and no longer written by anyone.
    private static let legacyReadOnly: Set<String> = ["colorTag"]

    private struct MapperScan {
        var written: [String: Set<String>] = [:]
        var read: [String: Set<String>] = [:]

        var recordTypes: Set<String> { Set(written.keys).union(read.keys) }

        func written(_ recordType: String) -> Set<String> { written[recordType] ?? [] }
        func read(_ recordType: String) -> Set<String> { read[recordType] ?? [] }
    }

    /// Scope follows either the accessor a function builds for itself or the one it is handed as a
    /// parameter. Reading only the first missed `color`, which a helper reads from an argument.
    private static let scopePattern = try! NSRegularExpression(
        pattern: #"\.fields\((\w+)\.self\)|SyncRecordFields<(\w+)>"#
    )

    private static let accessPattern = try! NSRegularExpression(
        pattern: #"fields\[\.(\w+)\]\s*(=[^=]|as\?)"#
    )

    private static func scan(_ path: String) throws -> MapperScan {
        let url = repositoryRoot.appendingPathComponent(path)
        let source = try String(contentsOf: url, encoding: .utf8)

        var scan = MapperScan()
        var scope: String?

        for line in source.components(separatedBy: .newlines) {
            let full = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = scopePattern.firstMatch(in: line, range: full) {
                for group in 1...2 {
                    if let range = Range(match.range(at: group), in: line) {
                        scope = String(line[range])
                    }
                }
            }
            guard let recordType = scope else { continue }
            for match in accessPattern.matches(in: line, range: full) {
                guard let nameRange = Range(match.range(at: 1), in: line),
                      let opRange = Range(match.range(at: 2), in: line) else { continue }
                let name = String(line[nameRange])
                if line[opRange].hasPrefix("=") {
                    scan.written[recordType, default: []].insert(name)
                } else {
                    scan.read[recordType, default: []].insert(name)
                }
            }
        }
        return scan
    }

    @Test("Both mappers are where this check expects them")
    func mappersExist() {
        for path in [Self.macMapper, Self.iosMapper] {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), """
            \(path) has moved, so this check would pass vacuously.
            """)
        }
    }

    @Test("Every record type either mapper touches is accounted for")
    func recordTypesAreDeclared() throws {
        let touched = try Self.scan(Self.macMapper).recordTypes
            .union(Self.scan(Self.iosMapper).recordTypes)
        let declared = Set(Self.sharedRecordTypes.keys).union(Self.macOnlyRecordTypes)

        #expect(touched.subtracting(declared).isEmpty, """
        A mapper reads or writes a record type this check has not been told about. Add it to \
        sharedRecordTypes if both apps sync it, or to macOnlyRecordTypes with the reason.
        \(touched.subtracting(declared).sorted().joined(separator: "\n"))
        """)
        #expect(declared.subtracting(touched).isEmpty, """
        These record types are declared here but no mapper touches them any more: \
        \(declared.subtracting(touched).sorted())
        """)
    }

    @Test("A record type only the Mac syncs is not half-added to iOS")
    func macOnlyTypesStayMacOnly() throws {
        let ios = try Self.scan(Self.iosMapper)
        let leaked = Self.macOnlyRecordTypes.intersection(ios.recordTypes)

        #expect(leaked.isEmpty, """
        The iOS mapper now touches a record type listed as macOS-only. If iOS really syncs it, \
        move it to sharedRecordTypes so its fields are checked for parity.
        \(leaked.sorted().joined(separator: "\n"))
        """)
    }

    @Test("Neither mapper has a field the check has not been told about", arguments: sharedRecordTypes.keys.sorted())
    func noUndeclaredAsymmetry(recordType: String) throws {
        let mac = try Self.scan(Self.macMapper)
        let ios = try Self.scan(Self.iosMapper)
        let fields = try #require(Self.sharedRecordTypes[recordType])

        let oneSided = recordType == "ConnectionSyncField"
            ? Self.connectionMacOnly.union(Self.connectionIosOnly)
            : []

        let offenders = fields
            .filter { !oneSided.contains($0) }
            .filter { !Self.writeOnly.contains($0) }
            .filter { !Self.legacyReadOnly.contains($0) }
            .filter { field in
                !(mac.written(recordType).contains(field) && mac.read(recordType).contains(field)
                    && ios.written(recordType).contains(field) && ios.read(recordType).contains(field))
            }

        #expect(offenders.isEmpty, """
        These \(recordType) fields are not written and read by both mappers, so a value set on one \
        platform never reaches the other. Either map the field on both sides, or declare it \
        one-sided with the reason it is.
        \(offenders.sorted().joined(separator: "\n"))
        """)
    }

    @Test("A colour is carried on the field both platforms use")
    func colourIsShared() throws {
        let mac = try Self.scan(Self.macMapper)
        let ios = try Self.scan(Self.iosMapper)

        for scan in [mac, ios] {
            #expect(scan.written("ConnectionSyncField").contains("color"))
            #expect(scan.read("ConnectionSyncField").contains("color"))
        }
        #expect(
            !ios.written("ConnectionSyncField").contains("colorTag"),
            "colorTag is legacy and must not be written again"
        )
    }

    @Test("Every one-sided field the check tolerates is still a real field")
    func toleratedFieldsExist() {
        let known = Set(Self.sharedRecordTypes.values.flatMap { $0 })
        let tolerated = Self.connectionMacOnly
            .union(Self.connectionIosOnly)
            .union(Self.writeOnly)
            .union(Self.legacyReadOnly)
        let stale = tolerated.subtracting(known)

        #expect(stale.isEmpty, "These names are no longer sync fields: \(stale.sorted())")
    }
}
