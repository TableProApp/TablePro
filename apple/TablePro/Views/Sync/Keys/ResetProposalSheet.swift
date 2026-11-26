//
//  ResetProposalSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

internal struct ResetProposalSheet: View {
    @StateObject private var proposal: ResetProposalModel
    private let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(kind: ResetKindTag, service: any ResetKeysService, stepUp: StepUpRetry, onFinish: @escaping () -> Void) {
        _proposal = StateObject(wrappedValue: ResetProposalModel(kind: kind, service: service, stepUp: stepUp))
        self.onFinish = onFinish
    }

    init(proposal: @autoclosure @escaping () -> ResetProposalModel, onFinish: @escaping () -> Void) {
        _proposal = StateObject(wrappedValue: proposal())
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                switch proposal.phase {
                case .explain, .preparing:
                    ResetExplainStep(kind: proposal.kind)
                case .showKey:
                    ResetRecoveryKeyStep(groups: proposal.groups)
                case .typeBack, .submitting:
                    ResetTypeBackStep(proposal: proposal)
                case .done:
                    ResetProposedStep(proposed: proposal.proposed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)

            if let failure = proposal.failure {
                NoticeLabel(failure, severity: .error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 520)
        .interactiveDismissDisabled(proposal.phase == .preparing || proposal.phase == .submitting)
        .onDisappear {
            Task { await proposal.close() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch proposal.phase {
        case .explain, .preparing:
            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Continue")) { Task { await proposal.begin() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposal.phase == .preparing)
            }
        case .showKey:
            DialogFooter {
                Button(String(localized: "Copy")) {
                    ClipboardService.shared.writeSecretText(proposal.groups.joined(separator: "-"))
                }
            } actions: {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "I Saved It")) { proposal.continueToTypeBack() }
                    .keyboardShortcut(.defaultAction)
            }
        case .typeBack, .submitting:
            DialogFooter {
                Button(String(localized: "Show the Key Again")) { proposal.showKeyAgain() }
                    .disabled(proposal.phase == .submitting)
            } actions: {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(proposal.phase == .submitting)
                Button(String(localized: "Ask for Reset")) { Task { await proposal.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!proposal.canSubmit)
            }
        case .done:
            DialogFooter {
                Button(String(localized: "Done")) {
                    onFinish()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ResetExplainStep: View {
    let kind: ResetKindTag

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .keepScopeKeys:
                Text("Reset Your Keys")
                    .font(.headline)
                paragraph(String(localized: "Use this when you lost your recovery key and this Mac still has your keys. You get a new recovery key now."))
                paragraph(String(localized: "The reset waits 7 days. Any of your devices, or your old recovery key if you find it, can cancel it in that time."))
                paragraph(String(localized: "Then your other devices sign out and join again from this Mac. Your passwords and query history stay."))
                paragraph(String(localized: "Teammates see that your keys changed. An owner or admin of each team confirms you again before you get its passwords."))
            case .startEmpty:
                Text("Reset Your Keys and Start Empty")
                    .font(.headline)
                NoticeLabel(String(localized: "Use this only when you have no other device and no recovery key."))
                paragraph(String(localized: "You confirm it's you with your passkey first. Then you get a new recovery key."))
                paragraph(String(localized: "The reset waits 7 days. Your other devices, or your recovery key if you find it, can cancel it in that time."))
                paragraph(String(localized: "Then TablePro Sync deletes everything you synced to it, passwords and query history included. Team libraries stay."))
                paragraph(String(localized: "Teammates see that your keys changed. An owner or admin of each team confirms you again before you get its passwords."))
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// R' is shown once (core ADR 0056, The recovery key), in its 14 groups so it reads like the printed key.
private struct ResetRecoveryKeyStep: View {
    let groups: [String]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your New Recovery Key")
                .font(.headline)
            Text("Write it down or save it in your password manager. TablePro shows it only this once, and without it a lost device means another reset.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Text(verbatim: group)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("New recovery key"))
            .accessibilityValue(Text(verbatim: groups.joined(separator: " ")))
        }
    }
}

private struct ResetTypeBackStep: View {
    @ObservedObject var proposal: ResetProposalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Your Recovery Key")
                .font(.headline)
            Text("Type two of its groups from what you saved, so you know the copy is right.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(Array(proposal.checkedGroups.enumerated()), id: \.offset) { index, group in
                    TextField(String(format: String(localized: "Group %lld"), group), text: typedBinding(index))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .disabled(proposal.phase == .submitting)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)
            if proposal.phase == .submitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Asking for the reset")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func typedBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { proposal.typed.indices.contains(index) ? proposal.typed[index] : "" },
            set: { value in
                guard proposal.typed.indices.contains(index) else { return }
                proposal.typed[index] = value
            }
        )
    }
}

private struct ResetProposedStep: View {
    let proposed: PendingResetInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset Asked For")
                .font(.headline)
            if let proposed {
                Text(String(
                    format: String(localized: """
                        It can finish on %@, unless one of your devices or your old recovery key cancels it first. Come back to this \
                        Mac then to finish it.
                        """),
                    ResetKeysModel.date(proposed.heldUntilUs).formatted(date: .long, time: .shortened)
                ))
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your other devices and the web portal show the reset until then.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
