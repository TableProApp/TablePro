//
//  CloudflareTunnelPaneViewModel.swift
//  TablePro
//

import Foundation
import os

@Observable
@MainActor
final class CloudflareTunnelPaneViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareTunnelPane")

    var state = CloudflareTunnelFormState()

    var coordinator: WeakCoordinatorRef?

    var resolvedBinaryPath: String?
    var didResolveBinary: Bool = false
    var signInError: String?

    @ObservationIgnored private var loginProcess: Process?

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        var issues: [String] = []

        if state.accessHostname.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "Cloudflare hostname is required"))
        }

        if !state.automaticPort {
            let portIsValid = Int(state.localPort).map { (1...65_535).contains($0) } ?? false
            if !portIsValid {
                issues.append(String(localized: "Local port must be between 1 and 65535"))
            }
        }

        if state.authMethod == .serviceToken {
            if state.serviceTokenId.trimmingCharacters(in: .whitespaces).isEmpty
                || state.serviceTokenSecret.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(localized: "Service token ID and secret are required"))
            }
        }

        if coordinator?.value?.ssh.state.enabled == true {
            issues.append(String(localized: "Cannot use SSH Tunnel and Cloudflare Tunnel at the same time"))
        }

        return issues
    }

    func load(from connection: DatabaseConnection, storage: ConnectionStorage) {
        state.load(from: connection)
        state.serviceTokenId = storage.loadCloudflareTokenId(for: connection.id) ?? ""
        state.serviceTokenSecret = storage.loadCloudflareTokenSecret(for: connection.id) ?? ""
        resolveBinary()
    }

    func save(to connectionId: UUID, storage: ConnectionStorage) {
        guard state.enabled, state.authMethod == .serviceToken else {
            storage.deleteCloudflareTokenId(for: connectionId)
            storage.deleteCloudflareTokenSecret(for: connectionId)
            return
        }
        storage.saveCloudflareTokenId(state.serviceTokenId, for: connectionId)
        storage.saveCloudflareTokenSecret(state.serviceTokenSecret, for: connectionId)
    }

    func resolveBinary() {
        Task {
            let path = await Task.detached { CLIExecutableFinder.findExecutable("cloudflared") }.value
            resolvedBinaryPath = path
            didResolveBinary = true
        }
    }

    func signInWithBrowser() {
        signInError = nil
        guard loginProcess?.isRunning != true else { return }

        let hostname = state.accessHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return }

        let rawPath = state.binaryPath.isEmpty ? resolvedBinaryPath : state.binaryPath
        guard let resolvedPath = rawPath.map({ ($0 as NSString).expandingTildeInPath }),
              FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            signInError = String(localized: "cloudflared was not found. Set its path below first.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = ["access", "login", hostname]
        do {
            try process.run()
            loginProcess = process
            Self.logger.info("Started cloudflared access login for \(hostname, privacy: .public)")
        } catch {
            signInError = error.localizedDescription
            Self.logger.error("cloudflared access login failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
