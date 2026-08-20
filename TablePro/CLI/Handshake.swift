import Foundation
import os

enum MCPHandshakeAcquisitionError: Error, LocalizedError {
    case launchFailed(status: Int32)
    case timeout(lastFailure: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let status):
            return "Failed to launch TablePro (open exit \(status))"
        case .timeout(let lastFailure):
            return "Timed out waiting for a trusted TablePro MCP handshake (\(lastFailure))"
        }
    }
}

struct MCPHandshakeAcquirer: Sendable {
    private static let pollInterval: Duration = .milliseconds(200)
    private static let pollTimeout: Duration = .seconds(10)
    private static let launchUrl = "tablepro://integrations/start-mcp"

    let handshakeUrl: URL
    let logger: any MCPBridgeLogger

    init(logger: any MCPBridgeLogger, supportDirectory: URL = MCPHandshakeLocation.supportDirectory()) {
        self.handshakeUrl = MCPHandshakeLocation.file(in: supportDirectory)
        self.logger = logger
    }

    func acquire() async throws -> MCPHandshakePayload {
        if let trusted = loadTrusted().payload {
            return trusted
        }
        try launchHostApp()
        return try await pollForTrustedHandshake()
    }

    private func loadTrusted() -> (payload: MCPHandshakePayload?, failure: String) {
        do {
            return (try MCPHandshakeTrust.load(at: handshakeUrl), "")
        } catch let failure as MCPHandshakeTrustFailure {
            return (nil, failure.localizedDescription)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func launchHostApp() throws {
        logger.log(.info, "No trusted MCP handshake; launching TablePro via \(Self.launchUrl)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Self.launchUrl]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MCPHandshakeAcquisitionError.launchFailed(status: process.terminationStatus)
        }
    }

    private func pollForTrustedHandshake() async throws -> MCPHandshakePayload {
        let deadline = ContinuousClock().now.advanced(by: Self.pollTimeout)
        var lastFailure = "no handshake file"
        while ContinuousClock().now < deadline {
            let attempt = loadTrusted()
            if let payload = attempt.payload {
                return payload
            }
            lastFailure = attempt.failure
            try? await Task.sleep(for: Self.pollInterval)
        }
        logger.log(.error, "Handshake never became trustworthy: \(lastFailure)")
        throw MCPHandshakeAcquisitionError.timeout(lastFailure: lastFailure)
    }
}

extension MCPHandshakePayload {
    func credentials() -> MCPUpstreamCredentials? {
        guard let endpoint else { return nil }
        return MCPUpstreamCredentials(endpoint: endpoint, bearerToken: token)
    }
}
