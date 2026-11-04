import Foundation

public enum CLIClientIdentity {
    // The app files a query under Command Line when a request names this client.
    public static let name = "tablepro-cli"
    public static let title = "Command Line"
    public static let pairingName = "tablepro command"
}

public enum CLIServerClientError: Error, Sendable, Equatable {
    // Revoked, expired or unknown.
    case tokenRejected(String)
}

public struct CLIServerClient: Sendable {
    static let requestTimeout: Duration = .seconds(360)

    private let socketPath: String
    private let token: String

    public init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    public func callTool(_ name: String, arguments: [String: JsonValue]) async throws -> JsonValue {
        // The server tracks a call in flight by token and id, and every run of this command shares one token.
        let requestId = JsonRpcId.string(UUID().uuidString)
        let params: JsonValue = .object([
            "name": .string(name),
            "arguments": .object(arguments),
            "_meta": .object([
                MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue),
                MCPMetaKeys.clientCapabilities: .object([:]),
                MCPMetaKeys.clientInfo: .object([
                    "name": .string(CLIClientIdentity.name),
                    "title": .string(CLIClientIdentity.title),
                    "version": .string("1")
                ])
            ])
        ])
        let body = try JsonRpcCodec.encode(.request(JsonRpcRequest(id: requestId, method: "tools/call", params: params)))

        let request = MCPSocketHttpRequest(
            path: "/mcp",
            headers: [
                ("Content-Type", "application/json"),
                ("Accept", "application/json, text/event-stream"),
                ("Authorization", "Bearer \(token)"),
                ("MCP-Protocol-Version", MCPProtocolVersion.latest.rawValue),
                ("Mcp-Method", "tools/call"),
                ("Mcp-Name", MCPBase64Sentinel.encodeIfNeeded(name))
            ],
            body: body
        )

        let (data, response) = try await Self.send(request, socketPath: socketPath)
        let message = try await responseMessage(data: data, response: response, requestId: requestId)
        switch message {
        case .successResponse(let success):
            return try Self.toolOutput(success.result)
        case .errorResponse(let failure):
            if failure.error.code == JsonRpcErrorCode.unauthenticated || failure.error.code == JsonRpcErrorCode.expired {
                throw CLIServerClientError.tokenRejected(failure.error.message)
            }
            throw CLIFailure.fromRpcError(code: failure.error.code, message: failure.error.message)
        case .request, .notification:
            throw CLIFailure(.failure, "TablePro answered with something that is not a response.")
        }
    }

    static func toolOutput(_ result: JsonValue) throws -> JsonValue {
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue
        if result["isError"]?.boolValue == true {
            throw CLIFailure.fromToolError(text: text ?? "internal_failure: The tool failed without a message.")
        }
        if let structured = result["structuredContent"] {
            return structured
        }
        guard let text, let decoded = try? JSONDecoder().decode(JsonValue.self, from: Data(text.utf8)) else {
            throw CLIFailure(.failure, "TablePro returned a result this command cannot read.")
        }
        return decoded
    }

    private func responseMessage(data: Data, response: CLIServerResponse, requestId: JsonRpcId) async throws -> JsonRpcMessage {
        let contentType = response.headers.value(for: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            let decoder = SseDecoder()
            for frame in await decoder.feed(data) {
                guard let message = try? JsonRpcCodec.decode(Data(frame.data.utf8)) else { continue }
                if Self.answers(message, requestId: requestId) {
                    return message
                }
            }
            throw CLIFailure(.failure, "TablePro closed the stream before it answered.")
        }
        if let message = try? JsonRpcCodec.decode(data) {
            return message
        }
        if response.status == 401 {
            throw CLIServerClientError.tokenRejected("HTTP 401")
        }
        throw CLIFailure(.failure, "TablePro's MCP server answered HTTP \(response.status).")
    }

    private static func answers(_ message: JsonRpcMessage, requestId: JsonRpcId) -> Bool {
        switch message {
        case .successResponse(let success):
            return success.id == requestId
        case .errorResponse(let failure):
            return failure.id == requestId || failure.id == nil
        case .request, .notification:
            return false
        }
    }

    // The exchange takes no bearer token: the one-time code and the verifier are the credential.
    public static func exchange(code: String, verifier: String, socketPath: String) async throws -> String {
        let request = MCPSocketHttpRequest(
            path: "/v1/integrations/exchange",
            headers: [("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])
        )

        let (data, response) = try await send(request, socketPath: socketPath)
        let body = try? JSONDecoder().decode(JsonValue.self, from: data)
        guard response.status == 200, let token = body?["token"]?.stringValue, !token.isEmpty else {
            let detail = body?["error"]?.stringValue ?? "HTTP \(response.status)"
            throw CLIFailure(.refused, "TablePro did not hand over a token: \(detail).")
        }
        return token
    }

    private static func send(_ request: MCPSocketHttpRequest, socketPath: String) async throws -> (Data, CLIServerResponse) {
        do {
            let response = try await MCPUnixSocketHttpClient.send(request, socketPath: socketPath, idleTimeout: requestTimeout)
            let data = try await response.collectBody()
            return (data, CLIServerResponse(status: response.status, headers: response.headers))
        } catch MCPSocketHttpError.timedOut {
            throw CLIFailure(.timedOut, "TablePro did not answer in time.")
        } catch {
            throw CLIFailure(.failure, "TablePro's MCP server is not reachable: \(error.localizedDescription)")
        }
    }
}

private struct CLIServerResponse {
    let status: Int
    let headers: HttpHeaders
}
