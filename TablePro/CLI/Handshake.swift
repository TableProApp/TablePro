import Foundation
import os

enum MCPHandshakeAcquisitionError: Error, LocalizedError, Equatable {
    case launchFailed(status: Int32)
    case timeout(lastFailure: String)
    case serverTurnedOff

    var errorDescription: String? {
        switch self {
        case .launchFailed(let status):
            return "Failed to launch TablePro (open exit \(status))"
        case .timeout(let lastFailure):
            return "Timed out waiting for a trusted TablePro MCP handshake (\(lastFailure))"
        case .serverTurnedOff:
            return "The TablePro MCP server is turned off. Turn it on in TablePro under Settings > MCP."
        }
    }
}

struct MCPHandshakeAcquirer: Sendable {
    private static let pollInterval: Duration = .milliseconds(200)
    private static let launchUrl = "tablepro://integrations/start-mcp"

    let handshakeUrl: URL
    let refusalUrl: URL
    let logger: any MCPBridgeLogger
    private let pollTimeout: Duration
    private let launchHostApp: @Sendable (any MCPBridgeLogger) throws -> Void

    init(
        logger: any MCPBridgeLogger,
        supportDirectory: URL = MCPHandshakeLocation.supportDirectory(),
        pollTimeout: Duration = .seconds(10),
        launchHostApp: @escaping @Sendable (any MCPBridgeLogger) throws -> Void = { try openHostApp(logger: $0) }
    ) {
        self.handshakeUrl = MCPHandshakeLocation.file(in: supportDirectory)
        self.refusalUrl = MCPHandshakeLocation.refusalFile(in: supportDirectory)
        self.logger = logger
        self.pollTimeout = pollTimeout
        self.launchHostApp = launchHostApp
    }

    func acquire() async throws -> MCPHandshakePayload {
        if let trusted = loadTrusted().payload {
            return trusted
        }
        let launchRequestedAt = Date()
        try launchHostApp(logger)
        return try await pollForTrustedHandshake(launchRequestedAt: launchRequestedAt)
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

    /// A forged refusal can only make the bridge give up, so it is read without the handshake's
    /// ownership checks.
    private func refusalAnswers(launchRequestedAt: Date) -> Bool {
        guard let data = try? Data(contentsOf: refusalUrl),
              let refusal = try? MCPHandshakeCoding.decoder().decode(MCPStartRefusal.self, from: data) else {
            return false
        }
        return refusal.answers(launchRequestedAt: launchRequestedAt)
    }

    /// `open` hands its own environment to the app it launches, which is how the flag arrives early
    /// enough for the app to stay out of the Dock and the app switcher. Nobody asked for this window
    /// of TablePro: a client did, to answer a question.
    static func openHostApp(logger: any MCPBridgeLogger) throws {
        logger.log(.info, "No trusted MCP handshake; launching TablePro via \(Self.launchUrl)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Self.launchUrl]
        var environment = ProcessInfo.processInfo.environment
        environment[BackgroundLaunchFlag.variable] = BackgroundLaunchFlag.value
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MCPHandshakeAcquisitionError.launchFailed(status: process.terminationStatus)
        }
    }

    private func pollForTrustedHandshake(launchRequestedAt: Date) async throws -> MCPHandshakePayload {
        let deadline = ContinuousClock().now.advanced(by: pollTimeout)
        var lastFailure = "no handshake file"
        while ContinuousClock().now < deadline {
            let attempt = loadTrusted()
            if let payload = attempt.payload {
                return payload
            }
            if refusalAnswers(launchRequestedAt: launchRequestedAt) {
                logger.log(.error, "TablePro refused to start the MCP server: it is turned off")
                throw MCPHandshakeAcquisitionError.serverTurnedOff
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
