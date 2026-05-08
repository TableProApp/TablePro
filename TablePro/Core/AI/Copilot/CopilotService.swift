//
//  CopilotService.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class CopilotService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotService")
    static let shared = CopilotService()

    enum Status: Sendable, Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    enum AuthState: Sendable, Equatable {
        case signedOut
        case signingIn(userCode: String, verificationURI: String)
        case signedIn(username: String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    private(set) var status: Status = .stopped
    private(set) var authState: AuthState = .signedOut
    private(set) var statusMessage: String?

    @ObservationIgnored private var lspClient: LSPClient?
    @ObservationIgnored private var transport: LSPTransport?
    @ObservationIgnored private var serverGeneration: Int = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempt: Int = 0
    @ObservationIgnored private let authManager = CopilotAuthManager()
    @ObservationIgnored private lazy var unauthenticatedStop = CopilotIdleStopController(
        timeout: Self.unauthenticatedTimeout,
        isAuthenticated: { [weak self] in self?.isAuthenticated ?? true },
        isRunning: { [weak self] in self?.status == .running },
        onStopRequest: { [weak self] in
            Self.logger.info("Copilot LSP idle without sign-in, stopping")
            await self?.stop()
        }
    )

    /// Stops the LSP server if the user hasn't signed in within this window after start.
    /// Avoids leaving a Node process idle for users who add a Copilot config but never authorise.
    private static let unauthenticatedTimeout: Duration = .seconds(5 * 60)

    private init() {}

    var client: LSPClient? { lspClient }
    var lspTransport: LSPTransport? { transport }
    var isAuthenticated: Bool { authState.isSignedIn }
    var generation: Int { serverGeneration }

    // MARK: - Lifecycle

    func start() async {
        guard status != .starting, status != .running else { return }
        serverGeneration += 1
        let generation = serverGeneration
        status = .starting

        do {
            let binaryPath = try await CopilotBinaryManager.shared.ensureBinary()

            let newTransport = LSPTransport()
            try await newTransport.start(executablePath: binaryPath, arguments: ["--stdio"], environment: [:])

            let client = LSPClient(transport: newTransport)
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            _ = try await client.initialize(
                clientInfo: LSPClientInfo(name: "TablePro", version: appVersion),
                editorPluginInfo: LSPClientInfo(name: "tablepro-copilot", version: "1.0.0"),
                processId: Int(ProcessInfo.processInfo.processIdentifier)
            )
            await client.initialized()

            let copilotConfig = AppSettingsManager.shared.ai.providers.first(where: { $0.type == .copilot })
            let telemetryLevel: String = (copilotConfig?.telemetryEnabled ?? false) ? "all" : "off"
            await client.didChangeConfiguration(settings: [
                "telemetry": AnyCodable(["telemetryLevel": telemetryLevel])
            ])

            guard generation == serverGeneration else { return }

            // Register notification handlers
            await client.onNotification(method: "didChangeStatus") { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleStatusNotification(data)
                }
            }

            self.transport = newTransport
            self.lspClient = client
            status = .running
            restartAttempt = 0

            Self.logger.info("Copilot language server started successfully")

            await checkAuthStatus()
            scheduleUnauthenticatedStopIfNeeded()
        } catch {
            guard generation == serverGeneration else { return }
            status = .error(error.localizedDescription)
            Self.logger.error("Failed to start Copilot: \(error.localizedDescription)")

            let isPermanent = error is CopilotError
            if !isPermanent {
                scheduleRestart()
            }
        }
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        unauthenticatedStop.cancel()
        serverGeneration += 1

        if let client = lspClient {
            let shutdownCompleted = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                group.addTask { (try? await client.shutdown()) != nil }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !shutdownCompleted {
                Self.logger.warning("Copilot shutdown RPC timed out, forcing exit")
            }
            await client.exit()
        }
        await transport?.stop()

        lspClient = nil
        transport = nil
        status = .stopped
        Self.logger.info("Copilot language server stopped")
    }

    // MARK: - Authentication

    func signIn() async throws {
        if status == .stopped {
            await start()
        }
        guard let transport else {
            throw CopilotError.serverNotRunning
        }
        let result = try await authManager.initiateSignIn(transport: transport)
        authState = .signingIn(userCode: result.userCode, verificationURI: result.verificationURI)
    }

    func completeSignIn() async throws {
        guard let transport else {
            throw CopilotError.serverNotRunning
        }
        let username = try await authManager.completeSignIn(transport: transport)
        authState = .signedIn(username: username)
        unauthenticatedStop.cancel()
    }

    func signOut() async {
        guard let transport else { return }
        await authManager.signOut(transport: transport)
        authState = .signedOut
        scheduleUnauthenticatedStopIfNeeded()
    }

    // MARK: - Private

    private func scheduleRestart() {
        restartAttempt += 1
        let delay = min(Double(1 << min(restartAttempt, 6)), 60.0)
        Self.logger.info("Scheduling Copilot restart in \(delay)s (attempt \(self.restartAttempt))")

        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.start()
        }
    }

    private struct CheckStatusResponse: Decodable {
        let status: String
        let user: String?
    }

    private func checkAuthStatus() async {
        guard let transport else { return }
        do {
            let data: Data = try await transport.sendRequest(
                method: "checkStatus",
                params: EmptyLSPParams()
            )
            let response = try JSONDecoder().decode(CheckStatusResponse.self, from: data)
            if response.status == "OK" || response.status == "AlreadySignedIn" {
                authState = .signedIn(username: response.user ?? "")
                Self.logger.info("Copilot already authenticated as \(response.user ?? "")")
            }
        } catch {
            Self.logger.debug("Auth status check failed: \(error.localizedDescription)")
        }
    }

    private func scheduleUnauthenticatedStopIfNeeded() {
        unauthenticatedStop.schedule()
    }

    private func handleStatusNotification(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = json["params"] as? [String: Any] else { return }

        let kind = params["kind"] as? String ?? "Normal"
        let message = params["message"] as? String

        switch kind {
        case "Error":
            statusMessage = message
            if let message, message.lowercased().contains("sign") || message.lowercased().contains("expired") {
                authState = .signedOut
                scheduleUnauthenticatedStopIfNeeded()
            }
        case "Warning":
            statusMessage = message
            Self.logger.warning("Copilot warning: \(message ?? "")")
        case "Inactive":
            statusMessage = String(localized: "Copilot subscription inactive")
        default:
            statusMessage = nil
        }
    }
}

enum CopilotError: Error, LocalizedError {
    case serverNotRunning
    case authenticationFailed(String)
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return String(localized: "Copilot server is not running")
        case .authenticationFailed(let detail):
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .binaryNotFound:
            return String(localized: "Copilot language server binary not found")
        }
    }
}
