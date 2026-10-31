//
//  TableHealthModels.swift
//  TablePro
//

import Foundation

enum TableHealthCheckKind: String, CaseIterable, Identifiable {
    case bloat
    case unusedIndex
    case redundantIndex
    case missingPrimaryKey
    case unindexedForeignKey

    var id: String { rawValue }

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

struct TableHealthFinding: Identifiable, Hashable {
    let kind: TableHealthCheckKind
    let schema: String
    let table: String
    /// The index or constraint the finding is about, nil when it is about the whole table.
    let objectName: String?
    let detail: String
    /// Shown as a preview only: nothing in the report runs it.
    let fixSQL: String

    var id: String {
        [kind.rawValue, schema, table, objectName ?? ""].joined(separator: "\u{1F}")
    }
}

struct TableHealthCheckResult: Identifiable {
    static let findingLimit = 500

    let kind: TableHealthCheckKind
    var findings: [TableHealthFinding]
    var error: String?

    var id: String { kind.id }
}

struct TableHealthReport {
    var checks: [TableHealthCheckResult]
    /// The database the server answered for, so a finding opens and fixes there even after the sidebar moves on.
    var databaseName: String?
    /// Index usage counts only since the statistics were last reset, so an index can look unused because they were.
    var statisticsNote: String?

    var findingCount: Int {
        checks.reduce(0) { $0 + $1.findings.count }
    }
}
