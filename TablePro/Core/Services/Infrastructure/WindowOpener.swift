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
    @ObservationIgnored private var openConnectionFormAction: ((ConnectionFormRequest) -> Void)?
    @ObservationIgnored private var openIntegrationsActivityAction: (() -> Void)?
    @ObservationIgnored private var openSettingsAction: (() -> Void)?
    @ObservationIgnored private var stagedDraftId: UUID?
    @ObservationIgnored private var pendingCalls: [() -> Void] = []
    @ObservationIgnored private var isWired = false

    private init() {}

    internal func openWelcome() {
        run {
            $0.openWelcomeAction?()
            NSApp.activate()
        }
    }

    internal func openSettings(tab: SettingsPane? = nil) {
        if let tab {
            UserDefaults.standard.set(tab.rawValue, forKey: PreferenceKeys.selectedSettingsPane.name)
        }
        run { $0.openSettingsAction?() }
    }

    internal func closeWelcome() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.close()
        }
    }

    internal func openConnectionForm(editing connectionId: UUID) {
        run { $0.openConnectionFormAction?(.edit(connectionId: connectionId)) }
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
        run { $0.openConnectionFormAction?(.create(draftId: draftId)) }
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
        run { $0.openIntegrationsActivityAction?() }
    }

    internal func wire(
        openWelcome: @escaping () -> Void,
        openConnectionForm: @escaping (ConnectionFormRequest) -> Void,
        openIntegrationsActivity: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        openWelcomeAction = openWelcome
        openConnectionFormAction = openConnectionForm
        openIntegrationsActivityAction = openIntegrationsActivity
        openSettingsAction = openSettings
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
