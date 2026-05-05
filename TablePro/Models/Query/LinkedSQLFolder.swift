//
//  LinkedSQLFolder.swift
//  TablePro
//

import Foundation

internal struct LinkedSQLFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var isEnabled: Bool
    var connectionId: UUID?

    var name: String { (path as NSString).lastPathComponent }

    var expandedURL: URL {
        URL(fileURLWithPath: PathPortability.expandHome(path))
    }

    init(
        id: UUID = UUID(),
        path: String,
        isEnabled: Bool = true,
        connectionId: UUID? = nil
    ) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
        self.connectionId = connectionId
    }
}
