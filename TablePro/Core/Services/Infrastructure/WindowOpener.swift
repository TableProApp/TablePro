//
//  WindowOpener.swift
//  TablePro
//

import AppKit
import Observation
import os

@MainActor
@Observable
internal final class WindowOpener {
    internal static let shared = WindowOpener()

    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowOpener")

    @ObservationIgnored private var openWelcomeAction: (() -> Void)?
    @ObservationIgnored private var openConnectionFormAction: ((UUID?) -> Void)?
    @ObservationIgnored private var openIntegrationsActivityAction: (() -> Void)?

    private init() {}

    internal func openWelcome() {
        invoke(openWelcomeAction, label: "openWelcome") { [weak self] in
            self?.openWelcomeAction
        }
    }

    internal func orderOutWelcome() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.orderOut(nil)
        }
    }

    internal func closeWelcome() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.close()
        }
    }

    internal func openConnectionForm(editing connectionId: UUID? = nil) {
        if let action = openConnectionFormAction {
            action(connectionId)
            return
        }
        Self.logger.notice("openConnectionForm called before bridge wired; retrying on next runloop tick")
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.openConnectionFormAction?(connectionId)
        }
    }

    internal func openIntegrationsActivity() {
        invoke(openIntegrationsActivityAction, label: "openIntegrationsActivity") { [weak self] in
            self?.openIntegrationsActivityAction
        }
    }

    internal func wire(
        openWelcome: @escaping () -> Void,
        openConnectionForm: @escaping (UUID?) -> Void,
        openIntegrationsActivity: @escaping () -> Void
    ) {
        openWelcomeAction = openWelcome
        openConnectionFormAction = openConnectionForm
        openIntegrationsActivityAction = openIntegrationsActivity
    }

    private func invoke(
        _ action: (() -> Void)?,
        label: StaticString,
        retry: @escaping () -> (() -> Void)?
    ) {
        if let action {
            action()
            return
        }
        Self.logger.notice("\(label, privacy: .public) called before bridge wired; retrying on next runloop tick")
        Task { @MainActor in
            await Task.yield()
            retry()?()
        }
    }
}
