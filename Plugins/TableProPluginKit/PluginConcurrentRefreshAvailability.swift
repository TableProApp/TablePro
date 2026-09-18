//
//  PluginConcurrentRefreshAvailability.swift
//  TableProPluginKit
//

import Foundation

/// Whether one materialized view can be refreshed without blocking the sessions reading it.
///
/// The answer depends on the view, not only on the engine: PostgreSQL refuses a concurrent refresh
/// of a view that has no usable unique index or has never been populated, and the prompt says which
/// rather than offering an option the server will reject.
public enum PluginConcurrentRefreshAvailability: String, Sendable, Equatable {
    case available
    case requiresUniqueIndex
    case requiresPopulatedView
}
