import SwiftUI
import TableProFFI

// A reset proposal: what it does, the new recovery key shown once, two of its groups typed back, then the request.
struct ResetProposalSheet: View {
    @State private var proposal: ResetProposalModel
    private let copySecret: @MainActor (String) -> Void
    private let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    init(
        kind: ResetKindTag,
        service: any ResetKeysService,
        stepUp: StepUpRetry,
        copySecret: @escaping @MainActor (String) -> Void,
        onFinish: @escaping () -> Void
    ) {
        _proposal = State(initialValue: ResetProposalModel(kind: kind, service: service, stepUp: stepUp))
        self.copySecret = copySecret
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Form {
                switch proposal.phase {
                case .explain, .preparing:
                    explain
                case .showKey:
                    showKey
                case .typeBack, .submitting:
                    typeBack
                case .done:
                    proposed
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(proposal.phase != .explain && proposal.phase != .done)
        .onDisappear {
            Task { await proposal.close() }
        }
    }

    private var title: String {
        switch proposal.phase {
        case .explain, .preparing:
            proposal.kind == .keepScopeKeys ? String(localized: "Reset Your Keys") : String(localized: "Reset and Start Empty")
        case .showKey: String(localized: "Your New Recovery Key")
        case .typeBack, .submitting: String(localized: "Check Your Recovery Key")
        case .done: String(localized: "Reset Asked For")
        }
    }

    @ViewBuilder
    private var explain: some View {
        Section {
            switch proposal.kind {
            case .keepScopeKeys:
                Text("Use this when you lost your recovery key and this device still has your keys. You get a new recovery key now.")
                Text("The reset waits 7 days. Any of your devices, or your old recovery key if you find it, can cancel it in that time.")
                Text("Then your other devices sign out and join again from this device. Your passwords and query history stay.")
                Text("Teammates see that your keys changed. An owner or admin of each team confirms you again before you get its passwords.")
            case .startEmpty:
                Label(String(localized: "Use this only when you have no other device and no recovery key."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("You confirm it's you with your passkey first. Then you get a new recovery key.")
                Text("The reset waits 7 days. Your other devices, or your recovery key if you find it, can cancel it in that time.")
                Text("Then TablePro Sync deletes everything you synced to it, passwords and query history included. Team libraries stay.")
                Text("Teammates see that your keys changed. An owner or admin of each team confirms you again before you get its passwords.")
            }
        } footer: {
            AccountKeysFailureText(message: proposal.failure)
        }
    }

    private var showKey: some View {
        Section {
            AccountRecoveryKeyGrid(groups: proposal.groups)
                .padding(.vertical, 8)
            Button {
                copySecret(proposal.keyText)
                copied = true
            } label: {
                Label(
                    copied ? String(localized: "Copied") : String(localized: "Copy Recovery Key"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
        } footer: {
            Text("Write it down or save it in your password manager. TablePro shows it only this once, and without it a lost device means another reset.")
        }
    }

    @ViewBuilder
    private var typeBack: some View {
        Section {
            AccountRecoveryKeyTypeBack(groups: proposal.checkedGroups, typed: Bindable(proposal).typed) {
                Task { await proposal.submit() }
            }
            .disabled(proposal.phase == .submitting)
        } header: {
            Text("Type two of its groups from what you saved, so you know the copy is right.")
        } footer: {
            AccountKeysFailureText(message: proposal.failure)
        }
        Section {
            Button(String(localized: "Show Key Again")) { proposal.showKeyAgain() }
                .disabled(proposal.phase == .submitting)
        }
    }

    private var proposed: some View {
        Section {
            if let reset = proposal.proposed {
                Text(String(
                    format: String(localized: "It can finish on %@, unless one of your devices or your old recovery key cancels it first. Come back to this device then to finish it."),
                    ResetKeysModel.date(reset.heldUntilUs).formatted(date: .long, time: .shortened)
                ))
            }
        } footer: {
            Text("Your other devices and the web portal show the reset until then.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch proposal.phase {
        case .explain, .preparing:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
                    .disabled(proposal.phase == .preparing)
            }
            ToolbarItem(placement: .confirmationAction) {
                if proposal.phase == .preparing {
                    ProgressView()
                } else {
                    Button(String(localized: "Continue")) { Task { await proposal.begin() } }
                }
            }
        case .showKey:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "I Saved It")) { proposal.continueToTypeBack() }
            }
        case .typeBack, .submitting:
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
                    .disabled(proposal.phase == .submitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                if proposal.phase == .submitting {
                    ProgressView()
                } else {
                    Button(String(localized: "Ask for Reset")) { Task { await proposal.submit() } }
                        .disabled(!proposal.canSubmit)
                }
            }
        case .done:
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) {
                    onFinish()
                    dismiss()
                }
            }
        }
    }
}
