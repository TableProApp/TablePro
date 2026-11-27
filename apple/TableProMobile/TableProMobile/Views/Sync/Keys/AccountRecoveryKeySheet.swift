import SwiftUI
import TableProFFI

// Set Up and Replace: the new key shown once, then two of its groups typed back before anything is pushed.
struct AccountRecoveryKeySheet: View {
    let flow: AccountRecoveryKeyFlow
    let copySecret: @MainActor (String) -> Void
    let onAskForApproval: () -> Void
    let onClose: () -> Void

    @State private var copied = false

    private var isReplace: Bool {
        flow.purpose == .replace
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        // A key on screen goes only by Cancel or Done, never by a stray swipe.
        .interactiveDismissDisabled(flow.hasKey || flow.isWorking)
        .accessibilityIdentifier("account-recovery-key-sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .enterCurrentKey:
            enterCurrentKey
        case .chooseDevices:
            chooseDevices
        case .showKey:
            showKey
        case .typeBack:
            typeBack
        case .anotherDeviceWon:
            message(
                title: String(localized: "Approve This Device Instead"),
                text: String(localized: "Another device set up your keys first, so this key wasn't used. Ask that device to approve this one.")
            )
        case .done:
            message(
                title: isReplace ? String(localized: "Recovery Key Replaced") : String(localized: "Recovery Key Set Up"),
                text: isReplace
                    ? String(localized: "Your old recovery key no longer works. Devices you didn't keep ask for approval again.")
                    : String(localized: "Keep your recovery key somewhere safe. TablePro Sync now seals your secrets on this device.")
            )
        }
    }

    private var enterCurrentKey: some View {
        Form {
            Section {
                AccountRecoveryKeyField(text: Bindable(flow).currentKey) {
                    Task { await flow.advance() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter your current recovery key. You get a new one, and the current one stops working.")
                    AccountKeysFailureText(message: flow.failure)
                }
            }
        }
        .navigationTitle(String(localized: "Replace Recovery Key"))
    }

    private var chooseDevices: some View {
        Form {
            Section {
                ForEach(flow.devices, id: \.device.keyDevice) { device in
                    AccountKeepDeviceToggle(
                        device: device.device,
                        isOn: Binding(
                            get: { device.device.thisDevice || flow.keep.contains(device.device.keyDevice) },
                            set: { flow.setKeep(device, $0) }
                        ),
                        isEnabled: flow.canKeep(device)
                    )
                }
            } footer: {
                Text("Devices you compared words with can keep your keys. Every other device asks for approval again.")
            }
        }
        .navigationTitle(String(localized: "Keep Your Devices?"))
    }

    private var showKey: some View {
        Form {
            Section {
                if flow.hasKey {
                    AccountRecoveryKeyGrid(groups: flow.groups)
                        .padding(.vertical, 8)
                    Button {
                        copySecret(flow.keyText)
                        copied = true
                    } label: {
                        Label(
                            copied ? String(localized: "Copied") : String(localized: "Copy Recovery Key"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier("account-recovery-key-copy")
                } else if flow.isWorking {
                    AccountKeysLoadingRow(label: String(localized: "Making your recovery key"))
                } else if flow.failure != nil {
                    AccountKeysFailureText(message: flow.failure)
                    Button(String(localized: "Try Again")) {
                        Task { await flow.start() }
                    }
                }
            } footer: {
                Text("Save it in a password manager or write it down. TablePro can't show it again or recover it. You need it to remove a lost device. A copy leaves the clipboard after a minute.")
            }
        }
        .navigationTitle(isReplace ? String(localized: "Your New Recovery Key") : String(localized: "Set Up a Recovery Key"))
        .task {
            await flow.start()
        }
    }

    private var typeBack: some View {
        Form {
            Section {
                AccountRecoveryKeyTypeBack(groups: flow.checkedGroups, typed: Bindable(flow).typed) {
                    Task { await flow.advance() }
                }
            } header: {
                Text(checkMessage)
            } footer: {
                AccountKeysFailureText(message: flow.failure)
            }
            Section {
                Button(String(localized: "Show Key Again")) {
                    flow.showKeyAgain()
                }
                .disabled(flow.isWorking)
            }
        }
        .navigationTitle(String(localized: "Confirm Your Recovery Key"))
    }

    private var checkMessage: String {
        let groups = flow.checkedGroups.map { $0.formatted() }
        guard groups.count == 2 else { return String(localized: "Type the groups of your recovery key it asks for.") }
        return String(format: String(localized: "Type groups %@ and %@ of your recovery key."), groups[0], groups[1])
    }

    private func message(title: String, text: String) -> some View {
        Form {
            Section {
                Text(verbatim: text)
            }
        }
        .navigationTitle(title)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch flow.step {
        case .enterCurrentKey, .chooseDevices, .showKey, .typeBack:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), action: onClose)
                    .disabled(flow.isWorking && flow.step == .typeBack)
            }
            ToolbarItem(placement: .confirmationAction) {
                if flow.isWorking, flow.hasKey || flow.step == .enterCurrentKey {
                    ProgressView()
                } else {
                    Button(continueTitle) {
                        Task { await flow.advance() }
                    }
                    .disabled(!flow.canContinue)
                    .accessibilityIdentifier("account-recovery-key-continue")
                }
            }
        case .anotherDeviceWon:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close"), action: onClose)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Ask Another Device"), action: onAskForApproval)
            }
        case .done:
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: onClose)
                    .accessibilityIdentifier("account-recovery-key-done-button")
            }
        }
    }

    private var continueTitle: String {
        switch flow.step {
        case .typeBack: isReplace ? String(localized: "Replace") : String(localized: "Set Up")
        default: String(localized: "Continue")
        }
    }
}
