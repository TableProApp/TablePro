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
    static let requestTimeout: TimeInterval = 360

    private let port: Int
    private let token: String
    private let session: URLSession

    public init(port: Int, token: String, session: URLSession = CLIServerClient.makeSession()) {
        self.port = port
        self.token = token
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
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

        var request = URLRequest(url: endpoint(path: "/mcp"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(MCPProtocolVersion.latest.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        request.setValue(MCPBase64Sentinel.encodeIfNeeded(name), forHTTPHeaderField: "Mcp-Name")

        let (data, response) = try await send(request)
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

    private func responseMessage(data: Data, response: HTTPURLResponse, requestId: JsonRpcId) async throws -> JsonRpcMessage {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
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
        if response.statusCode == 401 {
            throw CLIServerClientError.tokenRejected("HTTP 401")
        }
        throw CLIFailure(.failure, "TablePro's MCP server answered HTTP \(response.statusCode).")
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
    public static func exchange(
        code: String,
        verifier: String,
        port: Int,
        session: URLSession = makeSession()
    ) async throws -> String {
        var request = URLRequest(url: endpoint(port: port, path: "/v1/integrations/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier])

        let (data, response) = try await send(request, session: session)
        let body = try? JSONDecoder().decode(JsonValue.self, from: data)
        guard response.statusCode == 200, let token = body?["token"]?.stringValue, !token.isEmpty else {
            let detail = body?["error"]?.stringValue ?? "HTTP \(response.statusCode)"
            throw CLIFailure(.refused, "TablePro did not hand over a token: \(detail).")
        }
        return token
    }

    private func endpoint(path: String) -> URL {
        Self.endpoint(port: port, path: path)
    }

    static func endpoint(port: Int, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Self.send(request, session: session)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CLIFailure(.timedOut, "TablePro did not answer in time.")
        } catch {
            throw CLIFailure(.failure, "TablePro's MCP server is not reachable: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CLIFailure(.failure, "TablePro's MCP server did not answer over HTTP.")
        }
        return (data, http)
    }
}
