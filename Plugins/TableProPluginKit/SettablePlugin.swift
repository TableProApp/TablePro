//
//  SettablePlugin.swift
//  TableProPluginKit
//

import Foundation
import SwiftUI

/// Type-erased witness for runtime discovery (needed because SettablePlugin has associated type).
public protocol SettablePluginDiscoverable: AnyObject {
    func settingsView() -> AnyView?
}

/// Opt-in protocol for plugins with user-configurable settings.
public protocol SettablePlugin: SettablePluginDiscoverable {
    associatedtype Settings: Codable & Equatable

    /// ID for namespaced UserDefaults keys (matches existing pluginId values).
    static var settingsStorageId: String { get }

    /// Current settings. Must be a stored var with `didSet { saveSettings() }`.
    var settings: Settings { get set }
}

public extension SettablePlugin {
    func settingsView() -> AnyView? { nil }

    func loadSettings() {
        let storage = PluginSettingsStorage(pluginId: Self.settingsStorageId)
        if let saved = storage.load(Settings.self) {
            settings = saved
        }
    }

    func saveSettings() {
        let storage = PluginSettingsStorage(pluginId: Self.settingsStorageId)
        storage.save(settings)
    }
}
