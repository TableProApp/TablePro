//
//  MaterializedViewRefreshPrompt.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the Refresh Materialized View confirmation says, kept apart from the alert so it can be
/// asserted without presenting one.
///
/// The option to refresh without blocking readers is shown only where the engine has one, and it is
/// enabled only for a view the server will accept it for. Offering it on engine version alone is how
/// other clients ended up with a checkbox the server then refuses.
internal struct MaterializedViewRefreshPrompt: Equatable {
    internal let qualifiedName: String
    /// Nil when the engine has no concurrent refresh at all.
    internal let availability: PluginConcurrentRefreshAvailability?
    /// The check failed, so whether the view qualifies is not known. The option is shown disabled
    /// rather than left out, so the user is not told the engine lacks it.
    internal let availabilityCheckFailed: Bool

    internal init(
        qualifiedName: String,
        availability: PluginConcurrentRefreshAvailability?,
        availabilityCheckFailed: Bool = false
    ) {
        self.qualifiedName = qualifiedName
        self.availability = availability
        self.availabilityCheckFailed = availabilityCheckFailed
    }

    internal var messageText: String {
        String(format: String(localized: "Refresh the materialized view “%@”?"), qualifiedName)
    }

    internal var informativeText: String {
        String(
            localized: """
            The view's query runs again and replaces its stored rows. A plain refresh stops other \
            sessions from reading the view until it finishes.
            """
        )
    }

    internal var confirmButtonTitle: String {
        String(localized: "Refresh")
    }

    internal var cancelButtonTitle: String {
        String(localized: "Cancel")
    }

    internal var showsConcurrentOption: Bool {
        availability != nil || availabilityCheckFailed
    }

    internal var isConcurrentOptionEnabled: Bool {
        availability == .available
    }

    internal var concurrentOptionTitle: String {
        String(localized: "Refresh concurrently")
    }

    internal var concurrentOptionDescription: String {
        if availabilityCheckFailed {
            return String(localized: "Couldn't check whether this view can be refreshed concurrently.")
        }
        switch availability {
        case .available:
            return String(localized: "Other sessions keep reading the view. Slower, because the new rows are compared with the old ones.")
        case .requiresUniqueIndex:
            return String(localized: "Needs a valid unique index on the view's columns, with no WHERE clause and no expressions.")
        case .requiresPopulatedView:
            return String(localized: "Available once the view holds rows. Refresh it once without this option first.")
        case .none:
            return ""
        @unknown default:
            return String(localized: "This view can't be refreshed concurrently.")
        }
    }

    /// Only honoured while the option is enabled, so a stale checkbox can never ask the server for
    /// a refresh it has already said it would refuse.
    internal func refreshesConcurrently(checkboxIsOn: Bool) -> Bool {
        isConcurrentOptionEnabled && checkboxIsOn
    }
}
