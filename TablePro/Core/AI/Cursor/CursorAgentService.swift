//
//  CursorAgentService.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class CursorAgentService {
    static let shared = CursorAgentService()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CursorAgentService")

    enum AuthState: Sendable, Equatable {
        case notInstalled
        case signedOut
        case signingIn
        case signedIn(account: String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    private(set) var authState: AuthState = .signedOut
    private(set) var errorMessage: String?

    @ObservationIgnored private let cli: CursorAgentCLI
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    init(cli: CursorAgentCLI = CursorAgentCLI()) {
        self.cli = cli
    }

    func refreshStatus() async {
        guard cli.isInstalled else {
            authState = .notInstalled
            return
        }
        do {
            let result = try await cli.run(["status"])
            authState = result.code == 0
                ? .signedIn(account: Self.parseAccount(result.output))
                : .signedOut
        } catch {
            authState = cli.isInstalled ? .signedOut : .notInstalled
        }
    }

    func signIn() {
        guard cli.isInstalled else {
            authState = .notInstalled
            return
        }
        guard signInTask == nil else { return }
        errorMessage = nil
        authState = .signingIn
        signInTask = Task {
            do {
                let result = try await cli.run(["login"])
                if !Task.isCancelled, result.code != 0 {
                    errorMessage = result.output.isEmpty
                        ? String(localized: "Cursor sign-in failed.")
                        : result.output
                }
            } catch {
                Self.logger.error("Cursor CLI sign-in failed: \(error.localizedDescription, privacy: .public)")
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            signInTask = nil
            await refreshStatus()
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
    }

    func signOut() async {
        _ = try? await cli.run(["logout"])
        errorMessage = nil
        await refreshStatus()
    }

    private static func parseAccount(_ output: String) -> String {
        let tokens = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        for token in tokens where token.contains("@") && token.contains(".") {
            return String(token.trimmingCharacters(in: CharacterSet(charactersIn: "<>(),")))
        }
        return ""
    }
}
