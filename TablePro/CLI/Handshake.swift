import CryptoKit
import Foundation
import Security

struct MCPBridgeHandshake: Codable, Sendable {
    let port: Int
    let token: String
    let pid: Int32
    let protocolVersion: String
    let tls: Bool?
    let tlsCertFingerprint: String?
}

enum MCPHandshakeError: Error, LocalizedError {
    case launchFailed(status: Int32)
    case timeout
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .launchFailed(let status):
            return "Failed to launch TablePro (open exit \(status))"
        case .timeout:
            return "Timed out waiting for TablePro MCP server to start"
        case .fileNotFound:
            return "Handshake file not found"
        }
    }
}

struct MCPHandshakeAcquirer: Sendable {
    private static let pollInterval: Duration = .milliseconds(200)
    private static let pollTimeout: Duration = .seconds(10)
    private static let launchUrl = "tablepro://integrations/start-mcp"

    let handshakePath: String
    let logger: any MCPBridgeLogger

    init(logger: any MCPBridgeLogger) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.handshakePath = "\(home)/Library/Application Support/TablePro/mcp-handshake.json"
        self.logger = logger
    }

    func acquire() async throws -> MCPBridgeHandshake {
        if let existing = try? load(), isProcessRunning(pid: existing.pid) {
            return existing
        }

        if (try? load()) != nil {
            logger.log(.warning, "Stale handshake detected; relaunching TablePro")
            removeHandshake()
        }

        try launchHostApp()
        return try await pollForHandshake()
    }

    private func load() throws -> MCPBridgeHandshake {
        let url = URL(fileURLWithPath: handshakePath)
        guard FileManager.default.fileExists(atPath: handshakePath) else {
            throw MCPHandshakeError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MCPBridgeHandshake.self, from: data)
    }

    private func removeHandshake() {
        try? FileManager.default.removeItem(atPath: handshakePath)
    }

    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func launchHostApp() throws {
        logger.log(.info, "TablePro not running; launching via \(Self.launchUrl)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Self.launchUrl]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw MCPHandshakeError.launchFailed(status: process.terminationStatus)
        }
    }

    private func pollForHandshake() async throws -> MCPBridgeHandshake {
        let deadline = ContinuousClock().now.advanced(by: Self.pollTimeout)
        while ContinuousClock().now < deadline {
            if let handshake = try? load(), isProcessRunning(pid: handshake.pid) {
                return handshake
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        throw MCPHandshakeError.timeout
    }
}

extension MCPBridgeHandshake {
    func endpoint() -> URL? {
        let scheme = (tls ?? false) ? "https" : "http"
        return URL(string: "\(scheme)://127.0.0.1:\(port)/mcp")
    }
}
