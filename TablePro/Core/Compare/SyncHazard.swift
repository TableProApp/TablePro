//
//  SyncHazard.swift
//  TablePro
//
//  Typed risks attached to individual generated statements.
//  A statement carrying a refused hazard is shown in the preview but is not
//  executed unless it is explicitly allowed for that run.
//

import Foundation

internal enum SyncHazardKind: String, Codable, Hashable, Sendable {
    case dataLoss
    case lossyTypeChange
    case tableRebuild
    case collationOrCharsetChange
    case primaryKeyChange
    case engineOrStorageChange
    case notSupportedByTarget
}

internal enum SyncHazardSeverity: Int, Codable, Hashable, Sendable, Comparable {
    case informational
    case warning
    case refusedByDefault

    internal static func < (lhs: SyncHazardSeverity, rhs: SyncHazardSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

internal struct SyncHazard: Identifiable, Hashable, Sendable {
    internal let kind: SyncHazardKind
    internal let severity: SyncHazardSeverity
    internal let explanation: String

    internal var id: String { "\(kind.rawValue)-\(explanation)" }

    internal init(kind: SyncHazardKind, severity: SyncHazardSeverity, explanation: String) {
        self.kind = kind
        self.severity = severity
        self.explanation = explanation
    }
}

internal extension SyncHazardKind {
    var displayName: String {
        switch self {
        case .dataLoss:
            return String(localized: "Data loss")
        case .lossyTypeChange:
            return String(localized: "Lossy type change")
        case .tableRebuild:
            return String(localized: "Table rebuild")
        case .collationOrCharsetChange:
            return String(localized: "Collation or character set change")
        case .primaryKeyChange:
            return String(localized: "Primary key change")
        case .engineOrStorageChange:
            return String(localized: "Storage engine change")
        case .notSupportedByTarget:
            return String(localized: "Not supported by the target")
        }
    }
}
