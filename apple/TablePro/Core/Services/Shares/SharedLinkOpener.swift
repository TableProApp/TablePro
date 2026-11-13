//
//  SharedLinkOpener.swift
//  TablePro
//

import AppKit
import Foundation

internal struct SharedQueryOpen: Equatable, Sendable {
    let sql: String
    let title: String?
}

// A shared link only ever fills a new query tab: it never runs the SQL and carries no connection details.
@MainActor
internal final class SharedLinkOpener {
    enum PasswordPrompt: Equatable {
        case required
        case wrong
    }

    static let shared = SharedLinkOpener(
        service: { AccountServices.shared.shares },
        askPassword: SharedLinkOpener.presentPasswordPrompt,
        openQuery: SharedLinkOpener.openInQueryTab,
        tell: SharedLinkOpener.presentMessage
    )

    private let service: @MainActor () -> any ShareService
    private let askPassword: @MainActor (PasswordPrompt) async -> String?
    private let openQuery: @MainActor (SharedQueryOpen) -> Void
    private let tell: @MainActor (String) -> Void
    private var openingTokens: Set<String> = []

    init(
        service: @escaping @MainActor () -> any ShareService,
        askPassword: @escaping @MainActor (PasswordPrompt) async -> String?,
        openQuery: @escaping @MainActor (SharedQueryOpen) -> Void,
        tell: @escaping @MainActor (String) -> Void
    ) {
        self.service = service
        self.askPassword = askPassword
        self.openQuery = openQuery
        self.tell = tell
    }

    func open(token: String) async {
        guard ShareToken.isValid(token), !openingTokens.contains(token) else { return }
        openingTokens.insert(token)
        defer { openingTokens.remove(token) }

        let service = service()
        var password: String?
        while true {
            do throws(ShareFailure) {
                let shared = try await service.fetchShared(token: token, password: password)
                guard let sql = shared.sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    tell(String(localized: "This shared result hides its SQL, so there is nothing to open."))
                    return
                }
                let title = shared.title.trimmingCharacters(in: .whitespacesAndNewlines)
                openQuery(SharedQueryOpen(sql: sql, title: title.isEmpty ? nil : title))
                return
            } catch .passwordRequired {
                guard let entered = await askPassword(.required) else { return }
                password = entered
            } catch .passwordWrong {
                guard let entered = await askPassword(.wrong) else { return }
                password = entered
            } catch {
                if let message = Self.message(for: error) {
                    tell(message)
                }
                return
            }
        }
    }

    static func message(for failure: ShareFailure) -> String? {
        switch failure {
        case .canceled:
            return nil
        case .notFound, .revoked, .removed:
            return String(localized: "This shared link is no longer available.")
        case .offline:
            return String(localized: "You appear to be offline. Try again once you're connected.")
        case .rateLimited:
            return String(localized: "Too many attempts. Try again in a moment.")
        case .signedOut, .emailUnverified, .proRequired, .sharingDisabled, .teamSharingDisabled, .seatRequired,
             .limitReached, .snapshotTooLarge, .invalid, .passwordRequired, .passwordWrong, .server:
            return String(localized: "The shared link couldn't be opened. Try again.")
        }
    }

    // MARK: - Live presentation

    private static func presentPasswordPrompt(_ prompt: PasswordPrompt) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt == .required
            ? String(localized: "This link is password protected.")
            : String(localized: "That password is not correct.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Open"))
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        guard await AlertHelper.response(to: alert, in: nil) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func openInQueryTab(_ query: SharedQueryOpen) {
        guard !TabRouter.shared.openSharedQuery(query) else { return }
        WelcomeRouter.shared.enqueueSharedQuery(query)
    }

    private static func presentMessage(_ message: String) {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        AlertHelper.present(alert, in: nil)
    }
}
