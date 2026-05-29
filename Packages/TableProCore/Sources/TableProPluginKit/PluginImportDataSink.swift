//
//  PluginImportDataSink.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginImportDataSink: AnyObject, Sendable {
    var databaseTypeId: String { get }
    func execute(statement: String) async throws
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    func disableForeignKeyChecks() async throws
    func enableForeignKeyChecks() async throws
}

public extension PluginImportDataSink {
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}
