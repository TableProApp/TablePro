import Foundation
import TableProPluginKit

struct PrincipalRow: Identifiable, Hashable {
    enum Stage: Equatable {
        case unchanged
        case created
        case modified
        case dropped
    }

    let info: PluginPrincipalInfo
    let stage: Stage

    var id: PluginPrincipalRef { info.ref }
    var ref: PluginPrincipalRef { info.ref }
    var displayName: String { info.ref.displayName }
    var sortName: String { info.ref.name.lowercased() }
    var isRole: Bool { info.isRole }

    var kindTitle: String {
        info.isRole ? String(localized: "Role") : String(localized: "User")
    }

    var attributeSummary: String {
        info.attributes
            .filter(\.isEnabled)
            .map(\.label)
            .formatted(.list(type: .and, width: .narrow))
    }

    var symbolName: String {
        info.isRole ? "person.2" : "person"
    }

    var statusSymbol: String? {
        switch stage {
        case .unchanged: nil
        case .created: "plus.circle"
        case .modified: "pencil.circle"
        case .dropped: "minus.circle"
        }
    }

    var statusDescription: String? {
        switch stage {
        case .unchanged:
            nil
        case .created:
            String(localized: "Will be created when you apply changes")
        case .modified:
            String(localized: "Has unsaved changes")
        case .dropped:
            String(localized: "Will be dropped when you apply changes")
        }
    }
}
