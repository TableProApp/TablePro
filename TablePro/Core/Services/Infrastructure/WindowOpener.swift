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

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WindowOpener")

    @ObservationIgnored private var openWelcomeAction: (() -> Void)?
    @ObservationIgnored private var openConnectionFormAction: ((ConnectionFormRequest) -> Void)?
    @ObservationIgnored private var openIntegrationsActivityAction: (() -> Void)?
    @ObservationIgnored private var openCompareSyncAction: ((UUID?) -> Void)?
    @ObservationIgnored private var openSettingsAction: ((SettingsPane?) -> Void)?
    @ObservationIgnored private var stagedDraftId: UUID?
    @ObservationIgnored private var pendingCalls: [() -> Void] = []

    /// Not private so a test can exercise the queue on an instance with no presenters
    /// registered. Production code uses `shared`.
    internal init() {}

    internal func openWelcome() {
        perform { opener in
            guard let present = opener.openWelcomeAction else { return false }
            present()
            AppActivationPolicyController.shared.activate()
            return true
        }
    }

    internal func openSettings(tab: SettingsPane? = nil) {
        perform { opener in
            guard let present = opener.openSettingsAction else { return false }
            present(tab)
            return true
        }
    }

    internal func closeWelcome() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.close()
        }
    }

    internal func openConnectionForm(editing connectionId: UUID) {
        perform { opener in
            guard let present = opener.openConnectionFormAction else { return false }
            present(.edit(connectionId: connectionId))
            return true
        }
    }

    internal func openConnectionForm() {
        presentTypeChooser(initialType: nil) { selected in
            WindowOpener.shared.stageConnectionFormDraft(type: selected)
        }
    }

    internal func stageConnectionFormDraft(type: DatabaseType? = nil, parsedURL: ParsedConnectionURL? = nil) {
        discardStagedDraft()
        stagedDraftId = ConnectionFormDraftStore.shared.stage(
            ConnectionFormDraft(type: type, parsedURL: parsedURL)
        )
    }

    internal func openStagedConnectionForm() {
        guard let draftId = stagedDraftId else { return }
        stagedDraftId = nil
        perform { opener in
            guard let present = opener.openConnectionFormAction else { return false }
            present(.create(draftId: draftId))
            return true
        }
    }

    private func discardStagedDraft() {
        guard let draftId = stagedDraftId else { return }
        stagedDraftId = nil
        _ = ConnectionFormDraftStore.shared.consume(draftId)
    }

    internal func presentTypeChooser(
        initialType: DatabaseType?,
        onSelected: @escaping (DatabaseType) -> Void
    ) {
        let payload = DatabaseTypeChooserPayload(initialType: initialType, onSelected: onSelected)
        WelcomeRouter.shared.route(.chooseDatabaseType(payload))
    }

    internal func openIntegrationsActivity() {
        perform { opener in
            guard let present = opener.openIntegrationsActivityAction else { return false }
            present()
            return true
        }
    }

    internal func openCompareSync(prefillSource connectionId: UUID? = nil) {
        perform { opener in
            guard let present = opener.openCompareSyncAction else { return false }
            present(connectionId)
            return true
        }
    }

    internal func setWelcomePresenter(_ present: @escaping () -> Void) {
        openWelcomeAction = present
        drainPendingCalls()
    }

    internal func setConnectionFormPresenter(_ present: @escaping (ConnectionFormRequest) -> Void) {
        openConnectionFormAction = present
        drainPendingCalls()
    }

    internal func setIntegrationsActivityPresenter(_ present: @escaping () -> Void) {
        openIntegrationsActivityAction = present
        drainPendingCalls()
    }

    internal func setSettingsPresenter(_ present: @escaping (SettingsPane?) -> Void) {
        openSettingsAction = present
        drainPendingCalls()
    }

    internal func setCompareSyncPresenter(_ present: @escaping (UUID?) -> Void) {
        openCompareSyncAction = present
        drainPendingCalls()
    }

    /// Returns false when the presenter for that window has not been registered yet, which
    /// queues the call. Each window registers independently, so one that has already migrated
    /// to AppKit never waits on one that has not.
    private func perform(_ block: @escaping (WindowOpener) -> Bool) {
        AppActivationPolicyController.shared.enterForeground()
        guard !block(self) else { return }
        Self.logger.notice("WindowOpener call queued; presenter not registered yet")
        pendingCalls.append { [weak self] in
            self?.perform(block)
        }
    }

    private func drainPendingCalls() {
        let drained = pendingCalls
        pendingCalls.removeAll()
        for call in drained {
            call()
        }
    }
}
