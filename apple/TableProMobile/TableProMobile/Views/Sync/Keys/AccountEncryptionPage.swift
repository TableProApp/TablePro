import SwiftUI
import TableProFFI

// Settings > TablePro Account > End-to-End Encryption. The model is made once the page is on screen, so the link that
// leads here builds nothing; its sheets hang off the page, and a sign-out that pops the page ends them with it.
struct AccountEncryptionPage: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var sceneDelegate: TableProSceneDelegate

    @State private var model: AccountKeysModel?

    var body: some View {
        Group {
            if let model {
                AccountEncryptionContent(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "End-to-End Encryption"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard model == nil else { return }
            model = AccountKeysModel(environment: appState.keysEnvironment { [sceneDelegate] in
                sceneDelegate.presentationWindow
            })
        }
    }
}

private struct AccountEncryptionContent: View {
    @Bindable var model: AccountKeysModel

    var body: some View {
        Form {
            content
            if Self.showsResets(model.state.value) {
                ResetKeysSection(model: model.resets, copySecret: model.environment.copySecret)
            }
        }
        .accessibilityIdentifier("account-encryption-page")
        .refreshable {
            await model.reload()
        }
        .task {
            await model.reload()
        }
        .task {
            await model.watchRequests()
        }
        .sheet(item: sheetBinding) { sheet in
            AccountKeysSheetContent(sheet: sheet, model: model)
        }
        .confirmationDialog(
            model.pendingRemoval.map {
                String(format: String(localized: "Remove “%@”?"), AccountKeysText.deviceName($0.name))
            } ?? "",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { device in
            Button(String(localized: "Remove"), role: .destructive) {
                Task { await model.remove(device) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("It's signed out and can't read anything new. First confirm it's you in your browser, then enter your recovery key so TablePro can change your keys.")
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
    }

    // A sheet the system closes reaches the model the same way as one its own buttons close.
    private var sheetBinding: Binding<AccountKeysModel.Sheet?> {
        Binding(
            get: { model.sheet },
            set: { sheet in
                if sheet == nil {
                    model.closeSheet()
                } else {
                    model.sheet = sheet
                }
            }
        )
    }

    // A reset needs keys on the account: kind 2 from an approved device, kind 3 from one waiting for approval or
    // locked, and every device shows a pending one (core ADR 0056, Reset).
    private static func showsResets(_ state: KeyStateInfo?) -> Bool {
        switch state {
        case .approved?, .needsApproval?, .locked?: true
        case .noKeys?, .noDeviceStore?, .unknown?, nil: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state.value {
        case nil:
            Section {
                if let failure = model.state.failure {
                    AccountKeysFailureText(message: failure)
                    Button(String(localized: "Try Again")) { Task { await model.reload() } }
                        .disabled(model.state.isLoading)
                } else {
                    AccountKeysLoadingRow(label: String(localized: "Checking your keys"))
                }
            }
        case .unknown?:
            Section {
                AccountKeysLoadingRow(label: String(localized: "Checking your keys"))
            }
        case .noDeviceStore?:
            Section {
                AccountKeysStatusRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: String(localized: "This device can't keep keys"),
                    message: String(localized: "Without a place to keep keys, TablePro Sync carries only team records without their secrets here.")
                )
            }
        case .noKeys?:
            Section {
                Button(String(localized: "Set Up End-to-End Encryption…")) {
                    model.setUpRecoveryKey()
                }
                .accessibilityIdentifier("account-keys-set-up")
            } footer: {
                Text("Your passwords, history and team secrets are sealed on this device before they sync. A recovery key you keep lets you add and remove devices.")
            }
        case .needsApproval(let request)?:
            Section {
                Button(request != nil ? String(localized: "Show Request…") : String(localized: "Ask Another Device…")) {
                    model.askForApproval()
                }
                .accessibilityIdentifier("account-keys-ask-approval")
            } header: {
                Text("Approve This Device")
            } footer: {
                Text("Your account already has keys. Approve this device from another one where you use TablePro.")
            }
            Section {
                Button(String(localized: "Use Recovery Key…")) {
                    model.useRecoveryKey()
                }
                .accessibilityIdentifier("account-keys-use-recovery-key")
            } footer: {
                Text("No other device at hand? Use your recovery key instead. Your other devices then ask this one for approval.")
            }
        case .locked(let cause)?:
            Section {
                AccountKeysStatusRow(
                    symbol: "lock.trianglebadge.exclamationmark.fill",
                    tint: .orange,
                    title: AccountKeysText.lockTitle(cause),
                    message: AccountKeysText.lockMessage(cause)
                )
                if AccountKeysText.canAskForApproval(cause) {
                    Button(String(localized: "Ask Another Device…")) {
                        model.askForApproval()
                    }
                    .accessibilityIdentifier("account-keys-ask-approval")
                }
                if AccountKeysText.canRecover(cause) {
                    Button(String(localized: "Use Recovery Key…")) {
                        model.useRecoveryKey()
                    }
                    .accessibilityIdentifier("account-keys-use-recovery-key")
                }
            }
        case .approved?:
            Section {
                Label(String(localized: "This device has your keys"), systemImage: "checkmark.seal.fill")
                Button(String(localized: "Replace Recovery Key…")) {
                    model.replaceRecoveryKey()
                }
                .accessibilityIdentifier("account-keys-replace-recovery-key")
            } header: {
                Text("Recovery Key")
            } footer: {
                Text("Keep it on paper or in a password manager. You need it to remove a lost device.")
            }
            if !model.requests.isEmpty {
                requestsSection
            }
            devicesSection
        }
    }

    private var requestsSection: some View {
        Section {
            ForEach(model.requests, id: \.request) { request in
                Button {
                    model.approve(request)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: AccountKeysText.deviceName(request.deviceName))
                        Text(verbatim: requestSubtitle(request))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(Text(String(
                    format: String(localized: "Approve %@"),
                    AccountKeysText.deviceName(request.deviceName)
                )))
            }
        } header: {
            Text("Waiting for Approval")
        } footer: {
            Text("Approve only a device you're signing in to right now.")
        }
    }

    private func requestSubtitle(_ request: ApprovalRequestInfo) -> String {
        let asked = AccountKeysText.date(microseconds: request.requestedAtUs)
        let when = String(format: String(localized: "Asked %@"), asked.formatted(.relative(presentation: .named)))
        return [AccountKeysText.platform(request.platform), when].compactMap { $0 }.joined(separator: " · ")
    }

    private var devicesSection: some View {
        Section {
            if let failure = model.devices.failure, model.devices.value == nil {
                AccountKeysFailureText(message: failure)
                Button(String(localized: "Try Again")) { Task { await model.reload() } }
                    .disabled(model.devices.isLoading)
            } else if model.devices.value == nil {
                AccountKeysLoadingRow(label: String(localized: "Loading devices"))
            }

            ForEach(model.sortedDevices, id: \.keyDevice) { device in
                AccountKeyDeviceRow(
                    device: device,
                    isRemoving: model.removing == device.keyDevice,
                    isDisabled: model.removing != nil || model.sheet != nil
                ) {
                    if device.device == nil {
                        Task { await model.remove(device) }
                    } else {
                        model.pendingRemoval = device
                    }
                }
            }
        } header: {
            Text("Devices With Your Keys")
        } footer: {
            Text("Removing a device signs it out and changes your keys, so it can't read anything new. You need your recovery key.")
        }
    }
}

private struct AccountKeyDeviceRow: View {
    let device: AccountDeviceInfo
    let isRemoving: Bool
    let isDisabled: Bool
    let onRemove: () -> Void

    // A device whose row is gone but whose keys have not changed yet: the removal waits for the recovery key.
    private var awaitsKeyChange: Bool {
        device.device == nil && !device.thisDevice
    }

    private var subtitle: String {
        var parts: [String] = []
        if device.thisDevice {
            parts.append(String(localized: "This Device"))
        }
        if let platform = AccountKeysText.platform(device.platform), !device.thisDevice {
            parts.append(platform)
        }
        if awaitsKeyChange {
            parts.append(String(localized: "Removed, keys not changed yet"))
        } else if let added = device.addedAtUs {
            let date = AccountKeysText.date(microseconds: added).formatted(date: .abbreviated, time: .omitted)
            parts.append(String(format: String(localized: "Added %@"), date))
        }
        return parts.joined(separator: " · ")
    }

    private var actionTitle: String {
        awaitsKeyChange ? String(localized: "Finish Removing") : String(localized: "Remove")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AccountKeysText.deviceName(device.name))
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundStyle(awaitsKeyChange ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 8)
            if isRemoving {
                ProgressView()
                    .accessibilityLabel(Text("Removing"))
            } else if awaitsKeyChange {
                Button(actionTitle, action: onRemove)
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
            }
        }
        .swipeActions {
            if !device.thisDevice, !isRemoving, !awaitsKeyChange {
                Button(actionTitle, role: .destructive, action: onRemove)
                    .disabled(isDisabled)
            }
        }
        .contextMenu {
            if !device.thisDevice, !isRemoving {
                Button(actionTitle, role: awaitsKeyChange ? nil : .destructive, action: onRemove)
                    .disabled(isDisabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if !device.thisDevice, !isRemoving, !isDisabled {
                Button(actionTitle, action: onRemove)
            }
        }
    }
}

// Which sheet the page shows, each closing through the page's model.
struct AccountKeysSheetContent: View {
    let sheet: AccountKeysModel.Sheet
    let model: AccountKeysModel

    var body: some View {
        switch sheet {
        case .recoveryKey(let flow):
            AccountRecoveryKeySheet(
                flow: flow,
                copySecret: { model.environment.copySecret($0) },
                onAskForApproval: { model.askAfterAnotherDeviceWon() },
                onClose: { model.closeSheet() }
            )
        case .approval(let flow):
            AccountApprovalSheet(flow: flow, onAskAgain: { model.askAgain() }, onClose: { model.closeSheet() })
        case .removal(let flow):
            AccountRemovalSheet(flow: flow, onClose: { model.closeSheet() })
        case .recover(let flow):
            AccountRecoverSheet(flow: flow, onClose: { model.closeSheet() })
        }
    }
}
