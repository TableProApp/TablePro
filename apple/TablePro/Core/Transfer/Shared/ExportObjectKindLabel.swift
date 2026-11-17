import Foundation
import TableProPluginKit

// How each object kind names and draws itself in both apps' export lists. One table rather than a switch per call site,
// so a kind added later cannot pick up a different icon in one of them.
nonisolated enum ExportObjectKindLabel {
    static func title(for kind: PluginExportObjectKind) -> String {
        switch kind {
        case .table: return String(localized: "Tables")
        case .view: return String(localized: "Views")
        case .materializedView: return String(localized: "Materialized Views")
        case .foreignTable: return String(localized: "Foreign Tables")
        case .sequence: return String(localized: "Sequences")
        case .userType: return String(localized: "Types")
        case .routine: return String(localized: "Routines")
        case .trigger: return String(localized: "Triggers")
        case .event: return String(localized: "Events")
        case .grant: return String(localized: "Privileges")
        @unknown default: return String(localized: "Objects")
        }
    }

    static func systemImage(for kind: PluginExportObjectKind) -> String {
        switch kind {
        case .table, .foreignTable: return "tablecells"
        case .view, .materializedView: return "eye"
        case .sequence: return "number"
        case .userType: return "curlybraces"
        case .routine: return "function"
        case .trigger: return "bolt"
        case .event: return "clock"
        case .grant: return "key"
        @unknown default: return "shippingbox"
        }
    }
}
