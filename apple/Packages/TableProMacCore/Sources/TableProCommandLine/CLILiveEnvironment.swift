import AppKit
import Darwin
import Foundation
import TableProMCP
import TableProProcess

public extension CLIEnvironment {
    static func live(console: any CLIConsole) -> CLIEnvironment {
        let app = CLIHostApp.current
        return CLIEnvironment(
            console: console,
            terminal: .current,
            tokenStore: CLITokenStores.current(),
            app: app,
            openServer: { try await CLILive.openServer() },
            findServer: { await CLILive.findServer(app: app) },
            pair: { server in try await CLILive.pair(server: server, app: app) },
            openTargets: { targets in try await CLILive.open(targets, app: app) },
            readStandardInput: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CLIFailure.usage("Standard input is not UTF-8 text.")
                }
                return text
            },
            readFile: { path in try String(contentsOfFile: path, encoding: .utf8) },
            fileExists: { path in FileManager.default.fileExists(atPath: path) },
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
    }
}

enum CLILive {
    static let pairingTimeout: Duration = .seconds(330)

    // The server must prove it wrote the handshake before any token goes to its socket.
    static func openServer() async throws -> CLIServerEndpoint {
        let logger = MCPOSBridgeLogger(category: "CLI")
        let handshake: MCPHandshakePayload
        do {
            handshake = try await MCPHandshakeAcquirer(logger: logger).acquire()
        } catch MCPHandshakeAcquisitionError.serverTurnedOff {
            throw CLIFailure(
                .refused,
                "TablePro's MCP server is turned off, and the tablepro command reaches TablePro through it. Turn it on under Settings > MCP."
            )
        } catch {
            throw CLIFailure(.failure, "TablePro did not start its MCP server: \(error.localizedDescription)")
        }
        do {
            return try await verified(handshake, logger: logger)
        } catch MCPSocketHttpError.peerChanged {
            throw CLIFailure.peerChanged
        }
    }

    // One read of the handshake, no launch and no polling: status must answer at once.
    static func findServer(app: CLIHostApp) async -> CLIServerProbe {
        let logger = MCPOSBridgeLogger(category: "CLI")
        let file = MCPHandshakeLocation.file(in: MCPHandshakeLocation.supportDirectory())
        guard let handshake = try? MCPHandshakeTrust.load(at: file) else {
            return isRunning(app) ? .turnedOff : .notRunning
        }
        return await probe(handshake, logger: logger)
    }

    static func probe(_ handshake: MCPHandshakePayload, logger: any MCPBridgeLogger) async -> CLIServerProbe {
        do {
            return .reachable(try await verified(handshake, logger: logger))
        } catch MCPSocketHttpError.peerChanged {
            return .peerChanged
        } catch let failure as CLIFailure {
            return .unreachable(failure.message)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func pair(server: CLIServerEndpoint, app: CLIHostApp) async throws -> String {
        let request = CLIPairingRequest.random()
        let listener = CLICallbackListener(state: request.state)
        defer { listener.stop() }

        let callbackPort: UInt16
        do {
            callbackPort = try await listener.start()
        } catch {
            throw CLIFailure(.failure, "Could not listen for the pairing answer: \(error.localizedDescription)")
        }
        guard let link = request.link(callbackPort: callbackPort) else {
            throw CLIFailure(.failure, "Could not build the pairing link.")
        }
        // The one-time code is only good on the instance serving MCP.
        let target = server.appPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? app.url
        do {
            try await openInApp([link], app: target)
        } catch {
            throw CLIFailure(.failure, "Could not open TablePro to pair: \(error.localizedDescription)")
        }

        switch await listener.waitForCallback(timeout: pairingTimeout) {
        case .approved(let code):
            return try await CLIServerClient.exchange(code: code, verifier: request.verifier, socketPath: server.socketPath, serverPID: server.serverPID)
        case .denied:
            throw CLIFailure(.refused, "Pairing was declined in TablePro.")
        case .ignored, nil:
            throw CLIFailure(.refused, "Pairing was not approved in time.")
        }
    }

    static func open(_ targets: [URL], app: CLIHostApp) async throws {
        guard let appURL = app.url else {
            throw CLIFailure(.failure, "This command runs only from inside TablePro.app, so it cannot tell which TablePro to open.")
        }
        do {
            try await openInApp(targets, app: appURL)
        } catch {
            throw CLIFailure(.failure, "Could not open TablePro: \(error.localizedDescription)")
        }
    }

    // The copy this command ships in, not the one LaunchServices picks for a scheme or a bundle id.
    // Substitution stays on, so a copy already running elsewhere answers instead of a second instance.
    private static func openInApp(_ urls: [URL], app: URL?) async throws {
        let configuration = launchConfiguration(environment: ProcessInfo.processInfo.environment)
        guard let app else {
            for url in urls {
                _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            }
            return
        }
        if urls.isEmpty {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
        }
    }

    static func launchConfiguration(environment: [String: String]) -> NSWorkspace.OpenConfiguration {
        ProcessLauncher.openConfiguration(environment: environment)
    }

    private static func verified(_ handshake: MCPHandshakePayload, logger: any MCPBridgeLogger) async throws -> CLIServerEndpoint {
        do {
            _ = try await BridgeUpstreamHandshake.verifiedDiscovery(
                handshake: handshake,
                credentials: handshake.credentials(),
                logger: logger
            )
        } catch MCPSocketHttpError.peerChanged {
            throw MCPSocketHttpError.peerChanged
        } catch {
            throw CLIFailure(.failure, "The local MCP server did not prove it is TablePro: \(error.localizedDescription)")
        }
        let appPath = MCPHandshakeTrust.executablePath(forPid: handshake.pid)
            .flatMap(MCPHandshakeTrust.appBundleRoot(forExecutable:))
        return CLIServerEndpoint(socketPath: handshake.socketPath, serverPID: handshake.pid, appPath: appPath)
    }

    private static func isRunning(_ app: CLIHostApp) -> Bool {
        guard let identifier = app.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }
}

public final class CLIStandardConsole: CLIConsole, @unchecked Sendable {
    private static let flushThreshold = 64 * 1_024

    private let lock = NSLock()
    private var pending = Data()
    private var firstFailure: Error?

    public init() {}

    public var outputFailure: Error? {
        lock.withLock { firstFailure }
    }

    public func out(_ text: String) {
        let ready: Data? = lock.withLock {
            pending.append(contentsOf: text.utf8)
            guard pending.count >= Self.flushThreshold else { return nil }
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        if let ready {
            writeOutput(ready)
        }
    }

    public func err(_ text: String) {
        flush()
        try? DescriptorWrite.allBytes(Data(text.utf8), to: STDERR_FILENO)
    }

    public func flush() {
        let ready: Data = lock.withLock {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        guard !ready.isEmpty else { return }
        writeOutput(ready)
    }

    private func writeOutput(_ data: Data) {
        do {
            try DescriptorWrite.allBytes(data, to: STDOUT_FILENO)
        } catch {
            lock.withLock {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }
    }
}
