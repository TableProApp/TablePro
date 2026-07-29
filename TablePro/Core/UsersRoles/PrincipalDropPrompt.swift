import Foundation
import TableProPluginKit

struct PrincipalDropPrompt: Identifiable, Equatable {
    enum Disposition: Equatable {
        case reassign(to: PluginPrincipalRef)
        case dropOwned
    }

    let principals: [PluginPrincipalInfo]
    let reassignCandidates: [PluginPrincipalRef]

    var id: String {
        principals.map(\.ref.displayName).joined(separator: ",")
    }

    var title: String {
        guard principals.count == 1, let principal = principals.first else {
            return String(
                format: String(localized: "%lld roles own database objects"),
                principals.count
            )
        }
        return String(
            format: String(localized: "“%@” owns database objects"),
            principal.ref.displayName
        )
    }

    static func dropOptions(for disposition: Disposition) -> PluginPrincipalDropOptions {
        switch disposition {
        case let .reassign(target):
            PluginPrincipalDropOptions(reassignOwnedTo: target)
        case .dropOwned:
            PluginPrincipalDropOptions(dropOwned: true)
        }
    }
}
