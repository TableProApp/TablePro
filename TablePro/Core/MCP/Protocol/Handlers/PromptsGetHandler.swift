import Foundation
import os

public struct PromptsGetHandler: MCPMethodHandler {
    public static let method = "prompts/get"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Prompts")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        guard let name = params?["name"]?.stringValue, !name.isEmpty else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: name")
        }
        guard let definition = MCPPromptCatalog.prompt(named: name) else {
            throw MCPProtocolError.invalidParams(detail: "Unknown prompt: \(name)")
        }

        let arguments = try MCPTextArguments.strict(params?["arguments"], parameter: "arguments")
        try Self.validate(arguments, against: definition)
        try await context.throwIfCancelled()

        let renderContext = MCPPromptRenderContext(
            principal: context.principal,
            arguments: arguments,
            schema: MCPPromptSchemaReader(services: services)
        )

        do {
            let rendering = try await definition.render(renderContext)
            Self.logger.debug(
                """
                prompts/get name=\(name, privacy: .public) \
                messages=\(rendering.messages.count, privacy: .public)
                """
            )
            MCPAuditLogger.logResourceRead(
                principal: context.principal,
                uri: Self.auditUri(name: name),
                outcome: .success
            )
            return .complete(rendering.asPayload)
        } catch {
            let protocolError = error as? MCPProtocolError
            MCPAuditLogger.logResourceRead(
                principal: context.principal,
                uri: Self.auditUri(name: name),
                outcome: protocolError?.code == JsonRpcErrorCode.forbidden ? .denied : .error,
                errorMessage: protocolError?.message ?? error.localizedDescription
            )
            throw error
        }
    }

    private static func validate(_ arguments: [String: String], against definition: MCPPromptDefinition) throws {
        let known = Set(definition.arguments.map(\.name))
        let unknown = arguments.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw MCPProtocolError.invalidParams(
                detail: "Unknown arguments for prompt \(definition.name): \(unknown.joined(separator: ", "))"
            )
        }
        for argument in definition.arguments where argument.isRequired {
            let value = arguments[argument.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else {
                throw MCPProtocolError.invalidParams(detail: "Missing required argument: \(argument.name)")
            }
        }
    }

    private static func auditUri(name: String) -> String {
        "\(ResourcesUriRoute.scheme)://prompts/\(name)"
    }
}
