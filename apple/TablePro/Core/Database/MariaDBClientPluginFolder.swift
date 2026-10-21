//
//  MariaDBClientPluginFolder.swift
//  TablePro
//

import Foundation

// MariaDB's client tools answer a server that asks for the password as typed (mysql_clear_password, dialog for PAM, and
// the test plugins Homebrew ships) without TLS, and have no option that refuses it. Every one of them is loaded from
// the plugin folder, so a run that might go without TLS points the tool at a private folder that links only the
// plugins that never send it. Measured with mariadb-dump and mariadb 13.0.2 from Homebrew: a server asking for any
// other plugin gets 2059 "Plugin dialog could not be loaded" before anything is sent.
struct MariaDBClientPluginFolder: Sendable, Equatable {
    // The app's MySQL driver allows the same sign-in methods without TLS (MySQLPlaintextPassword.methodsWithoutTLS).
    // mysql_native_password and mysql_old_password are built into the tools, and zstd is compression.
    static let allowedPlugins: Set<String> = [
        "caching_sha2_password",
        "sha256_password",
        "client_ed25519",
        "parsec",
        "auth_gssapi_client",
        "zstd"
    ]

    // Relative to the folder that holds bin: MariaDB's own layouts (Homebrew uses the first), then MacPorts', which
    // keeps bin and plugin side by side under lib/mariadb-<version>.
    private static let layouts = ["lib/plugin", "lib/mysql/plugin", "plugin"]

    let url: URL

    static func pluginDirectory(forTool path: String) -> URL? {
        let tool = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let prefix = tool.deletingLastPathComponent().deletingLastPathComponent()
        return layouts
            .map { prefix.appendingPathComponent($0, isDirectory: true) }
            .first { isDirectory($0) }
    }

    // A tool whose folder cannot be found gets an empty one: the built-in sign-ins still work, and nothing that could
    // send the password as typed.
    static func make(
        from source: URL?,
        in parent: URL = FileManager.default.temporaryDirectory
    ) throws -> MariaDBClientPluginFolder {
        let manager = FileManager.default
        let folder = parent.appendingPathComponent("tablepro-client-plugins-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let source else { return MariaDBClientPluginFolder(url: folder) }
        for name in allowedPlugins.sorted() {
            let file = "\(name).so"
            let target = source.appendingPathComponent(file)
            guard manager.fileExists(atPath: target.path) else { continue }
            try manager.createSymbolicLink(at: folder.appendingPathComponent(file), withDestinationURL: target)
        }
        return MariaDBClientPluginFolder(url: folder)
    }

    // A plugin left out of the folder is one that sends the password as typed. One that was allowed but could not be
    // loaded keeps the tool's own words.
    func refusal(in stderr: String) -> String? {
        let refused = stderr.matches(of: #/Plugin ([A-Za-z0-9_]+) could not be loaded/#).map { String($0.output.1) }
        guard refused.contains(where: { !Self.allowedPlugins.contains($0) }) else { return nil }
        return MySQLClientArguments.plaintextPasswordRefusal
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
