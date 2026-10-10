//
//  DataGripConsoleReader.swift
//  TablePro
//

import Foundation

enum DataGripConsoleReader {
    struct DataSource: Sendable, Equatable {
        let uuid: String
        let isMongo: Bool
    }

    private struct ConsoleFolder {
        let dataSource: DataSource
        let url: URL
        let baseName: String
    }

    private static let defaultBaseName = "console"

    static func savedQueries(
        dataSources: [DataSource],
        configDirs: [URL],
        limit: Int
    ) throws -> [ForeignSavedQuery] {
        var queries: [ForeignSavedQuery] = []
        var baseNames: [URL: String] = [:]
        for folder in consoleFolders(dataSources: dataSources, configDirs: configDirs, baseNames: &baseNames) {
            for entry in entries(in: folder) {
                try Task.checkCancellation()
                guard let content = ForeignSQLFileTree.content(of: entry, limit: limit) else { continue }
                let name = (entry.fileName as NSString).deletingPathExtension
                queries.append(ForeignSavedQuery(
                    name: name,
                    content: content,
                    keyword: nil,
                    folderPath: entry.folderPath,
                    sourceConnectionId: folder.dataSource.uuid,
                    isAutoNamed: isAutoNamed(name, baseName: folder.baseName)
                ))
            }
        }
        return queries
    }

    static func count(dataSources: [DataSource], configDirs: [URL]) -> Int {
        var baseNames: [URL: String] = [:]
        return consoleFolders(dataSources: dataSources, configDirs: configDirs, baseNames: &baseNames)
            .reduce(into: 0) { total, folder in
                total += entries(in: folder).count(where: ForeignSQLFileTree.isCountable)
            }
    }

    // DataGrip names consoles `<base>`, `<base>_1`, `<base>_2`; the base is a setting that defaults to `console`.
    static func isAutoNamed(_ name: String, baseName: String) -> Bool {
        let lowered = name.lowercased()
        let base = baseName.lowercased()
        guard lowered != base else { return true }
        guard lowered.hasPrefix(base + "_") else { return false }
        let number = lowered.dropFirst(base.count + 1)
        guard let first = number.first, first != "0", number.count <= 5 else { return false }
        return number.allSatisfy { ("0"..."9").contains($0) }
    }

    static func baseName(configDir: URL) -> String {
        let url = configDir.appendingPathComponent("options/QueryFileSettings.xml")
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let node = try? document.nodes(forXPath: "//option[@name='scratchesName']/@value").first,
              let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return defaultBaseName }
        return value
    }

    // An IDE upgrade copies consoles into the new config dir, so only the newest copy of each data source counts.
    private static func consoleFolders(
        dataSources: [DataSource],
        configDirs: [URL],
        baseNames: inout [URL: String]
    ) -> [ConsoleFolder] {
        var seen: Set<String> = []
        var folders: [ConsoleFolder] = []
        // The uuid comes from a project's dataSources.xml, which a repository can carry, so it never
        // becomes a path unless it is a UUID.
        for dataSource in dataSources where UUID(uuidString: dataSource.uuid) != nil && seen.insert(dataSource.uuid).inserted {
            for configDir in configDirs {
                let url = configDir.appendingPathComponent("consoles/db", isDirectory: true)
                    .appendingPathComponent(dataSource.uuid, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let baseName = baseNames[configDir] ?? Self.baseName(configDir: configDir)
                baseNames[configDir] = baseName
                folders.append(ConsoleFolder(dataSource: dataSource, url: url, baseName: baseName))
                break
            }
        }
        return folders
    }

    private static func entries(in folder: ConsoleFolder) -> [ForeignSQLFileTree.Entry] {
        ForeignSQLFileTree.entries(under: folder.url) { fileName in
            switch (fileName as NSString).pathExtension.lowercased() {
            case "sql": return true
            case "js": return folder.dataSource.isMongo
            default: return false
            }
        }
    }
}
