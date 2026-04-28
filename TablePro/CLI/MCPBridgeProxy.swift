import CryptoKit
import Foundation
import Security

struct MCPHandshake: Codable {
    let port: Int
    let token: String
    let pid: Int32
    let protocolVersion: String
    let tls: Bool?
    let tlsCertFingerprint: String?
}

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let serverCert = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }

        let serverFingerprint = sha256Fingerprint(of: serverCert)
        guard serverFingerprint == expectedFingerprint else {
            return (.cancelAuthenticationChallenge, nil)
        }

        return (.useCredential, URLCredential(trust: trust))
    }

    private func sha256Fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

final class MCPBridgeProxy {
    private static let pollInterval: TimeInterval = 0.2
    private static let pollTimeout: TimeInterval = 10.0
    private static let launchURL = "tablepro://integrations/start-mcp"

    private let handshakePath: String
    private var sessionId: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.handshakePath = "\(home)/Library/Application Support/TablePro/mcp-handshake.json"
    }

    func run() async {
        let handshake: MCPHandshake
        do {
            handshake = try await acquireHandshake()
        } catch {
            writeStderr("Error: \(error.localizedDescription)\n")
            writeJsonRpcError(
                id: .null,
                code: -32_000,
                message: "TablePro is not running. Launch the app and enable the MCP server."
            )
            exit(1)
        }

        let urlSession = makeSession(handshake: handshake)
        let scheme = (handshake.tls ?? false) ? "https" : "http"
        let baseUrl = "\(scheme)://127.0.0.1:\(handshake.port)/mcp"
        await readLoop(baseUrl: baseUrl, bearerToken: handshake.token, urlSession: urlSession)
    }

    private func acquireHandshake() async throws -> MCPHandshake {
        if let handshake = try? loadHandshake(), isProcessRunning(pid: handshake.pid) {
            return handshake
        }

        if (try? loadHandshake()) != nil {
            writeStderr("Stale handshake detected; relaunching TablePro\n")
            removeHandshake()
        }

        try launchHostApp()
        return try await pollForHandshake()
    }

    private func loadHandshake() throws -> MCPHandshake {
        let data = try Data(contentsOf: URL(fileURLWithPath: handshakePath))
        return try JSONDecoder().decode(MCPHandshake.self, from: data)
    }

    private func removeHandshake() {
        try? FileManager.default.removeItem(atPath: handshakePath)
    }

    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func launchHostApp() throws {
        writeStderr("TablePro not running; launching via \(Self.launchURL)\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Self.launchURL]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw BridgeError.launchFailed(status: process.terminationStatus)
        }
    }

    private func pollForHandshake() async throws -> MCPHandshake {
        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            if let handshake = try? loadHandshake(), isProcessRunning(pid: handshake.pid) {
                return handshake
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
        throw BridgeError.handshakeTimeout
    }

    private func makeSession(handshake: MCPHandshake) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60

        let delegate: URLSessionDelegate?
        if handshake.tls ?? false, let fingerprint = handshake.tlsCertFingerprint {
            delegate = CertificatePinningDelegate(expectedFingerprint: fingerprint)
        } else {
            delegate = nil
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func readLoop(baseUrl: String, bearerToken: String, urlSession: URLSession) async {
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
                    try await forwardAndEmit(
                        lineDataCopy,
                        baseUrl: baseUrl,
                        bearerToken: bearerToken,
                        urlSession: urlSession
                    )
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

    private func forwardAndEmit(
        _ body: Data,
        baseUrl: String,
        bearerToken: String,
        urlSession: URLSession
    ) async throws {
        guard let url = URL(string: baseUrl) else {
            throw BridgeError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            captureSessionId(from: httpResponse)
            let contentType = headerValue(httpResponse, forKey: "content-type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") {
                emitSSE(data)
                return
            }
        }

        writeStdout(data)
        writeStdout(Data([0x0A]))
    }

    private func emitSSE(_ data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else { return }
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
            let trimmed = payload.drop(while: { $0 == " " })
            guard !trimmed.isEmpty else { continue }
            if let payloadData = String(trimmed).data(using: .utf8) {
                writeStdout(payloadData)
                writeStdout(Data([0x0A]))
            }
        }
    }

    private func headerValue(_ response: HTTPURLResponse, forKey key: String) -> String? {
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let keyString = rawKey as? String,
                  keyString.lowercased() == key.lowercased(),
                  let valueString = rawValue as? String else { continue }
            return valueString
        }
        return nil
    }

    private func captureSessionId(from response: HTTPURLResponse) {
        guard let value = headerValue(response, forKey: "mcp-session-id") else { return }
        if sessionId == nil {
            writeStderr("Session established: \(value)\n")
        }
        sessionId = value
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
        var errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ] as [String: Any]
        ]

        switch id {
        case .null:
            errorResponse["id"] = NSNull()
        case .int(let value):
            errorResponse["id"] = value
        case .string(let value):
            errorResponse["id"] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: errorResponse) else { return }
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
    case launchFailed(status: Int32)
    case handshakeTimeout

    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            "Invalid MCP server URL"
        case .launchFailed(let status):
            "Failed to launch TablePro (open exit \(status))"
        case .handshakeTimeout:
            "Timed out waiting for TablePro MCP server to start"
        }
    }
}
