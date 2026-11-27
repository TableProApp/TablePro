//
//  AccountApprovalSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// Either side of one approval: the person compares five words on both devices and confirms on each.
internal struct AccountApprovalSheet: View {
    @ObservedObject var flow: AccountApprovalFlow
    let onAskAgain: () -> Void
    let onClose: () -> Void

    private var otherName: String? {
        guard case .approver(let request) = flow.role else { return nil }
        return AccountKeysText.deviceName(request.deviceName)
    }

    var body: some View {
        AccountKeysSheetLayout(
            title: title,
            message: message,
            identifier: "account-approval-sheet"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                details
                if let failure = flow.actionFailure {
                    AccountKeysFailureNotice(message: failure)
                }
                if let expiresAt = flow.expiresAt, !flow.phase.hasEnded, flow.phase != .reviewing {
                    AccountApprovalTimeLeft(expiresAt: expiresAt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom)
        } auxiliary: {
            auxiliary
        } actions: {
            actions
        }
        .task {
            await flow.start()
        }
    }

    // MARK: - Words per phase

    private var title: String {
        switch flow.phase {
        case .reviewing:
            String(format: String(localized: "Approve “%@”?"), otherName ?? "")
        case .starting where flow.isNewDevice:
            String(localized: "Asking for Approval")
        case .starting:
            String(localized: "Starting the Approval")
        case .waiting:
            String(localized: "Approve This Mac From Another Device")
        case .chosen where flow.isNewDevice:
            String(localized: "Another Device Is Approving This Mac")
        case .chosen:
            String(format: String(localized: "Waiting for “%@”"), otherName ?? "")
        case .compare:
            String(localized: "Compare the Words")
        case .confirmed:
            String(localized: "Waiting for the Other Device")
        case .approved where flow.isNewDevice:
            String(localized: "This Mac Is Approved")
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
            String(localized: "On another device signed in to your account, open TablePro's account settings, choose End-to-End Encryption and approve this Mac.")
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
            String(localized: "The other device's answer didn't match what this Mac sent, so nothing was approved.")
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
                AccountApprovalRequestDetails(request: request)
            }
        case .starting, .waiting, .chosen, .confirmed:
            AccountKeysLoadingRow(label: waitingLabel)
        case .compare(let words):
            AccountApprovalWords(words: words)
        case .approved, .takenElsewhere, .cancelled, .expired, .failed:
            EmptyView()
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

    // MARK: - Buttons

    @ViewBuilder
    private var auxiliary: some View {
        if case .compare = flow.phase {
            Button(String(localized: "They Don't Match")) {
                Task { await flow.wordsDiffer() }
            }
            .disabled(flow.isWorking)
            .accessibilityIdentifier("account-approval-words-differ")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.phase {
        case .reviewing:
            Button(String(localized: "Cancel"), action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Approve")) {
                Task { await flow.approve() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("account-approval-approve")
        case .compare:
            Button(String(localized: "Cancel"), action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "The Words Match")) {
                Task { await flow.wordsMatch() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(flow.isWorking)
            .accessibilityIdentifier("account-approval-words-match")
        case .starting, .waiting, .chosen, .confirmed:
            Button(String(localized: "Cancel"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("account-approval-cancel")
        case .cancelled, .expired, .failed:
            if flow.isNewDevice {
                Button(String(localized: "Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Ask Again"), action: onAskAgain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("account-approval-ask-again")
            } else {
                Button(String(localized: "Done"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        case .approved, .takenElsewhere:
            Button(String(localized: "Done"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("account-approval-done")
        }
    }
}

private struct AccountApprovalRequestDetails: View {
    let request: ApprovalRequestInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let platform = AccountKeysText.platform(request.platform) {
                LabeledContent(String(localized: "Platform"), value: platform)
            }
            LabeledContent(
                String(localized: "Asked"),
                value: AccountKeysText.date(microseconds: request.requestedAtUs).formatted(date: .omitted, time: .shortened)
            )
        }
    }
}

// The five words, large enough to read aloud and compare across two screens. They are never selectable or copied.
private struct AccountApprovalWords: View {
    let words: [String]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(words.indices, id: \.self) { index in
                Text(verbatim: words[index])
                    .font(.title2.weight(.semibold))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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
                HStack(spacing: 4) {
                    Text("Time left:")
                    Text(timerInterval: timeline.date ... expiresAt, countsDown: true)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}
