import Foundation

struct MCPHandshake: Codable {
    let port: Int
    let token: String
    let pid: Int32
    let protocolVersion: String
    let tls: Bool?
}

private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

final class MCPBridgeProxy {
    private let handshakePath: String
    private var sessionId: String?
    private let urlSession: URLSession
    private let sessionDelegate = TrustAllDelegate()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.handshakePath = "\(home)/Library/Application Support/com.TablePro/mcp-handshake.json"

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }

    func run() async {
        let handshake: MCPHandshake

        do {
            handshake = try loadHandshake()
        } catch {
            writeStderr("Error: \(error.localizedDescription)\n")
            writeJsonRpcError(
                id: .null,
                code: -32_000,
                message: "TablePro is not running. Launch the app and enable the MCP server."
            )
            exit(1)
        }

        guard isProcessRunning(pid: handshake.pid) else {
            writeStderr("Error: TablePro process \(handshake.pid) is not running\n")
            writeJsonRpcError(
                id: .null,
                code: -32_000,
                message: "TablePro is not running. Launch the app and enable the MCP server."
            )
            exit(1)
        }

        let scheme = (handshake.tls ?? false) ? "https" : "http"
        let baseUrl = "\(scheme)://127.0.0.1:\(handshake.port)/mcp"
        let bearerToken = handshake.token

        await readLoop(baseUrl: baseUrl, bearerToken: bearerToken)
    }

    private func loadHandshake() throws -> MCPHandshake {
        let data = try Data(contentsOf: URL(fileURLWithPath: handshakePath))
        return try JSONDecoder().decode(MCPHandshake.self, from: data)
    }

    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func readLoop(baseUrl: String, bearerToken: String) async {
        let stdin = FileHandle.standardInput
        var buffer = Data()

        while true {
            let chunk = stdin.availableData
            guard !chunk.isEmpty else {
                break
            }

            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard !lineData.isEmpty else { continue }

                let lineDataCopy = Data(lineData)
                let requestId = extractRequestId(from: lineDataCopy)

                do {
                    let responseData = try await forwardRequest(
                        lineDataCopy,
                        baseUrl: baseUrl,
                        bearerToken: bearerToken
                    )
                    writeStdout(responseData)
                    writeStdout(Data([0x0A]))
                } catch {
                    writeStderr("Request failed: \(error.localizedDescription)\n")
                    writeJsonRpcError(
                        id: requestId,
                        code: -32_000,
                        message: "Failed to reach TablePro: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func forwardRequest(
        _ body: Data,
        baseUrl: String,
        bearerToken: String
    ) async throws -> Data {
        guard let url = URL(string: baseUrl) else {
            throw BridgeError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            captureSessionId(from: httpResponse)
        }

        return data
    }

    private func captureSessionId(from response: HTTPURLResponse) {
        guard sessionId == nil else { return }

        let headerFields = response.allHeaderFields
        for (key, value) in headerFields {
            guard let keyString = key as? String else { continue }
            guard keyString.lowercased() == "mcp-session-id" else { continue }
            guard let valueString = value as? String else { continue }

            sessionId = valueString
            writeStderr("Session established: \(valueString)\n")
            return
        }
    }

    private func extractRequestId(from data: Data) -> JsonRpcId {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .null
        }

        guard let id = object["id"] else {
            return .null
        }

        if let intId = id as? Int {
            return .int(intId)
        }
        if let stringId = id as? String {
            return .string(stringId)
        }

        return .null
    }

    private func writeJsonRpcError(id: JsonRpcId, code: Int, message: String) {
        let idJson: String
        switch id {
        case .null:
            idJson = "null"
        case .int(let value):
            idJson = "\(value)"
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            idJson = "\"\(escaped)\""
        }

        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let json = "{\"jsonrpc\":\"2.0\",\"id\":\(idJson),\"error\":{\"code\":\(code),\"message\":\"\(escapedMessage)\"}}"
        guard let data = json.data(using: .utf8) else { return }
        writeStdout(data)
        writeStdout(Data([0x0A]))
    }

    private func writeStdout(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private func writeStderr(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private enum JsonRpcId {
    case null
    case int(Int)
    case string(String)
}

private enum BridgeError: LocalizedError {
    case invalidUrl

    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            "Invalid MCP server URL"
        }
    }
}
