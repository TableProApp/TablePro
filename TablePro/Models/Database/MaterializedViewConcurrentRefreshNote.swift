//
//  MaterializedViewConcurrentRefreshNote.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct MaterializedViewConcurrentRefreshNote: Equatable {
    internal let systemImage: String
    internal let text: String

    internal init?(state: MetadataLoadState<PluginConcurrentRefreshAvailability?>) {
        switch state {
        case .idle, .loading:
            return nil
        case .failed:
            systemImage = "exclamationmark.triangle"
            text = String(localized: "Couldn't check whether this view can be refreshed concurrently.")
        case .loaded(let availability):
            guard let availability else { return nil }
            switch availability {
            case .available:
                systemImage = "checkmark.circle"
                text = String(localized: "This view can be refreshed concurrently.")
            case .requiresUniqueIndex:
                systemImage = "info.circle"
                text = String(
                    localized: """
                    Concurrent refresh needs a valid unique index on the view's columns, with no WHERE \
                    clause and no expressions.
                    """
                )
            case .requiresPopulatedView:
                systemImage = "info.circle"
                text = String(
                    localized: "Concurrent refresh needs the view to be populated first. Refresh it once without that option."
                )
            @unknown default:
                systemImage = "info.circle"
                text = String(localized: "This view can't be refreshed concurrently.")
            }
        }
    }
}
