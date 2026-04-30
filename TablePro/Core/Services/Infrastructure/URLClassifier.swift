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
        if ext == "tableplugin" {
            return .success(.installPlugin(url))
        }
        if ext == "tablepro" {
            return .success(.openConnectionShare(url))
        }
        if ext == "sql" {
            return .success(.openSQLFile(url))
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
