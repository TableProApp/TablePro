import Foundation

enum TableHealthCheckKind: String, Sendable {
    case bloat
    case unusedIndex
    case redundantIndex
    case missingPrimaryKey
    case unindexedForeignKey

    var title: String {
        switch self {
        case .bloat: return String(localized: "Bloated Tables")
        case .unusedIndex: return String(localized: "Unused Indexes")
        case .redundantIndex: return String(localized: "Redundant Indexes")
        case .missingPrimaryKey: return String(localized: "Tables Without a Primary Key")
        case .unindexedForeignKey: return String(localized: "Foreign Keys Without an Index")
        }
    }

    var systemImage: String {
        switch self {
        case .bloat: return "trash"
        case .unusedIndex: return "list.bullet.indent"
        case .redundantIndex: return "square.on.square"
        case .missingPrimaryKey: return "key"
        case .unindexedForeignKey: return "link"
        }
    }
}

struct TableHealthFinding: Identifiable, Hashable, Sendable {
    let kind: TableHealthCheckKind
    // Nil where the engine has no schema level below the database.
    let schema: String?
    let table: String
    let objectName: String?
    let detail: String
    let fixSQL: String

    var id: String {
        [kind.rawValue, schema ?? "", table, objectName ?? ""].joined(separator: "\u{1F}")
    }

    var qualifiedTable: String {
        guard let schema else { return table }
        return "\(schema).\(table)"
    }
}

struct TableHealthCheckResult: Identifiable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case failed(String)
        // The server records nothing the check could read, so it did not run.
        case skipped(String)
    }

    let kind: TableHealthCheckKind
    var findings: [TableHealthFinding]
    var outcome: Outcome

    var id: String { kind.rawValue }
}

struct TableHealthReport: Sendable {
    let database: String
    var checks: [TableHealthCheckResult]
    var statisticsNote: String?

    var findingCount: Int {
        checks.reduce(0) { $0 + $1.findings.count }
    }

    func finding(id: TableHealthFinding.ID) -> TableHealthFinding? {
        for check in checks {
            if let finding = check.findings.first(where: { $0.id == id }) {
                return finding
            }
        }
        return nil
    }
}

struct TableHealthStatistics: Equatable, Sendable {
    var note: String?
    var skippedChecks: [TableHealthCheckKind: String] = [:]
}
