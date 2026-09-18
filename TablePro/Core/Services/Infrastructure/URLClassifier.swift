//
//  URLClassifier.swift
//  TablePro
//

import Foundation

@MainActor
internal enum URLClassifier {
    internal static func classify(_ url: URL) -> Result<LaunchIntent, DeeplinkError>? {
        if url.scheme == "tablepro" {
            return DeeplinkParser.parse(url)
        }
        if url.isFileURL {
            return classifyFile(url)
        }
        if isDatabaseURL(url) {
            return .success(.openDatabaseURL(url))
        }
        return nil
    }

    private static func classifyFile(_ url: URL) -> Result<LaunchIntent, DeeplinkError>? {
        let ext = url.pathExtension.lowercased()
        /// TablePro's own two are decided by name, and neither carries a signature to read.
        if ext == "tableplugin" {
            return .success(.installPlugin(url))
        }
        if ext == "tablepro" {
            return .success(.openConnectionShare(url))
        }
        /// Ahead of every other extension, so a database still reaches its driver when it is named
        /// `store.bin`, carries no extension, or wears another engine's.
        if let dbType = DatabaseFileClassifier.classify(url) {
            return .success(.openDatabaseFile(url, dbType))
        }
        return classifyByName(url, extension: ext)
    }

    /// What the name alone says, with nothing read from disk. The open panel asks this first, so
    /// browsing a folder of files it already recognises never touches a network volume.
    internal static func classifyByName(_ url: URL) -> Result<LaunchIntent, DeeplinkError>? {
        classifyByName(url, extension: url.pathExtension.lowercased())
    }

    private static func classifyByName(
        _ url: URL,
        extension ext: String
    ) -> Result<LaunchIntent, DeeplinkError>? {
        if ext == "tableplugin" {
            return .success(.installPlugin(url))
        }
        if ext == "tablepro" {
            return .success(.openConnectionShare(url))
        }
        if SQLFileService.supportedExtensions.contains(ext) {
            return .success(.openSQLFile(url))
        }
        if PluginManager.shared.allInspectorFileExtensions.contains(ext) {
            return .success(.openInspectorFile(url))
        }
        if let dbType = PluginManager.shared.allRegisteredFileExtensions[ext] {
            return .success(.openDatabaseFile(url, dbType))
        }
        return nil
    }

    private static func isDatabaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        let base = scheme
            .replacingOccurrences(of: "+ssh", with: "")
            .replacingOccurrences(of: "+srv", with: "")
        let registered = PluginManager.shared.allRegisteredURLSchemes
        return registered.contains(base) || registered.contains(scheme)
    }
}
