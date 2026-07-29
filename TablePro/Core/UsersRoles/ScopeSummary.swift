import Foundation
import TableProPluginKit

enum ScopeSummary: Equatable {
    case notGrantable
    case none
    case all(count: Int)
    case some(names: [String], overflow: Int, hasGrantOption: Bool)
    case descendantsOnly(count: Int)
    case browsingRestricted(direct: [String])

    static let maximumNamesShown = 2

    static func make(
        granted: [String],
        grantable: [PluginPrivilegeDescriptor],
        descendantCount: Int,
        hasGrantOption: Bool,
        isBrowsingRestricted: Bool
    ) -> ScopeSummary {
        if isBrowsingRestricted {
            return .browsingRestricted(direct: granted.sorted())
        }
        guard !grantable.isEmpty else {
            return descendantCount > 0 ? .descendantsOnly(count: descendantCount) : .notGrantable
        }
        guard !granted.isEmpty else {
            return descendantCount > 0 ? .descendantsOnly(count: descendantCount) : .none
        }
        if granted.count == grantable.count {
            return .all(count: granted.count)
        }

        let sorted = granted.sorted()
        let shown = Array(sorted.prefix(maximumNamesShown))
        return .some(
            names: shown,
            overflow: sorted.count - shown.count,
            hasGrantOption: hasGrantOption
        )
    }
}
