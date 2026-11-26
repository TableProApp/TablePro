//
//  CatalogSideObjects.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The kinds a catalog load reads after its table list, asked of the driver at once: an engine that answers several
/// catalog reads in one round trip pays one, where asking each kind on its own pays one per kind.
struct CatalogSideRequest: Sendable, Equatable {
    var schema: String?
    var schemas = false
    var routines = false
    var triggers = false
    var userDefinedTypes = false
    var serverObjectKinds: [String] = []
}

/// One answer per kind asked, nil for a kind not asked. Each kind fails alone.
struct CatalogSideObjects: Sendable {
    var schemas: Result<[String], any Error>?
    var routines: Result<[RoutineInfo], any Error>?
    var triggers: Result<[TriggerInfo], any Error>?
    var userDefinedTypes: Result<[UserDefinedTypeInfo], any Error>?
    var serverObjects: [String: Result<[ServerObjectInfo], any Error>] = [:]
}

extension DatabaseDriver {
    /// Side by side on the driver's own methods, for a driver with no batched read: on one connection they still
    /// answer one at a time.
    func fetchCatalogSideObjectsSideBySide(_ request: CatalogSideRequest) async -> CatalogSideObjects {
        let schema = request.schema
        async let schemas: Result<[String], any Error>? = request.schemas
            ? Self.catching { try await self.fetchSchemas() }
            : nil
        async let routines: Result<[RoutineInfo], any Error>? = request.routines
            ? Self.catching { try await self.fetchRoutines(schema: schema) }
            : nil
        async let triggers: Result<[TriggerInfo], any Error>? = request.triggers
            ? Self.catching { try await self.fetchAllTriggers(schema: schema) }
            : nil
        async let types: Result<[UserDefinedTypeInfo], any Error>? = request.userDefinedTypes
            ? Self.catching { try await self.fetchUserDefinedTypes(schema: schema) }
            : nil
        let serverObjects = await withTaskGroup(of: (String, Result<[ServerObjectInfo], any Error>).self) { group in
            for kindId in request.serverObjectKinds {
                group.addTask {
                    (kindId, await Self.catching { try await self.fetchServerObjects(ofKind: kindId, schema: schema) })
                }
            }
            var answers: [String: Result<[ServerObjectInfo], any Error>] = [:]
            for await (kindId, answer) in group {
                answers[kindId] = answer
            }
            return answers
        }
        return await CatalogSideObjects(
            schemas: schemas, routines: routines, triggers: triggers, userDefinedTypes: types, serverObjects: serverObjects
        )
    }

    static func catching<T: Sendable>(_ read: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await read())
        } catch {
            return .failure(error)
        }
    }
}
