//
//  AccountRemovalSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// After the lost device's row is gone: the recovery key, the review, then where to remove teammates' seats.
internal struct AccountRemovalSheet: View {
    @ObservedObject var flow: AccountRemovalFlow
    let onClose: () -> Void

    var body: some View {
        switch flow.step {
        case .enterKey:
            enterKey
        case .review:
            review
        case .seats:
            seats
        case .done:
            done
        }
    }

    private var enterKey: some View {
        AccountKeysSheetLayout(
            title: String(format: String(localized: "Finish Removing “%@”"), flow.deviceName),
            message: String(format: String(
                localized: "“%@” is signed out. Enter your recovery key so TablePro can change your keys, and the removed device can't read anything new."
            ), flow.deviceName),
            identifier: "account-removal-key"
        ) {
            Form {
                Section {
                    AccountRecoveryKeyField(text: $flow.recoveryKey) {
                        Task { await flow.advance() }
                    }
                    AccountKeysFailureNotice(message: flow.failure)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button(String(localized: "Later"), action: onClose)
                .keyboardShortcut(.cancelAction)
            primary(String(localized: "Continue"))
        }
    }

    private var review: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Review Before Changing Your Keys"),
            message: String(localized: "Choose the devices that keep your keys, and check the teammates you confirmed while the removed device had them."),
            identifier: "account-removal-review"
        ) {
            Form {
                if let review = flow.review {
                    Section {
                        ForEach(review.devices, id: \.device.keyDevice) { device in
                            AccountKeepDeviceToggle(
                                device: device.device,
                                isOn: Binding(
                                    get: { device.device.thisDevice || flow.keep.contains(device.device.keyDevice) },
                                    set: { flow.setKeep(device, $0) }
                                ),
                                isEnabled: flow.canKeep(device) && !flow.isWorking
                            )
                        }
                    } header: {
                        Text("Your Devices")
                    }
                }

                ForEach(flow.memberGroups) { group in
                    Section {
                        ForEach(group.members) { member in
                            AccountReviewedMemberToggle(
                                member: member,
                                keeps: Binding(
                                    get: { !flow.removing.contains(member.id) },
                                    set: { flow.setRemoving(member, !$0) }
                                )
                            )
                            .disabled(flow.isWorking)
                        }
                    } header: {
                        Text(verbatim: group.team.name ?? String(localized: "Unnamed team"))
                    } footer: {
                        Text(String(
                            format: String(localized: "Confirmed while “%@” had your keys. Turn off anyone you didn't mean to confirm."),
                            flow.deviceName
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                if let failure = flow.failure {
                    Section {
                        AccountKeysFailureNotice(message: failure)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 420)
        } actions: {
            Button(String(localized: "Later"), action: onClose)
                .keyboardShortcut(.cancelAction)
            primary(flow.removing.isEmpty ? String(localized: "Change Keys") : String(localized: "Continue"))
        }
    }

    private var seats: some View {
        AccountKeysSheetLayout(
            title: String(localized: "Remove Their Seats First"),
            message: String(localized: "Remove the seats of the teammates you turned off, then change your keys. The new team keys leave them out either way."),
            identifier: "account-removal-seats"
        ) {
            Form {
                Section {
                    ForEach(flow.teamsToVisit) { team in
                        SettingsRecordRow(title: team.name ?? String(localized: "Unnamed team")) {
                            Button(String(localized: "Manage…")) {
                                flow.openTeam(team)
                            }
                            .fixedSize()
                        }
                    }
                }

                if let failure = flow.failure {
                    Section {
                        AccountKeysFailureNotice(message: failure)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 280)
        } auxiliary: {
            Button(String(localized: "Back")) {
                flow.backToReview()
            }
            .disabled(flow.isWorking)
        } actions: {
            Button(String(localized: "Later"), action: onClose)
                .keyboardShortcut(.cancelAction)
            primary(String(localized: "Change Keys"))
        }
    }

    private var done: some View {
        AccountKeysSheetLayout(
            title: String(format: String(localized: "“%@” Removed"), flow.deviceName),
            message: String(localized: "Your keys changed. Your other devices pick up the new keys the next time they sync."),
            identifier: "account-removal-finished"
        ) {
            EmptyView()
        } actions: {
            Button(String(localized: "Done"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("account-removal-done")
        }
    }

    private func primary(_ title: String) -> some View {
        HStack(spacing: 8) {
            if flow.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Working"))
            }
            Button(title) {
                Task { await flow.advance() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.canContinue)
            .accessibilityIdentifier("account-removal-continue")
        }
    }
}

private struct AccountReviewedMemberToggle: View {
    let member: AccountRemovalReview.Member
    let keeps: Binding<Bool>

    private var title: String {
        member.name ?? member.email ?? String(localized: "Unnamed teammate")
    }

    var body: some View {
        Toggle(isOn: keeps) {
            Text(verbatim: title)
            if member.name != nil, let email = member.email {
                Text(verbatim: email)
            }
        }
        .accessibilityIdentifier("account-removal-member-\(member.id)")
    }
}

// Recovery with the recovery key, on a Mac with no approved device at hand.
internal struct AccountRecoverSheet: View {
    @ObservedObject var flow: AccountRecoverFlow
    let onClose: () -> Void

    var body: some View {
        if flow.isDone {
            AccountKeysSheetLayout(
                title: String(localized: "This Mac Is Approved"),
                message: String(localized: "It has your keys again. Approve your other devices from this Mac when they ask."),
                identifier: "account-recover-done"
            ) {
                EmptyView()
            } actions: {
                Button(String(localized: "Done"), action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("account-recover-done-button")
            }
        } else {
            AccountKeysSheetLayout(
                title: String(localized: "Use Your Recovery Key"),
                message: String(localized: "Use it only when no other device of yours is at hand. This Mac gets new keys, and your other devices ask it for approval again."),
                identifier: "account-recover"
            ) {
                Form {
                    Section {
                        AccountRecoveryKeyField(text: $flow.recoveryKey) {
                            Task { await flow.recover() }
                        }
                        AccountKeysFailureNotice(message: flow.failure)
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button(String(localized: "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                HStack(spacing: 8) {
                    if flow.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Working"))
                    }
                    Button(String(localized: "Use Recovery Key")) {
                        Task { await flow.recover() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canRecover)
                    .accessibilityIdentifier("account-recover-continue")
                }
            }
        }
    }
}

// Which sheet the page shows, each closing through the page's model.
internal struct AccountKeysSheetContent: View {
    let sheet: AccountKeysModel.Sheet
    @ObservedObject var model: AccountKeysModel

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
