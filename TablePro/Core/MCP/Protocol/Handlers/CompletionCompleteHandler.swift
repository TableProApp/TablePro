import Foundation
import os

public struct CompletionCompleteHandler: MCPMethodHandler {
    public static let method = "completion/complete"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Completion")

    private let provider: MCPCompletionProvider

    public init(provider: MCPCompletionProvider) {
        self.provider = provider
    }

    public init(services: MCPToolServices) {
        self.init(provider: MCPCompletionProvider(services: services))
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let reference = try MCPCompletionReference.decode(params?["ref"])
        try reference.validate()

        guard let argument = params?["argument"], !argument.isNull else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: argument")
        }
        guard let argumentName = argument["name"]?.stringValue, !argumentName.isEmpty else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: argument.name")
        }
        guard let argumentValue = argument["value"]?.stringValue else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: argument.value")
        }

        let resolvedArguments = MCPTextArguments.lenient(params?["context"]?["arguments"])
        try await context.throwIfCancelled()

        let result = await provider.complete(
            reference: reference,
            argumentName: argumentName,
            argumentValue: argumentValue,
            context: resolvedArguments,
            principal: context.principal
        )

        Self.logger.debug(
            """
            completion/complete ref=\(reference.describedReference, privacy: .public) \
            argument=\(argumentName, privacy: .public) values=\(result.values.count, privacy: .public)
            """
        )
        return .complete(["completion": result.asJsonValue])
    }
}
