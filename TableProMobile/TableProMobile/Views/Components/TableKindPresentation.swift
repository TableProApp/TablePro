import Foundation
import TableProModels

nonisolated enum TableKindPresentation {
    static func systemImage(for kind: TableInfo.TableKind) -> String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .systemTable: return "tablecells.badge.ellipsis"
        case .externalTable: return "externaldrive.connected.to.line.below"
        case .sequence: return "number"
        }
    }

    static func accessibilityKind(for kind: TableInfo.TableKind) -> String {
        switch kind {
        case .table: return String(localized: "Table")
        case .view: return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .systemTable: return String(localized: "System Table")
        case .externalTable: return String(localized: "External Table")
        case .sequence: return String(localized: "Sequence")
        }
    }
}
