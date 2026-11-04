//
//  PluginExportedDatabaseImport.swift
//  TableProPluginKit
//

import Foundation

public extension PluginDatabaseDriver {
    func importExportedDatabase(from folder: URL, into file: URL) async throws {
        throw PluginDriverUnsupportedOperation.importExportedDatabase
    }
}
