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
    @ObservationIgnored private var pendingCalls: [() -> Void] = []
    @ObservationIgnored private var isWired = false

    private init() {}

    internal func openWelcome() {
        run { $0.openWelcomeAction?() }
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
        run { $0.openConnectionFormAction?(connectionId) }
    }

    internal func openIntegrationsActivity() {
        run { $0.openIntegrationsActivityAction?() }
    }

    internal func wire(
        openWelcome: @escaping () -> Void,
        openConnectionForm: @escaping (UUID?) -> Void,
        openIntegrationsActivity: @escaping () -> Void
    ) {
        openWelcomeAction = openWelcome
        openConnectionFormAction = openConnectionForm
        openIntegrationsActivityAction = openIntegrationsActivity
        isWired = true
        let drained = pendingCalls
        pendingCalls.removeAll()
        for call in drained {
            call()
        }
    }

    private func run(_ block: @escaping (WindowOpener) -> Void) {
        if isWired {
            block(self)
            return
        }
        Self.logger.notice("WindowOpener call queued; bridge not yet wired")
        pendingCalls.append { [weak self] in
            guard let self else { return }
            block(self)
        }
    }
}
