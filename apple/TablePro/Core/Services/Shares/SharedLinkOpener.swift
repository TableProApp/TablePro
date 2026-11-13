//
//  SharedLinkOpener.swift
//  TablePro
//

import AppKit
import Foundation
import SwiftUI

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

    struct Presentation {
        var askPassword: @MainActor (PasswordPrompt) async -> String?
        var openQuery: @MainActor (SharedQueryOpen) -> Void
        var tell: @MainActor (String) async -> Void
        var showProgress: @MainActor (_ cancel: @escaping @MainActor () -> Void) -> Void
        var hideProgress: @MainActor () -> Void
        // A launch that ends with nothing on screen leaves the person somewhere to go.
        var fallBack: @MainActor () -> Void
    }

    static let shared = SharedLinkOpener(service: { AccountServices.shared.shares }, presentation: .live)

    private let service: @MainActor () -> any ShareService
    private let presentation: Presentation
    private var openingTokens: Set<String> = []
    private var fetch: Task<Result<SharedQuery, ShareFailure>, Never>?

    init(service: @escaping @MainActor () -> any ShareService, presentation: Presentation) {
        self.service = service
        self.presentation = presentation
    }

    func open(token: String) async {
        guard ShareToken.isValid(token), !openingTokens.contains(token) else { return }
        openingTokens.insert(token)
        defer { openingTokens.remove(token) }

        let service = service()
        presentation.showProgress { [weak self] in self?.fetch?.cancel() }
        var password: String?
        while true {
            let attempt = password
            let task = Task { () async -> Result<SharedQuery, ShareFailure> in
                do throws(ShareFailure) {
                    return .success(try await service.fetchShared(token: token, password: attempt))
                } catch {
                    return .failure(error)
                }
            }
            fetch = task
            let result = await task.value
            fetch = nil
            switch result {
            case .success(let shared):
                presentation.hideProgress()
                guard let sql = shared.sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await finish(saying: String(localized: "This shared result hides its SQL, so there is nothing to open."))
                    return
                }
                let title = shared.title.trimmingCharacters(in: .whitespacesAndNewlines)
                presentation.openQuery(SharedQueryOpen(sql: sql, title: title.isEmpty ? nil : title))
                return
            case .failure(.passwordRequired):
                guard let entered = await presentation.askPassword(.required) else { return finishCancelled() }
                password = entered
            case .failure(.passwordWrong):
                guard let entered = await presentation.askPassword(.wrong) else { return finishCancelled() }
                password = entered
            case .failure(let failure):
                presentation.hideProgress()
                guard let message = Self.message(for: failure) else { return finishCancelled() }
                await finish(saying: message)
                return
            }
        }
    }

    private func finish(saying message: String) async {
        await presentation.tell(message)
        presentation.fallBack()
    }

    private func finishCancelled() {
        presentation.hideProgress()
        presentation.fallBack()
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
}

extension SharedLinkOpener.Presentation {
    @MainActor static var live: Self {
        let progress = SharedLinkProgressPresenter()
        return Self(
            askPassword: { prompt in await SharedLinkPrompts.password(prompt, over: progress.window) },
            openQuery: { query in
                guard !TabRouter.shared.openSharedQuery(query) else { return }
                WelcomeRouter.shared.enqueueSharedQuery(query)
            },
            tell: { message in await SharedLinkPrompts.tell(message) },
            showProgress: { cancel in progress.show(cancel: cancel) },
            hideProgress: { progress.hide() },
            fallBack: {
                guard !NSApp.windows.contains(where: { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }) else { return }
                WindowOpener.shared.openWelcome()
            }
        )
    }
}

@MainActor
private enum SharedLinkPrompts {
    static func password(_ prompt: SharedLinkOpener.PasswordPrompt, over window: NSWindow?) async -> String? {
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
        guard await AlertHelper.response(to: alert, in: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func tell(_ message: String) async {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await AlertHelper.response(to: alert, in: nil)
    }
}

// A small window while the link is read, so a link opened at launch never leaves the screen empty.
@MainActor
private final class SharedLinkProgressPresenter {
    private(set) var window: NSWindow?

    func show(cancel: @escaping @MainActor () -> Void) {
        guard window == nil else { return }
        let hosting = NSHostingController(rootView: SharedLinkProgressView(cancel: cancel))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow.titled(String(localized: "Opening Shared Link"), contentViewController: hosting)
        window.styleMask = [.titled]
        window.isRestorable = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct SharedLinkProgressView: View {
    let cancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Opening the shared link…")
            }
            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
