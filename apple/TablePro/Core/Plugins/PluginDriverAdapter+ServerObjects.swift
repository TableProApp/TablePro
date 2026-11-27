//
//  PluginDriverAdapter+ServerObjects.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension PluginDriverAdapter {
    private static let serverObjectsLogger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    var serverObjectKinds: [PluginServerObjectKind] { pluginDriver.serverObjectKinds }

    // A container kind is stamped with the schema it was read from, as routines are; a database kind
    // names no schema and reads with none.
    @concurrent
    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [ServerObjectInfo] {
        let isDatabaseScoped = pluginDriver.serverObjectKinds.first { $0.id == kindId }?.scope == .database
        let resolvedSchema = isDatabaseScoped ? nil : readSchema(schema)
        do {
            return try await pluginDriver.fetchServerObjects(ofKind: kindId, schema: resolvedSchema)
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

    @concurrent
    func fetchServerObject(_ object: ServerObjectInfo) async throws -> ServerObjectInfo {
        ServerObjectInfo(try await pluginDriver.fetchServerObject(object.pluginObject))
    }
}
