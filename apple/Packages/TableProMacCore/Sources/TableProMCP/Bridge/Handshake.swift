import AppKit
import Foundation
import os
import TableProProcess

public enum MCPHandshakeAcquisitionError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timeout(lastFailure: String)
    case serverTurnedOff

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Failed to launch TablePro: \(reason)"
        case .timeout(let lastFailure):
            return "Timed out waiting for a trusted TablePro MCP handshake (\(lastFailure))"
        case .serverTurnedOff:
            return "The TablePro MCP server is turned off. Turn it on in TablePro under Settings > MCP."
        }
    }
}

public struct MCPHandshakeAcquirer: Sendable {
    private static let pollInterval: Duration = .milliseconds(200)
    private static let launchUrl = "tablepro://integrations/start-mcp"

    let handshakeUrl: URL
    let refusalUrl: URL
    let logger: any MCPBridgeLogger
    private let pollTimeout: Duration
    private let launchHostApp: @Sendable (any MCPBridgeLogger) async throws -> Void

    public init(
        logger: any MCPBridgeLogger,
        supportDirectory: URL = MCPHandshakeLocation.supportDirectory(),
        pollTimeout: Duration = .seconds(10),
        launchHostApp: @escaping @Sendable (any MCPBridgeLogger) async throws -> Void = { try await openHostApp(logger: $0) }
    ) {
        self.handshakeUrl = MCPHandshakeLocation.file(in: supportDirectory)
        self.refusalUrl = MCPHandshakeLocation.refusalFile(in: supportDirectory)
        self.logger = logger
        self.pollTimeout = pollTimeout
        self.launchHostApp = launchHostApp
    }

    public func acquire() async throws -> MCPHandshakePayload {
        if let trusted = loadTrusted().payload {
            return trusted
        }
        let launchRequestedAt = Date()
        try await launchHostApp(logger)
        return try await pollForTrustedHandshake(launchRequestedAt: launchRequestedAt)
    }

    // The user may have quit TablePro, so this only waits out the window for one that comes back.
    public func acquireWithoutLaunching() async throws -> MCPHandshakePayload {
        if let trusted = loadTrusted().payload {
            return trusted
        }
        return try await pollForTrustedHandshake(launchRequestedAt: nil)
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

    // A forged refusal can only make the bridge give up, so it is read without the handshake's
    // ownership checks.
    private func refusalAnswers(launchRequestedAt: Date) -> Bool {
        guard let data = try? Data(contentsOf: refusalUrl),
              let refusal = try? MCPHandshakeCoding.decoder().decode(MCPStartRefusal.self, from: data) else {
            return false
        }
        return refusal.answers(launchRequestedAt: launchRequestedAt)
    }

    // The copy this helper ships in, not whichever copy owns `tablepro://`. Substitution stays on, so a
    // running copy elsewhere still answers instead of a second instance starting. The flag has to be in
    // the launch environment, read before NSApplicationMain, to keep the app out of the Dock.
    public static func openHostApp(logger: any MCPBridgeLogger) async throws {
        guard let url = URL(string: launchUrl) else {
            throw MCPHandshakeAcquisitionError.launchFailed("the start link is not a URL")
        }
        let configuration = launchConfiguration(environment: ProcessInfo.processInfo.environment)
        do {
            if let app = MCPHostApp.containingCurrentProcess() {
                logger.log(.info, "No trusted MCP handshake; launching \(app.path) via \(Self.launchUrl)")
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            } else {
                logger.log(.info, "No trusted MCP handshake and no enclosing app; launching TablePro via \(Self.launchUrl)")
                _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            }
        } catch {
            throw MCPHandshakeAcquisitionError.launchFailed(error.localizedDescription)
        }
    }

    static func launchConfiguration(environment: [String: String]) -> NSWorkspace.OpenConfiguration {
        var environment = environment
        environment[BackgroundLaunchFlag.variable] = BackgroundLaunchFlag.value
        return ProcessLauncher.openConfiguration(environment: environment, activates: false)
    }

    private func pollForTrustedHandshake(launchRequestedAt: Date?) async throws -> MCPHandshakePayload {
        let deadline = ContinuousClock().now.advanced(by: pollTimeout)
        var lastFailure = "no handshake file"
        while ContinuousClock().now < deadline {
            let attempt = loadTrusted()
            if let payload = attempt.payload {
                return payload
            }
            if let launchRequestedAt, refusalAnswers(launchRequestedAt: launchRequestedAt) {
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

public extension MCPHandshakePayload {
    func credentials() -> MCPUpstreamCredentials {
        MCPUpstreamCredentials(socketPath: socketPath, bearerToken: token)
    }
}

public enum MCPHostApp {
    // proc_pidpath, not Bundle.main: run through a link, Bundle.main is the link's folder.
    public static func containingCurrentProcess() -> URL? {
        MCPHandshakeTrust.executablePath(forPid: getpid()).flatMap(containing(executablePath:))
    }

    // Only Contents/MacOS: a tool somewhere else inside another app, such as xctest in Xcode, has no host app.
    public static func containing(executablePath: String) -> URL? {
        let macOS = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else {
            return nil
        }
        return app.standardizedFileURL
    }
}
