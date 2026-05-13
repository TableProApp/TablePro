import Foundation

public protocol PluginProcedureFunctionSupport {
    func fetchProcedures(schema: String?) async throws -> [PluginRoutineInfo]
    func fetchFunctions(schema: String?) async throws -> [PluginRoutineInfo]
    func fetchProcedureDDL(name: String, schema: String?) async throws -> String
    func fetchFunctionDDL(name: String, schema: String?) async throws -> String
}

public struct PluginRoutineInfo: Codable, Sendable {
    public let name: String
    public let returnType: String?
    public let language: String?

    public init(name: String, returnType: String? = nil, language: String? = nil) {
        self.name = name
        self.returnType = returnType
        self.language = language
    }
}
