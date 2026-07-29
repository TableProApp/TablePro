//
//  PluginManager+Inspector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginManager {
    func inspectorPlugin(forId id: String) -> (any DocumentInspectorPlugin)? {
        if let plugin = inspectorPlugins[id] { return plugin }
        activateInspector(id: id)
        return inspectorPlugins[id]
    }

    func inspectorPlugin(forFileExtension ext: String) -> (any DocumentInspectorPlugin)? {
        let needle = ext.lowercased()
        if let match = activatedInspector(matchingFileExtension: needle) {
            return match
        }
        guard let url = lazyInspectorFileExtensions[needle] else { return nil }
        activateLazyBundle(at: url)
        return activatedInspector(matchingFileExtension: needle)
    }

    func inspectorPlugin(forUTI uti: String) -> (any DocumentInspectorPlugin)? {
        if let match = activatedInspector(matchingUTI: uti) {
            return match
        }
        guard let url = lazyInspectorUTIs[uti] else { return nil }
        activateLazyBundle(at: url)
        return activatedInspector(matchingUTI: uti)
    }

    var allInspectorFileExtensions: Set<String> {
        var result = Set(lazyInspectorFileExtensions.keys)
        for plugin in inspectorPlugins.values {
            for ext in type(of: plugin).supportedFileExtensions {
                result.insert(ext.lowercased())
            }
        }
        return result
    }

    var allInspectorUTIs: Set<String> {
        var result = Set(lazyInspectorUTIs.keys)
        for plugin in inspectorPlugins.values {
            for uti in type(of: plugin).supportedUTIs {
                result.insert(uti)
            }
        }
        return result
    }

    private func activatedInspector(matchingFileExtension ext: String) -> (any DocumentInspectorPlugin)? {
        inspectorPlugins.values.first { plugin in
            type(of: plugin).supportedFileExtensions.contains { $0.lowercased() == ext }
        }
    }

    private func activatedInspector(matchingUTI uti: String) -> (any DocumentInspectorPlugin)? {
        inspectorPlugins.values.first { plugin in
            type(of: plugin).supportedUTIs.contains(uti)
        }
    }
}
