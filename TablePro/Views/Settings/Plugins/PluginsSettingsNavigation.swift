//
//  PluginsSettingsNavigation.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
internal final class PluginsSettingsNavigation {
    internal struct Request: Equatable {
        let id: UUID
        let pluginId: String?
    }

    internal static let shared = PluginsSettingsNavigation()

    internal private(set) var pendingRequest: Request?

    internal init() {}

    internal func reveal(pluginId: String?) {
        pendingRequest = Request(id: UUID(), pluginId: pluginId)
    }

    internal func consumePendingRequest() -> Request? {
        let request = pendingRequest
        pendingRequest = nil
        return request
    }
}
