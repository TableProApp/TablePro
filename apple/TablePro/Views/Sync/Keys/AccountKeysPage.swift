//
//  AccountKeysPage.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// Settings > Account > End-to-End Encryption. Its sheets hang off the page: only this page starts them, and a
// sign-out that pops the page ends them with it.
internal struct AccountKeysPage: View {
    @ObservedObject var model: AccountKeysModel

    var body: some View {
        Form {
            content
            if Self.showsResets(model.state.value) {
                ResetKeysSection(model: model.resets)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.accountEncryption.pageIdentifier)
        .task {
            await model.refresh()
        }
        .task {
            await model.watchRequests()
        }
        .sheet(item: sheetBinding) { sheet in
            AccountKeysSheetContent(sheet: sheet, model: model)
        }
        .alert(
            model.pendingRemoval.map {
                String(format: String(localized: "Remove “%@”?"), AccountKeysText.deviceName($0.name))
            } ?? "",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
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

    // A reset needs keys on the account: kind 2 from an approved Mac, kind 3 from one waiting for approval or locked,
    // and every device shows a pending one (core ADR 0056, Reset).
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
                    AccountKeysFailureRow(message: failure, isRetrying: model.state.isLoading) {
                        Task { await model.reload() }
                    }
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
                    symbol: "lock.slash",
                    title: String(localized: "This Mac can't keep keys"),
                    message: String(localized: "Without a place to keep keys, TablePro Sync carries only team records without their secrets here.")
                )
            }
        case .noKeys?:
            AccountKeysSetUpSection(model: model)
        case .needsApproval(let request)?:
            AccountKeysApprovalNeededSection(model: model, hasOpenRequest: request != nil)
        case .locked(let cause)?:
            AccountKeysLockedSection(model: model, cause: cause)
        case .approved?:
            AccountKeysRecoverySection(model: model)
            if !model.requests.isEmpty {
                AccountKeysRequestsSection(model: model)
            }
            AccountKeysDevicesSection(model: model)
        }
    }
}

private struct AccountKeysSetUpSection: View {
    @ObservedObject var model: AccountKeysModel

    var body: some View {
        Section {
            LabeledContent {
                Button(String(localized: "Set Up…")) {
                    model.setUpRecoveryKey()
                }
                .fixedSize()
                .accessibilityIdentifier("account-keys-set-up")
            } label: {
                Text("Set up end-to-end encryption")
                Text("Your passwords, history and team secrets are sealed on this Mac before they sync. A recovery key you keep lets you add and remove devices.")
            }
        }
    }
}

private struct AccountKeysApprovalNeededSection: View {
    @ObservedObject var model: AccountKeysModel
    let hasOpenRequest: Bool

    var body: some View {
        Section {
            LabeledContent {
                Button(hasOpenRequest ? String(localized: "Show Request…") : String(localized: "Ask Another Device…")) {
                    model.askForApproval()
                }
                .fixedSize()
                .accessibilityIdentifier("account-keys-ask-approval")
            } label: {
                Text("Approve this Mac")
                Text("Your account already has keys. Approve this Mac from another device where you use TablePro.")
            }

            LabeledContent {
                Button(String(localized: "Use Recovery Key…")) {
                    model.useRecoveryKey()
                }
                .fixedSize()
                .accessibilityIdentifier("account-keys-use-recovery-key")
            } label: {
                Text("No other device at hand")
                Text("Use your recovery key instead. Your other devices then ask this Mac for approval.")
            }
        }
    }
}

private struct AccountKeysLockedSection: View {
    @ObservedObject var model: AccountKeysModel
    let cause: LockCauseTag

    var body: some View {
        Section {
            AccountKeysStatusRow(
                symbol: NoticeSeverity.warning.symbolName,
                tint: NoticeSeverity.warning.tint,
                title: AccountKeysText.lockTitle(cause),
                message: AccountKeysText.lockMessage(cause)
            )

            if AccountKeysText.canAskForApproval(cause) || AccountKeysText.canRecover(cause) {
                HStack(spacing: 8) {
                    Spacer()
                    if AccountKeysText.canRecover(cause) {
                        Button(String(localized: "Use Recovery Key…")) {
                            model.useRecoveryKey()
                        }
                        .accessibilityIdentifier("account-keys-use-recovery-key")
                    }
                    if AccountKeysText.canAskForApproval(cause) {
                        Button(String(localized: "Ask Another Device…")) {
                            model.askForApproval()
                        }
                        .accessibilityIdentifier("account-keys-ask-approval")
                    }
                }
            }
        }
    }
}

private struct AccountKeysRecoverySection: View {
    @ObservedObject var model: AccountKeysModel

    var body: some View {
        Section {
            LabeledContent {
                Button(String(localized: "Replace…")) {
                    model.replaceRecoveryKey()
                }
                .fixedSize()
                .accessibilityIdentifier("account-keys-replace")
            } label: {
                Text("Recovery key")
                Text("Keep it on paper or in a password manager. You need it to remove a lost device.")
            }
        } header: {
            Text("Recovery Key")
        }
    }
}

private struct AccountKeysRequestsSection: View {
    @ObservedObject var model: AccountKeysModel

    var body: some View {
        Section {
            ForEach(model.requests, id: \.request) { request in
                SettingsRecordRow(
                    title: AccountKeysText.deviceName(request.deviceName),
                    subtitle: subtitle(request)
                ) {
                    Button(String(localized: "Approve…")) {
                        model.approve(request)
                    }
                    .disabled(model.sheet != nil)
                    .fixedSize()
                    .accessibilityLabel(Text(String(
                        format: String(localized: "Approve %@"),
                        AccountKeysText.deviceName(request.deviceName)
                    )))
                }
            }
        } header: {
            Text("Waiting for Approval")
        } footer: {
            Text("Approve only a device you're signing in to right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ request: ApprovalRequestInfo) -> String {
        let asked = AccountKeysText.date(microseconds: request.requestedAtUs)
        let when = String(format: String(localized: "Asked %@"), asked.formatted(.relative(presentation: .named)))
        return [AccountKeysText.platform(request.platform), when].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AccountKeysDevicesSection: View {
    @ObservedObject var model: AccountKeysModel

    var body: some View {
        Section {
            if let failure = model.devices.failure, model.devices.value == nil {
                AccountKeysFailureRow(message: failure, isRetrying: model.devices.isLoading) {
                    Task { await model.reload() }
                }
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

            SettingsHelpRow("Removing a device signs it out and changes your keys, so it can't read anything new. You need your recovery key.")
        } header: {
            Text("Devices With Your Keys")
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
            parts.append(String(localized: "This Mac"))
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

    var body: some View {
        SettingsRecordRow(title: AccountKeysText.deviceName(device.name), subtitle: subtitle) {
            if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Removing"))
            } else if !device.thisDevice {
                Button(awaitsKeyChange ? String(localized: "Finish…") : String(localized: "Remove…"), action: onRemove)
                    .disabled(isDisabled)
                    .fixedSize()
                    .accessibilityLabel(Text(String(
                        format: awaitsKeyChange ? String(localized: "Finish removing %@") : String(localized: "Remove %@"),
                        AccountKeysText.deviceName(device.name)
                    )))
            }
        }
        .contextMenu {
            if !device.thisDevice, !isRemoving {
                Button(awaitsKeyChange ? String(localized: "Finish…") : String(localized: "Remove…"), action: onRemove)
                    .disabled(isDisabled)
            }
        }
    }
}

internal struct AccountKeysStatusRow: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)

                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

internal struct AccountKeysLoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(verbatim: label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountKeysFailureRow: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            NoticeLabel(message)

            Spacer(minLength: 12)

            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading"))
            } else {
                Button(String(localized: "Try Again"), action: onRetry)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
