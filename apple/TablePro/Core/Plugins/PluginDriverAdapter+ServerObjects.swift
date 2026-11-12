//
//  PluginDriverAdapter+ServerObjects.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension PluginDriverAdapter {
    private static let serverObjectsLogger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    var serverObjectKinds: [PluginServerObjectKind] { schemaPluginDriver.serverObjectKinds }

    // A container kind is stamped with the schema it was read from, as routines are; a database kind
    // names no schema and reads with none.
    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [ServerObjectInfo] {
        let isDatabaseScoped = schemaPluginDriver.serverObjectKinds.first { $0.id == kindId }?.scope == .database
        let resolvedSchema = isDatabaseScoped ? nil : (schema ?? schemaPluginDriver.currentSchema)
        do {
            return try await schemaPluginDriver.fetchServerObjects(ofKind: kindId, schema: resolvedSchema)
                .filter { $0.kindId == kindId }
                .map { ServerObjectInfo($0).adoptingSchema(resolvedSchema) }
                .sorted { ($0.schema ?? "", $0.name) < ($1.schema ?? "", $1.name) }
        } catch {
            Self.serverObjectsLogger.warning(
                "fetchServerObjects failed kind=\(kindId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            throw error
        }
    }

    func fetchServerObject(_ object: ServerObjectInfo) async throws -> ServerObjectInfo {
        ServerObjectInfo(try await schemaPluginDriver.fetchServerObject(object.pluginObject))
    }
}
