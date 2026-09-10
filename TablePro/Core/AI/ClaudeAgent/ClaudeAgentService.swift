//
//  ClaudeAgentService.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class ClaudeAgentService {
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

    private(set) var state: InstallState = .unknown
    private(set) var isRefreshing = false

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
            Self.logger.error("Claude Agent status check failed: \(error.localizedDescription, privacy: .public)")
            state = .notInstalled
        }
    }

    var statusDescription: String {
        switch state {
        case .unknown:
            return String(localized: "Checking for the Claude Code command line tool…")
        case .notInstalled:
            return String(localized: "Claude Code is not installed.")
        case .outdated(let version):
            return String(
                format: String(localized: "Claude Code %@ is too old. Version %@ or newer is required."),
                version,
                ClaudeAgentCLI.minimumVersion
            )
        case .signedOut:
            return String(localized: "Claude Code is installed but not signed in.")
        case .signedIn(let account, let plan):
            if let account, let plan {
                return String(format: String(localized: "Signed in as %@ on the %@ plan."), account, plan)
            }
            if let account {
                return String(format: String(localized: "Signed in as %@."), account)
            }
            return String(localized: "Signed in.")
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
