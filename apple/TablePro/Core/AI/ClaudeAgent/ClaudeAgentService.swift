//
//  ClaudeAgentService.swift
//  TablePro
//

import Combine
import Foundation
import os

@MainActor
final class ClaudeAgentService: ObservableObject {
    enum InstallState: Equatable {
        case unknown
        case notInstalled
        case outdated(version: String)
        case signedOut
        case signedIn(account: String?, plan: String?)

        var isUsable: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    static let shared = ClaudeAgentService()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ClaudeAgentService")

    @Published private(set) var state: InstallState = .unknown
    @Published private(set) var isRefreshing = false

    private var refreshTask: Task<Void, Never>?

    func refreshStatus() {
        refreshTask?.cancel()
        refreshTask = Task { await performRefresh() }
    }

    func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let cli = ClaudeAgentCLI()
        guard cli.isInstalled else {
            state = .notInstalled
            return
        }

        do {
            let version = try await cli.version()
            guard ClaudeAgentCLI.meetsMinimumVersion(version) else {
                state = .outdated(version: version ?? String(localized: "unknown"))
                return
            }
            let status = try await cli.authStatus()
            guard status.loggedIn else {
                state = .signedOut
                return
            }
            state = .signedIn(account: status.accountDescription, plan: status.planDescription)
        } catch {
            Self.logger.error("Claude Agent status check failed: \(error.publicLogShape, privacy: .public)")
            state = .notInstalled
        }
    }

    var remedyCommand: String? {
        switch state {
        case .notInstalled, .outdated:
            return ClaudeAgentCLI.installCommand
        case .signedOut:
            return "claude /login"
        case .unknown, .signedIn:
            return nil
        }
    }
}
