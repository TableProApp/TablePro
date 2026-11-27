//
//  AccountRecoveryKeySheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProFFI

// Set Up and Replace: the new key shown once, then two of its groups typed back before anything is pushed.
internal struct AccountRecoveryKeySheet: View {
    @ObservedObject var flow: AccountRecoveryKeyFlow
    let copySecret: (String) -> Void
    let onAskForApproval: () -> Void
    let onClose: () -> Void

    private var isReplace: Bool {
        flow.purpose == .replace
    }

    var body: some View {
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
            anotherDeviceWon
        case .done:
            done
        }
    }

    private var enterCurrentKey: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Replace Recovery Key"),
            message: String(localized: "Enter your current recovery key. You get a new one, and the current one stops working."),
            identifier: "account-recovery-key-replace"
        ) {
            Form {
                Section {
                    AccountRecoveryKeyField(text: $flow.currentKey) {
                        Task { await flow.advance() }
                    }
                    AccountKeysFailureNotice(message: flow.failure)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            cancelButton
            continueButton(String(localized: "Continue"))
        }
    }

    private var chooseDevices: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Keep Your Devices?"),
            message: String(localized: "Devices you compared words with can keep your keys. Every other device asks for approval again."),
            identifier: "account-recovery-key-devices"
        ) {
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
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 320)
        } actions: {
            cancelButton
            continueButton(String(localized: "Continue"))
        }
    }

    private var showKey: some View {
        AccountKeysSheetLayout(
            title: isReplace ? String(localized: "Your New Recovery Key") : String(localized: "Set Up a Recovery Key"),
            message: String(localized: "Save it in a password manager or write it down. TablePro can't show it again or recover it. You need it to remove a lost device."),
            identifier: "account-recovery-key-show"
        ) {
            VStack(spacing: 16) {
                if flow.hasKey {
                    AccountRecoveryKeyGrid(groups: flow.groups)

                    HStack(spacing: 8) {
                        Button(String(localized: "Copy")) {
                            copySecret(flow.keyText)
                            AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
                        }
                        .accessibilityLabel(Text("Copy recovery key"))
                        .accessibilityIdentifier("account-recovery-key-copy")

                        Button(String(localized: "Print…")) {
                            AccountRecoveryKeyPrinter.print(groups: flow.groups)
                        }
                        .accessibilityIdentifier("account-recovery-key-print")
                    }
                } else if flow.isWorking {
                    AccountKeysLoadingRow(label: String(localized: "Making your recovery key"))
                } else if flow.failure != nil {
                    HStack(spacing: 8) {
                        AccountKeysFailureNotice(message: flow.failure)
                        Spacer(minLength: 12)
                        Button(String(localized: "Try Again")) {
                            Task { await flow.start() }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        } actions: {
            cancelButton
            continueButton(String(localized: "Continue"))
        }
        .task {
            await flow.start()
        }
    }

    private var typeBack: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Confirm Your Recovery Key"),
            message: checkMessage,
            identifier: "account-recovery-key-check"
        ) {
            Form {
                Section {
                    ForEach(flow.check.indices, id: \.self) { position in
                        TextField(
                            String(format: String(localized: "Group %@"), (flow.check[position] + 1).formatted()),
                            text: Binding(
                                get: { flow.typed.indices.contains(position) ? flow.typed[position] : "" },
                                set: { if flow.typed.indices.contains(position) { flow.typed[position] = $0 } }
                            ),
                            prompt: Text(verbatim: "XXXX")
                        )
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .onSubmit { Task { await flow.advance() } }
                        .accessibilityIdentifier("account-recovery-key-group-\(position)")
                    }
                    AccountKeysFailureNotice(message: flow.failure)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        } auxiliary: {
            Button(String(localized: "Show Key Again")) {
                flow.showKeyAgain()
            }
            .disabled(flow.isWorking)
        } actions: {
            cancelButton
            continueButton(isReplace ? String(localized: "Replace") : String(localized: "Set Up"))
        }
    }

    private var checkMessage: String {
        let groups = flow.check.map { ($0 + 1).formatted() }
        guard groups.count == 2 else { return String(localized: "Type the groups of your recovery key it asks for.") }
        return String(format: String(localized: "Type groups %@ and %@ of your recovery key."), groups[0], groups[1])
    }

    private var anotherDeviceWon: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Approve This Mac Instead"),
            message: String(localized: "Another device set up your keys first, so this key wasn't used. Ask that device to approve this Mac."),
            identifier: "account-recovery-key-another-device"
        ) {
            EmptyView()
        } actions: {
            Button(String(localized: "Close"), action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Ask Another Device…"), action: onAskForApproval)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var done: some View {
        AccountKeysSheetLayout(
            title: isReplace ? String(localized: "Recovery Key Replaced") : String(localized: "Recovery Key Set Up"),
            message: isReplace
                ? String(localized: "Your old recovery key no longer works. Devices you didn't keep ask for approval again.")
                : String(localized: "Keep your recovery key somewhere safe. TablePro Sync now seals your secrets on this Mac."),
            identifier: "account-recovery-key-done"
        ) {
            EmptyView()
        } actions: {
            Button(String(localized: "Done"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("account-recovery-key-done-button")
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "Cancel"), action: onClose)
            .keyboardShortcut(.cancelAction)
    }

    private func continueButton(_ title: String) -> some View {
        HStack(spacing: 8) {
            if flow.isWorking, flow.hasKey || flow.step == .enterCurrentKey {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Working"))
            }
            Button(title) {
                Task { await flow.advance() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.canContinue)
            .accessibilityIdentifier("account-recovery-key-continue")
        }
    }
}

// A device a rotation can keep, ticked for those it keeps. This Mac always stays.
internal struct AccountKeepDeviceToggle: View {
    let device: AccountDeviceInfo
    let isOn: Binding<Bool>
    let isEnabled: Bool

    private var subtitle: String {
        if device.thisDevice {
            return String(localized: "This Mac")
        }
        return isEnabled
            ? String(localized: "You compared words with it")
            : String(localized: "Asks for approval again")
    }

    var body: some View {
        Toggle(isOn: isOn) {
            Text(verbatim: AccountKeysText.deviceName(device.name))
            Text(verbatim: [AccountKeysText.platform(device.platform), subtitle].compactMap { $0 }.joined(separator: " · "))
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("account-keep-device-\(device.keyDevice)")
    }
}

// The key on paper: what the ADR names as one of the two places to keep it.
@MainActor
internal enum AccountRecoveryKeyPrinter {
    static func print(groups: [String]) {
        let page = NSHostingView(rootView: AccountRecoveryKeyPrintPage(groups: groups))
        page.frame = NSRect(origin: .zero, size: page.fittingSize)
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        let operation = NSPrintOperation(view: page, printInfo: info)
        operation.jobTitle = String(localized: "TablePro Recovery Key")
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

private struct AccountRecoveryKeyPrintPage: View {
    let groups: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("TablePro Recovery Key")
                .font(.title2.weight(.semibold))
            Text(Date.now.formatted(date: .long, time: .omitted))
                .foregroundStyle(.secondary)
            AccountRecoveryKeyGrid(groups: groups)
            Text("Keep this page somewhere safe. With it, someone signed in to your TablePro account can read what TablePro Sync keeps for you.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(width: 520, alignment: .leading)
        .environment(\.colorScheme, .light)
    }
}
