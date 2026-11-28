import AppKit
import Combine
import os

internal enum SettingsRequest: Equatable, Sendable {
    // nil opens the last-used pane.
    case open(SettingsLocation?)
    // A nil id asks for the first plugin that needs an update.
    case revealPlugin(String?)
}

@MainActor
internal final class WindowOpener: ObservableObject {
    internal static let shared = WindowOpener()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WindowOpener")

    private var openWelcomeAction: (() -> Void)?
    private var openConnectionFormAction: ((ConnectionFormRequest, ConnectionEditorFacetChoice?) -> Void)?
    private var openIntegrationsActivityAction: (() -> Void)?
    private var openSettingsAction: ((SettingsRequest) -> Void)?
    private var stagedDraftId: UUID?
    private var pendingCalls: [() -> Void] = []

    // Not private so a test can exercise the queue on an instance with no presenters registered.
    internal init() {}

    internal func openWelcome() {
        perform { opener in
            guard let present = opener.openWelcomeAction else { return false }
            present()
            AppActivationPolicyController.shared.activate()
            return true
        }
    }

    internal func openSettings(_ location: SettingsLocation? = nil) {
        requestSettings(.open(location))
    }

    internal func openSettings(tab pane: SettingsPane?) {
        openSettings(pane.map { SettingsLocation.root($0) })
    }

    internal func openSettings(revealingPlugin pluginId: String?) {
        requestSettings(.revealPlugin(pluginId))
    }

    private func requestSettings(_ request: SettingsRequest) {
        perform { opener in
            guard let present = opener.openSettingsAction else { return false }
            present(request)
            return true
        }
    }

    internal func closeWelcome() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.close()
        }
    }

    internal func openConnectionForm(editing connectionId: UUID, facet: ConnectionEditorFacetChoice? = nil) {
        perform { opener in
            guard let present = opener.openConnectionFormAction else { return false }
            present(.edit(connectionId: connectionId), facet)
            return true
        }
    }

    internal func openTeamConnectionForm(teamID: String, itemID: String) {
        perform { opener in
            guard let present = opener.openConnectionFormAction else { return false }
            present(.editTeamCopy(teamID: teamID, itemID: itemID), nil)
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
            present(.create(draftId: draftId), nil)
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

    internal func setWelcomePresenter(_ present: @escaping () -> Void) {
        openWelcomeAction = present
        drainPendingCalls()
    }

    internal func setConnectionFormPresenter(_ present: @escaping (ConnectionFormRequest, ConnectionEditorFacetChoice?) -> Void) {
        openConnectionFormAction = present
        drainPendingCalls()
    }

    internal func setIntegrationsActivityPresenter(_ present: @escaping () -> Void) {
        openIntegrationsActivityAction = present
        drainPendingCalls()
    }

    internal func setSettingsPresenter(_ present: @escaping (SettingsRequest) -> Void) {
        openSettingsAction = present
        drainPendingCalls()
    }

    // A block returns false while its window has no presenter yet, which queues the call.
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
