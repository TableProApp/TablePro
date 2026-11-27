//
//  PluginCatalogSideObjects.swift
//  TableProPluginKit
//

import Foundation

/// The kinds a catalog load reads after its table list, asked of the driver at once so an engine that can answer
/// several reads in one round trip does, instead of one round trip per kind.
public struct PluginCatalogSideRequest: Sendable, Equatable {
    public var schema: String?
    public var schemas: Bool
    public var routines: Bool
    public var triggers: Bool
    public var userDefinedTypes: Bool
    public var serverObjectKinds: [String]

    public init(
        schema: String?,
        schemas: Bool,
        routines: Bool,
        triggers: Bool,
        userDefinedTypes: Bool,
        serverObjectKinds: [String]
    ) {
        self.schema = schema
        self.schemas = schemas
        self.routines = routines
        self.triggers = triggers
        self.userDefinedTypes = userDefinedTypes
        self.serverObjectKinds = serverObjectKinds
    }
}

/// One answer per kind asked, nil for a kind not asked. Each kind fails alone: a refused routine list leaves the
/// schema list it was sent with standing.
public struct PluginCatalogSideObjects: Sendable {
    public var schemas: Result<[String], any Error>?
    public var routines: Result<[PluginRoutineInfo], any Error>?
    public var triggers: Result<[PluginTriggerInfo], any Error>?
    public var userDefinedTypes: Result<[PluginUserDefinedTypeInfo], any Error>?
    public var serverObjects: [String: Result<[PluginServerObjectInfo], any Error>]

    public init(
        schemas: Result<[String], any Error>? = nil,
        routines: Result<[PluginRoutineInfo], any Error>? = nil,
        triggers: Result<[PluginTriggerInfo], any Error>? = nil,
        userDefinedTypes: Result<[PluginUserDefinedTypeInfo], any Error>? = nil,
        serverObjects: [String: Result<[PluginServerObjectInfo], any Error>] = [:]
    ) {
        self.schemas = schemas
        self.routines = routines
        self.triggers = triggers
        self.userDefinedTypes = userDefinedTypes
        self.serverObjects = serverObjects
    }
}

public extension PluginDatabaseDriver {
    /// Asks each kind in turn: the answer for an engine that has not measured a batched read.
    func fetchCatalogSideObjectsOneByOne(_ request: PluginCatalogSideRequest) async -> PluginCatalogSideObjects {
        var answers = PluginCatalogSideObjects()
        if request.schemas {
            answers.schemas = await Self.catching { try await fetchSchemas() }
        }
        if request.routines {
            answers.routines = await Self.catching { try await fetchRoutines(schema: request.schema) }
        }
        if request.triggers {
            answers.triggers = await Self.catching { try await fetchAllTriggers(schema: request.schema) }
        }
        if request.userDefinedTypes {
            answers.userDefinedTypes = await Self.catching { try await fetchUserDefinedTypes(schema: request.schema) }
        }
        for kindId in request.serverObjectKinds {
            // A kind that lives in the database, not in a container, is asked with no schema, as on its own.
            let isDatabaseScoped = serverObjectKinds.first { $0.id == kindId }?.scope == .database
            let schema = isDatabaseScoped ? nil : request.schema
            answers.serverObjects[kindId] = await Self.catching {
                try await fetchServerObjects(ofKind: kindId, schema: schema)
            }
        }
        return answers
    }

    private static func catching<T>(_ read: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await read())
        } catch {
            return .failure(error)
        }
    }
}
