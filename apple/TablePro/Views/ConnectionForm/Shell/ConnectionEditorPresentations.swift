//
//  ConnectionEditorPresentations.swift
//  TablePro
//

import SwiftUI

// Every sheet and alert the editor raises on its window, each bound to the store state that asks for it.
struct ConnectionEditorPresentations: ViewModifier {
    @ObservedObject var store: ConnectionEditorStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isChoosingType) {
                DatabaseTypeChooserSheet(
                    purpose: .changeType,
                    initialType: store.draft.type,
                    onSelected: { choose($0) },
                    onCancel: { store.isChoosingType = false }
                )
            }
            .sheet(item: $store.sshProfileSheet) { sheet in
                sshProfileEditor(sheet)
            }
            .sheet(isPresented: $store.isSavingCredentialsAsProfile) {
                CredentialProfileEditorSheet(
                    existingProfile: store.credentialProfileFromCurrentCredentials(),
                    initialPassword: store.draft.credentials.password,
                    initialDatabaseType: store.draft.type,
                    onSave: { store.didSaveCredentialProfile($0) }
                )
            }
            .sheet(item: $store.pluginDiagnostic) { item in
                PluginDiagnosticSheet(item: item) {
                    store.pluginDiagnostic = nil
                }
            }
            .pluginInstallPrompt(for: $store.pluginInstallConnection, type: \.type) { _ in
                store.test()
            }
            .alert(
                retypeTitle,
                isPresented: Binding(
                    // The buttons answer it; SwiftUI may clear the binding before it runs a button's action.
                    get: { store.pendingRetype != nil },
                    set: { _ in }
                ),
                presenting: store.pendingRetype
            ) { _ in
                Button(String(localized: "Change Type")) {
                    store.confirmPendingRetype()
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    store.cancelPendingRetype()
                }
            } message: { proposal in
                Text(proposal.dropped.formatted(.list(type: .and)))
            }
            .alert(
                String(localized: "Save Failed"),
                isPresented: Binding(
                    get: { Self.alertsSaveError(store.saveError) },
                    set: { if !$0 { store.saveError = nil } }
                ),
                presenting: store.saveError
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) {
                    store.saveError = nil
                }
            } message: { error in
                Text(error.errorDescription ?? "")
            }
            .alert(
                String(localized: "Delete Failed"),
                isPresented: Binding(
                    get: { store.deleteError != nil },
                    set: { if !$0 { store.deleteError = nil } }
                ),
                presenting: store.deleteError
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) {
                    store.deleteError = nil
                }
            } message: { error in
                Text(error.errorDescription ?? "")
            }
    }

    // An invalid field already has its place: Save focuses it and the commit bar names it.
    static func alertsSaveError(_ error: ConnectionEditorSaveError?) -> Bool {
        guard let error else { return false }
        switch error {
        case .invalid: return false
        case .libraryUnreadable, .recordMissing, .keychainWriteFailed, .recordWriteFailed: return true
        }
    }

    private var retypeTitle: String {
        guard let proposal = store.pendingRetype else { return "" }
        return String(format: String(localized: "Changing to %@ removes:"), proposal.to.displayName)
    }

    // The same install question Welcome asks after its chooser, then the retype, which confirms what it drops.
    private func choose(_ type: DatabaseType) {
        store.isChoosingType = false
        Task { @MainActor in
            guard await DatabaseTypeInstallCheck.ensureInstalled(type, window: store.window) else { return }
            store.requestRetype(to: type)
        }
    }

    @ViewBuilder
    private func sshProfileEditor(_ sheet: ConnectionEditorStore.SSHProfileSheet) -> some View {
        switch sheet {
        case .create:
            SSHProfileEditorView(existingProfile: nil, onSave: { store.didSaveSSHProfile($0) })
        case .edit(let profile):
            SSHProfileEditorView(
                existingProfile: profile,
                onSave: { store.didSaveSSHProfile($0) },
                onDelete: { store.didDeleteSSHProfile() }
            )
        case .saveCurrent(let profile):
            SSHProfileEditorView(
                existingProfile: profile,
                initialPassword: store.draft.ssh.password,
                initialKeyPassphrase: store.draft.ssh.keyPassphrase,
                initialTOTPSecret: store.draft.ssh.totpSecret,
                onSave: { store.didSaveSSHProfile($0) }
            )
        }
    }
}
