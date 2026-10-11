//
//  DBeaverScriptReader.swift
//  TablePro
//

import Foundation

enum DBeaverScriptReader {
    private static let scriptsFolder = "Scripts"

    static func savedQueries(projectURL: URL, limit: Int) throws -> [ForeignSavedQuery] {
        let bindings = dataSourceBindings(projectURL: projectURL)
        var queries: [ForeignSavedQuery] = []
        for entry in scriptEntries(projectURL: projectURL) {
            try Task.checkCancellation()
            guard let content = ForeignSQLFileTree.content(of: entry, limit: limit) else { continue }
            let name = (entry.fileName as NSString).deletingPathExtension
            let resourcePath = ([scriptsFolder] + entry.folderPath + [entry.fileName]).joined(separator: "/")
            queries.append(ForeignSavedQuery(
                name: name,
                content: content,
                keyword: nil,
                folderPath: entry.folderPath,
                sourceConnectionId: bindings[resourcePath],
                isAutoNamed: isAutoNamed(name)
            ))
        }
        return queries
    }

    static func count(projectURL: URL) -> Int {
        scriptEntries(projectURL: projectURL).count(where: ForeignSQLFileTree.isCountable)
    }

    // DBeaver names a new script `Script`, then `Script-1`, `Script-2` and so on.
    static func isAutoNamed(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered != "script" else { return true }
        guard lowered.hasPrefix("script-") else { return false }
        let number = lowered.dropFirst("script-".count)
        return !number.isEmpty && number.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func scriptEntries(projectURL: URL) -> [ForeignSQLFileTree.Entry] {
        ForeignSQLFileTree.entries(under: projectURL.appendingPathComponent(scriptsFolder, isDirectory: true)) {
            $0.lowercased().hasSuffix(".sql")
        }
    }

    private static func dataSourceBindings(projectURL: URL) -> [String: String] {
        let url = projectURL.appendingPathComponent(".dbeaver/project-metadata.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = json["resources"] as? [String: Any] else { return [:] }
        return resources.compactMapValues { properties in
            ((properties as? [String: Any])?["default-datasource"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
