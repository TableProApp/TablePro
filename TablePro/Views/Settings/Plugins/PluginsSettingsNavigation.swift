//
//  PluginsSettingsNavigation.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class PluginsSettingsNavigation: ObservableObject {
    internal struct Request: Equatable {
        let id: UUID
        let pluginId: String?
    }

    internal static let shared = PluginsSettingsNavigation()

    @Published internal private(set) var pendingRequest: Request?

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
