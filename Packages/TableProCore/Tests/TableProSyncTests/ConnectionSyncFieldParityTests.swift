import Foundation
import Testing
@testable import TableProSyncTransport

/// macOS and iOS map a connection with two separate `SyncRecordMapper` implementations, because the
/// two platforms cannot share one `DatabaseConnection`: the macOS `DatabaseType` resolves through
/// the plugin registry and is open-ended by design, while iOS carries a fixed list. So the wire
/// contract is the only thing holding them together, and nothing checked that both ends actually
/// use it.
///
/// A connection's colour reached users that way: macOS wrote this enum's name to `color` and iOS
/// wrote hex to `colorTag`, each read only its own field, and a colour set on one device was
/// invisible on the other. The list below is the asymmetry that is left, every entry deliberate,
/// so a new one fails here instead of shipping.
@Suite("Connection sync field parity between the two mappers")
struct ConnectionSyncFieldParityTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let macMapper = "TablePro/Core/Sync/SyncRecordMapper.swift"
    private static let iosMapper = "Packages/TableProCore/Sources/TableProSync/SyncRecordMapper.swift"

    /// Fields only one platform has a model property for. Each is a feature the other app does not
    /// have, and `CKModifyRecordsOperation.savePolicy = .changedKeys` means the platform that does
    /// not write one also cannot erase it.
    private static let macOnly: Set<String> = [
        "aiPolicy", "aiRules", "aiAlwaysAllowedTools",
        "redisDatabase", "startupCommands", "sshProfileId", "isFavorite",
    ]

    private static let iosOnly: Set<String> = [
        "queryTimeoutSeconds", "sshEnabled", "sslEnabled",
    ]

    /// Written by whichever mapper owns the value and never read back by it.
    private static let writeOnly: Set<String> = ["modifiedAtLocal", "schemaVersion"]

    /// Read for backwards compatibility and no longer written by anyone.
    private static let legacyReadOnly: Set<String> = ["colorTag"]

    private static let accessPattern = try! NSRegularExpression(
        pattern: #"fields\[\.(\w+)\]\s*(=[^=]|as\?)"#
    )

    private static func connectionFields(in path: String) throws -> (written: Set<String>, read: Set<String>) {
        let url = repositoryRoot.appendingPathComponent(path)
        let source = try String(contentsOf: url, encoding: .utf8)

        var written: Set<String> = []
        var read: Set<String> = []
        var inConnectionScope = false

        for line in source.components(separatedBy: .newlines) {
            /// Scope follows either the accessor a function builds for itself or the one it is
            /// handed as a parameter. Reading only the first missed `color`, which a helper reads
            /// from a `SyncRecordFields` argument.
            if let range = line.range(of: #"\.fields\((\w+)\.self\)"#, options: .regularExpression) {
                inConnectionScope = line[range].contains("ConnectionSyncField")
            } else if let range = line.range(of: #"SyncRecordFields<(\w+)>"#, options: .regularExpression) {
                inConnectionScope = line[range].contains("ConnectionSyncField")
            }
            guard inConnectionScope else { continue }
            let full = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in Self.accessPattern.matches(in: line, range: full) {
                guard let nameRange = Range(match.range(at: 1), in: line),
                      let opRange = Range(match.range(at: 2), in: line) else { continue }
                let name = String(line[nameRange])
                if line[opRange].hasPrefix("=") {
                    written.insert(name)
                } else {
                    read.insert(name)
                }
            }
        }
        return (written, read)
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

    @Test("Neither mapper has a field the check has not been told about")
    func noUndeclaredAsymmetry() throws {
        let mac = try Self.connectionFields(in: Self.macMapper)
        let ios = try Self.connectionFields(in: Self.iosMapper)

        let shared = ConnectionSyncField.allCases
            .map(\.rawValue)
            .filter { !Self.macOnly.contains($0) }
            .filter { !Self.iosOnly.contains($0) }
            .filter { !Self.writeOnly.contains($0) }
            .filter { !Self.legacyReadOnly.contains($0) }

        let offenders = shared.filter { field in
            !(mac.written.contains(field) && mac.read.contains(field)
                && ios.written.contains(field) && ios.read.contains(field))
        }

        #expect(offenders.isEmpty, """
        These connection fields are not written and read by both mappers, so a value set on one \
        platform never reaches the other. Either map the field on both sides, or add it to \
        macOnly / iosOnly with the reason it is one-sided.
        \(offenders.sorted().joined(separator: "\n"))
        """)
    }

    @Test("A colour is carried on the field both platforms use")
    func colourIsShared() throws {
        let mac = try Self.connectionFields(in: Self.macMapper)
        let ios = try Self.connectionFields(in: Self.iosMapper)

        #expect(mac.written.contains("color"))
        #expect(mac.read.contains("color"))
        #expect(ios.written.contains("color"))
        #expect(ios.read.contains("color"))
        #expect(!ios.written.contains("colorTag"), "colorTag is legacy and must not be written again")
    }

    @Test("Every one-sided field the check tolerates is still a real field")
    func toleratedFieldsExist() {
        let known = Set(ConnectionSyncField.allCases.map(\.rawValue))
        let tolerated = Self.macOnly.union(Self.iosOnly).union(Self.writeOnly).union(Self.legacyReadOnly)
        let stale = tolerated.subtracting(known)

        #expect(stale.isEmpty, "These names are no longer ConnectionSyncField cases: \(stale.sorted())")
    }
}
