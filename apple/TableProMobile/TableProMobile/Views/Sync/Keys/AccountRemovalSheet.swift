import SwiftUI
import TableProFFI

// The rest of a removal once the device's row is gone: the recovery key, the review, the seats, then the new keys.
struct AccountRemovalSheet: View {
    let flow: AccountRemovalFlow
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .accessibilityIdentifier("account-removal-sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .enterKey:
            Form {
                Section {
                    AccountRecoveryKeyField(text: Bindable(flow).recoveryKey) {
                        Task { await flow.advance() }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(
                            format: String(localized: "“%@” is signed out. Enter your recovery key so TablePro can change your keys, and the removed device can't read anything new."),
                            flow.deviceName
                        ))
                        AccountKeysFailureText(message: flow.failure)
                    }
                }
            }
            .navigationTitle(String(format: String(localized: "Finish Removing “%@”"), flow.deviceName))
        case .review:
            review
        case .seats:
            seats
        case .done:
            Form {
                Section {
                    Text("Your keys changed. Your other devices pick up the new keys the next time they sync.")
                }
            }
            .navigationTitle(String(format: String(localized: "“%@” Removed"), flow.deviceName))
        }
    }

    private var review: some View {
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
                } footer: {
                    Text("Choose the devices that keep your keys, and check the teammates you confirmed while the removed device had them.")
                }
            }

            ForEach(flow.memberGroups) { group in
                Section {
                    ForEach(group.members) { member in
                        Toggle(isOn: Binding(
                            get: { !flow.removing.contains(member.id) },
                            set: { flow.setRemoving(member, !$0) }
                        )) {
                            Text(verbatim: memberName(member))
                            if let email = member.email, !member.isSelf, member.name != nil {
                                Text(verbatim: email)
                            }
                        }
                        .disabled(flow.isWorking || member.isSelf)
                    }
                } header: {
                    Text(verbatim: group.team.name ?? String(localized: "Unnamed team"))
                } footer: {
                    Text(String(
                        format: String(localized: "Confirmed while “%@” had your keys. Turn off anyone you didn't mean to confirm."),
                        flow.deviceName
                    ))
                }
            }

            if let failure = flow.failure {
                Section {
                    AccountKeysFailureText(message: failure)
                }
            }
        }
        .navigationTitle(String(localized: "Review Before Changing Keys"))
    }

    private var seats: some View {
        Form {
            Section {
                ForEach(flow.teamsToVisit) { team in
                    Button {
                        flow.openTeam(team)
                    } label: {
                        LabeledContent(team.name ?? String(localized: "Unnamed team")) {
                            Image(systemName: "arrow.up.forward.square")
                        }
                    }
                }
            } footer: {
                Text("Remove the seats of the teammates you turned off, then change your keys. The new team keys leave them out either way.")
            }
            Section {
                Button(String(localized: "Back to the Review")) {
                    flow.backToReview()
                }
                .disabled(flow.isWorking)
            } footer: {
                AccountKeysFailureText(message: flow.failure)
            }
        }
        .navigationTitle(String(localized: "Remove Their Seats First"))
    }

    private func memberName(_ member: AccountRemovalReview.Member) -> String {
        if member.isSelf {
            return String(localized: "You")
        }
        return member.name ?? member.email ?? String(localized: "Unnamed teammate")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if flow.step == .done {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: onClose)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Later"), action: onClose)
                    .disabled(flow.isWorking)
            }
            ToolbarItem(placement: .confirmationAction) {
                if flow.isWorking {
                    ProgressView()
                } else {
                    Button(primaryTitle) {
                        Task { await flow.advance() }
                    }
                    .disabled(!flow.canContinue)
                    .accessibilityIdentifier("account-removal-continue")
                }
            }
        }
    }

    private var primaryTitle: String {
        switch flow.step {
        case .review where flow.removing.isEmpty, .seats: String(localized: "Change Keys")
        default: String(localized: "Continue")
        }
    }
}

// Recovery with the recovery key, when no other device of this account is at hand.
struct AccountRecoverSheet: View {
    let flow: AccountRecoverFlow
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if flow.isDone {
                    Section {
                        Text("It has your keys again. Approve your other devices from here when they ask.")
                    }
                } else {
                    Section {
                        AccountRecoveryKeyField(text: Bindable(flow).recoveryKey) {
                            Task { await flow.recover() }
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Use it only when no other device of yours is at hand. This device gets new keys, and your other devices ask it for approval again.")
                            AccountKeysFailureText(message: flow.failure)
                        }
                    }
                }
            }
            .navigationTitle(flow.isDone ? String(localized: "This Device Is Approved") : String(localized: "Use Your Recovery Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if flow.isDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done"), action: onClose)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel"), action: onClose)
                            .disabled(flow.isWorking)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if flow.isWorking {
                            ProgressView()
                        } else {
                            Button(String(localized: "Use Recovery Key")) {
                                Task { await flow.recover() }
                            }
                            .disabled(!flow.canRecover)
                            .accessibilityIdentifier("account-recover-confirm")
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .accessibilityIdentifier("account-recover-sheet")
    }
}
