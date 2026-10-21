//
//  MariaDBClientPluginFolder.swift
//  TablePro
//

import Foundation

// MariaDB's client tools answer a server that asks for the password as typed (mysql_clear_password, or dialog for PAM)
// without TLS, and have no option that refuses it. Both are loaded from the plugin folder, so a run that might go
// without TLS points the tool at a folder that links every plugin but those two. Measured with mariadb-dump and mariadb
// 13.0.2 from Homebrew: they then fail with 2059 "Plugin dialog could not be loaded" before sending anything.
enum MariaDBClientPluginFolder {
    static let plaintextPasswordPlugins = ["mysql_clear_password", "dialog"]

    // The two install layouts MariaDB's build defines for this platform, relative to the prefix that holds bin.
    // Homebrew uses the first.
    private static let layouts = ["lib/plugin", "lib/mysql/plugin"]

    static func pluginDirectory(forTool path: String) -> URL? {
        let tool = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let prefix = tool.deletingLastPathComponent().deletingLastPathComponent()
        return layouts
            .map { prefix.appendingPathComponent($0, isDirectory: true) }
            .first { isDirectory($0) }
    }

    // A tool whose folder cannot be found gets an empty one: logins built into the tool still work, and none that
    // could send the password as typed.
    static func make(hiding hidden: [String], from source: URL?, in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let manager = FileManager.default
        let folder = parent.appendingPathComponent("tablepro-client-plugins-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let source else { return folder }
        let hiddenFiles = Set(hidden.map { "\($0).so" })
        let entries = (try? manager.contentsOfDirectory(atPath: source.path)) ?? []
        for entry in entries where !hiddenFiles.contains(entry) {
            try manager.createSymbolicLink(
                at: folder.appendingPathComponent(entry),
                withDestinationURL: source.appendingPathComponent(entry)
            )
        }
        return folder
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
