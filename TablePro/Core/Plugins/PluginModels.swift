//
//  PluginModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct PluginEntry: Identifiable {
    let id: String
    let bundle: Bundle
    let url: URL
    let source: PluginSource
    let name: String
    var version: String
    let pluginDescription: String
    let capabilities: [PluginCapability]
    var isEnabled: Bool

    let databaseTypeId: String?
    let additionalTypeIds: [String]
    let pluginIconName: String
    let defaultPort: Int?
}

enum PluginSource {
    case builtIn
    case userInstalled
}

extension PluginEntry {
    var exportPlugin: (any ExportFormatPlugin.Type)? {
        bundle.principalClass as? any ExportFormatPlugin.Type
    }
}
