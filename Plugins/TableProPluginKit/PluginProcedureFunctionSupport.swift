import Foundation

/// Superseded by `PluginDatabaseDriver.fetchRoutines(schema:)` and `fetchRoutineDDL(_:)`, which a
/// driver gets defaults for. It stays declared because removing a published protocol deletes its
/// descriptor symbol and every already-built plugin that referenced it fails to load; the default
/// implementation of `fetchRoutines(schema:)` adopts a conformer of this protocol so one keeps
/// working unchanged.
public protocol PluginProcedureFunctionSupport {
    func fetchProcedures(schema: String?) async throws -> [PluginRoutineInfo]
    func fetchFunctions(schema: String?) async throws -> [PluginRoutineInfo]
    func fetchProcedureDDL(name: String, schema: String?) async throws -> String
    func fetchFunctionDDL(name: String, schema: String?) async throws -> String
}

public enum PluginRoutineKind: String, Codable, Sendable {
    case procedure
    case function
}

public struct PluginRoutineInfo: Codable, Sendable {
    public let name: String
    public let returnType: String?
    public let language: String?
    public let schema: String?
    public let kind: PluginRoutineKind

    /// What the engine calls this routine's parameter list, spelled the way the engine spells it,
    /// including the parentheses: `(date)`, `(geometry, integer)`. Nil when the engine has no
    /// overloading and offers no parameter list.
    public let argumentSignature: String?

    /// Whatever the driver needs to address this exact routine again when asked for its DDL: a
    /// PostgreSQL oid, a Snowflake argument-type list, an Oracle overload position. Opaque to the
    /// app, which only ever hands it back.
    public let identity: String?

    /// The source, when the same read that listed the routine already returned it. Never part of
    /// the routine's identity: a definition that changes must not change which routine this is.
    public let definition: String?

    public let attributes: [PluginObjectAttribute]

    public init(
        name: String,
        kind: PluginRoutineKind,
        schema: String? = nil,
        returnType: String? = nil,
        language: String? = nil,
        argumentSignature: String? = nil,
        identity: String? = nil,
        definition: String? = nil,
        attributes: [PluginObjectAttribute] = []
    ) {
        self.name = name
        self.kind = kind
        self.schema = schema
        self.returnType = returnType
        self.language = language
        self.argumentSignature = argumentSignature
        self.identity = identity
        self.definition = definition
        self.attributes = attributes
    }

    @_disfavoredOverload
    public init(name: String, returnType: String? = nil, language: String? = nil) {
        self.name = name
        self.kind = .function
        self.schema = nil
        self.returnType = returnType
        self.language = language
        self.argumentSignature = nil
        self.identity = nil
        self.definition = nil
        self.attributes = []
    }

    public func adopting(kind: PluginRoutineKind, schema: String?) -> PluginRoutineInfo {
        PluginRoutineInfo(
            name: name,
            kind: kind,
            schema: self.schema ?? schema,
            returnType: returnType,
            language: language,
            argumentSignature: argumentSignature,
            identity: identity,
            definition: definition,
            attributes: attributes
        )
    }
}
