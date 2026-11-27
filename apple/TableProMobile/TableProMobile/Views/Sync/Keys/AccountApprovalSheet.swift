import SwiftUI
import TableProFFI

// Either side of one approval: the person compares five words on both devices and confirms on each.
struct AccountApprovalSheet: View {
    let flow: AccountApprovalFlow
    let onAskAgain: () -> Void
    let onClose: () -> Void

    private var otherName: String? {
        guard case .approver(let request) = flow.role else { return nil }
        return AccountKeysText.deviceName(request.deviceName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    details
                    if let expiresAt = flow.expiresAt, !flow.phase.hasEnded, flow.phase != .reviewing {
                        AccountApprovalTimeLeft(expiresAt: expiresAt)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let message {
                            Text(verbatim: message)
                        }
                        AccountKeysFailureText(message: flow.actionFailure)
                    }
                }
                if case .compare = flow.phase {
                    Section {
                        Button(String(localized: "They Don't Match"), role: .destructive) {
                            Task { await flow.wordsDiffer() }
                        }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier("account-approval-words-differ")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(!flow.phase.hasEnded && flow.phase != .reviewing)
        .accessibilityIdentifier("account-approval-sheet")
        .task {
            await flow.start()
        }
    }

    private var title: String {
        switch flow.phase {
        case .reviewing:
            String(format: String(localized: "Approve “%@”?"), otherName ?? "")
        case .starting where flow.isNewDevice:
            String(localized: "Asking for Approval")
        case .starting:
            String(localized: "Starting the Approval")
        case .waiting where flow.isNewDevice:
            String(localized: "Approve From Another Device")
        case .waiting:
            String(localized: "Another Device Is Approving This One")
        case .chosen where !flow.isNewDevice:
            String(format: String(localized: "Waiting for “%@”"), otherName ?? "")
        case .chosen, .compare:
            String(localized: "Compare the Words")
        case .confirmed:
            String(localized: "Waiting for the Other Device")
        case .approved where flow.isNewDevice:
            String(localized: "This Device Is Approved")
        case .approved:
            String(format: String(localized: "“%@” Is Approved"), otherName ?? "")
        case .takenElsewhere:
            String(localized: "Another Device Is Approving It")
        case .cancelled(.mismatch):
            String(localized: "The Words Didn't Match")
        case .cancelled(.commitment):
            String(localized: "The Request Couldn't Be Checked")
        case .cancelled(.user):
            String(localized: "Request Canceled")
        case .expired:
            String(localized: "Request Expired")
        case .failed:
            String(localized: "Approval Didn't Start")
        }
    }

    private var message: String? {
        switch flow.phase {
        case .reviewing:
            String(localized: "Approve only a device you're signing in to right now. It gets your keys and everything TablePro Sync keeps for you.")
        case .starting:
            nil
        case .waiting:
            String(localized: "On another device signed in to your account, open TablePro's account settings, choose End-to-End Encryption and approve this device.")
        case .chosen:
            String(localized: "The five words to compare appear in a moment.")
        case .compare where flow.isNewDevice:
            String(localized: "Check that the other device shows the same five words in the same order.")
        case .compare:
            String(format: String(localized: "Check that “%@” shows the same five words in the same order."), otherName ?? "")
        case .confirmed:
            String(localized: "Confirm the words on the other device too.")
        case .approved where flow.isNewDevice:
            String(localized: "It now has your keys, and TablePro Sync starts here.")
        case .approved:
            String(localized: "It now has your keys.")
        case .takenElsewhere:
            String(format: String(localized: "“%@” is being approved on another of your devices."), otherName ?? "")
        case .cancelled(.mismatch):
            String(localized: "Nothing was approved. If you didn't start this request, someone may be trying to get your keys.")
        case .cancelled(.commitment):
            String(localized: "The other device's answer didn't match what this device sent, so nothing was approved.")
        case .cancelled(.user):
            String(localized: "Nothing was approved.")
        case .expired:
            String(localized: "A request lasts 10 minutes. Nothing was approved.")
        case .failed(let reason):
            reason
        }
    }

    @ViewBuilder
    private var details: some View {
        switch flow.phase {
        case .reviewing:
            if case .approver(let request) = flow.role {
                if let platform = AccountKeysText.platform(request.platform) {
                    LabeledContent(String(localized: "Platform"), value: platform)
                }
                LabeledContent(
                    String(localized: "Asked"),
                    value: AccountKeysText.date(microseconds: request.requestedAtUs).formatted(date: .omitted, time: .shortened)
                )
            }
        case .starting, .waiting, .chosen, .confirmed:
            AccountKeysLoadingRow(label: waitingLabel)
        case .compare(let words):
            AccountApprovalWords(words: words)
        case .approved:
            Label(String(localized: "Approved"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .takenElsewhere, .cancelled, .expired, .failed:
            Label(String(localized: "Nothing was approved"), systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var waitingLabel: String {
        switch flow.phase {
        case .waiting: String(localized: "Waiting for another device")
        case .chosen: String(localized: "Waiting for the words")
        case .confirmed: String(localized: "Waiting for the other device to confirm")
        default: String(localized: "Working")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch flow.phase {
        case .reviewing:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), action: onClose)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Approve")) {
                    Task { await flow.approve() }
                }
                .accessibilityIdentifier("account-approval-approve")
            }
        case .compare:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), action: onClose)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "They Match")) {
                    Task { await flow.wordsMatch() }
                }
                .disabled(flow.isWorking)
                .accessibilityIdentifier("account-approval-words-match")
            }
        case .starting, .waiting, .chosen, .confirmed:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), action: onClose)
                    .accessibilityIdentifier("account-approval-cancel")
            }
        case .cancelled, .expired, .failed:
            if flow.isNewDevice {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close"), action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Ask Again"), action: onAskAgain)
                        .accessibilityIdentifier("account-approval-ask-again")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done"), action: onClose)
                }
            }
        case .approved, .takenElsewhere:
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: onClose)
                    .accessibilityIdentifier("account-approval-done")
            }
        }
    }
}

// The five words, large enough to read aloud and compare across two screens. They are never selectable or copied.
private struct AccountApprovalWords: View {
    let words: [String]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(words.indices, id: \.self) { index in
                Text(verbatim: words[index])
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "The words: %@"), words.joined(separator: ", "))))
        .accessibilityIdentifier("account-approval-words")
    }
}

private struct AccountApprovalTimeLeft: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if timeline.date < expiresAt {
                LabeledContent(String(localized: "Time Left")) {
                    Text(timerInterval: timeline.date ... expiresAt, countsDown: true)
                        .monospacedDigit()
                }
            }
        }
    }
}
