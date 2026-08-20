//
//  PluginSettingsSnapshot.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct PluginSettingsSnapshot {
    private var entries: [(plugin: any SettablePluginDiscoverable, data: Data)]

    init(plugins: [any SettablePluginDiscoverable]) {
        entries = plugins.compactMap { plugin in
            guard let data = plugin.snapshotSettingsData() else { return nil }
            return (plugin, data)
        }
    }

    func restore() {
        for entry in entries {
            entry.plugin.restoreSettingsData(entry.data)
        }
    }

    mutating func recapture(_ plugin: any SettablePluginDiscoverable) {
        guard let index = entries.firstIndex(where: { $0.plugin === plugin }),
              let data = plugin.snapshotSettingsData() else { return }
        entries[index].data = data
    }
}
