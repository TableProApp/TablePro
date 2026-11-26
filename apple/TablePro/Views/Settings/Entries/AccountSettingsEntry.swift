import SwiftUI
import UniformTypeIdentifiers

internal struct AccountSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        AccountSettingsView(model: context.models.account) { [context] in
            context.navigation.push(.page(.accountDevices), in: .account)
        }
    }
}

internal struct AccountSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.accountFeatures):
            AccountFeaturesPage(access: context.models.account.access)
        case .page(.accountDevices):
            AccountDevicesPage(model: context.models.account)
        case .page(.accountTeams):
            AccountTeamsPage(model: context.models.account)
        case .page(.accountEncryption):
            AccountKeysPage(model: context.models.accountKeys)
        case .page(.accountOffline):
            AccountOfflinePage(model: context.models.account)
        default:
            EmptyView()
        }
    }
}

// The root and every page share the model's sheets, dialogs and file panel, so they hang off the pane's stack.
internal struct AccountStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content.modifier(AccountPresentations(model: context.models.account, visit: context.visit, context: context))
    }
}

private struct AccountPresentations: ViewModifier {
    private static let offlineFileTypes = [UTType(filenameExtension: "jwt") ?? .data]
    private static let signedInPages: [SettingsRoute] = [
        .page(.accountDevices), .page(.accountTeams), .page(.accountEncryption),
    ]

    @ObservedObject var model: AccountSettingsModel
    @ObservedObject var visit: SettingsPaneVisit
    let context: SettingsPaneContext

    func body(content: Content) -> some View {
        content
            .task(id: visit.count) {
                await model.refreshOnVisit()
            }
            .onChange(of: model.access.state.isSignedIn) { isSignedIn in
                guard !isSignedIn else { return }
                for route in Self.signedInPages where context.path.routes.contains(route) {
                    context.navigation.removeRoute(route)
                }
            }
            .sheet(isPresented: $model.presentsDeviceLimit) {
                DeviceLimitSheet(model: DeviceLimitModel(services: model.services))
            }
            .sheet(isPresented: $model.presentsLicenseKey) {
                LicenseKeySheet(
                    storedKey: model.licenseKeyPrefill,
                    signedInEmail: signedInEmail,
                    isWorking: model.activity == .usingKey
                ) { key in
                    await model.useLicenseKey(key)
                }
            }
            .fileImporter(
                isPresented: $model.presentsOfflineImporter,
                allowedContentTypes: Self.offlineFileTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task { await model.importOfflineFile(at: url) }
                    }
                case .failure(let error):
                    model.offlineFilePickerFailed(error)
                }
            }
            .alert(
                model.actionFailure?.title ?? "",
                isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } }),
                presenting: model.actionFailure
            ) { _ in
                Button(String(localized: "OK")) {}
            } message: { failure in
                Text(failure.message)
            }
            .alert(
                model.pendingRemoval.map { String(format: String(localized: "Remove “%@”?"), $0.name) } ?? "",
                isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                presenting: model.pendingRemoval
            ) { device in
                Button(String(localized: "Remove"), role: .destructive) {
                    Task { await model.removeDevice(device) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: { _ in
                Text("TablePro on that device signs out the next time it checks your account. Its paid features keep working until its last check expires.")
            }
    }

    private var signedInEmail: String? {
        guard model.access.state.isSignedIn else { return nil }
        return model.profile.value?.email ?? model.access.state.entitlement?.email
    }
}
