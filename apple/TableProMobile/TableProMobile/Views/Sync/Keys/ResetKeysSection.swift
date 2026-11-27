import SwiftUI
import TableProFFI

// The reset rows of the encryption page: a pending reset with its wait and its Cancel or Finish, the resets that ended,
// and the way to start one. Every device shows a pending reset (core ADR 0056, Reset, Proposal).
struct ResetKeysSection: View {
    @Bindable var model: ResetKeysModel
    let copySecret: @MainActor (String) -> Void

    var body: some View {
        Section {
            if let reset = model.pending {
                pendingRow(reset)
            } else if let kind = model.offeredKind {
                Button(kind == .keepScopeKeys ? String(localized: "Reset Keys…") : String(localized: "Reset and Start Empty…"),
                       role: kind == .startEmpty ? .destructive : nil) {
                    model.proposal = ResetProposalRequest(kind: kind)
                }
                .disabled(model.work != nil)
            } else if model.isLoading {
                AccountKeysLoadingRow(label: String(localized: "Loading"))
            }

            ForEach(model.notices) { notice in
                noticeRow(notice)
            }

            if let failure = model.loadFailure {
                AccountKeysFailureText(message: failure)
                Button(String(localized: "Try Again")) { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
        } header: {
            Text("Reset")
        } footer: {
            if model.pending == nil, let kind = model.offeredKind {
                Text(kind == .keepScopeKeys
                    ? String(localized: "Lost your recovery key? Reset your keys from this device. Your passwords and query history stay.")
                    : String(localized: "No other device and no recovery key? Reset your keys and start empty."))
            }
        }
        .task { await model.load() }
        .sheet(item: $model.proposal) { request in
            ResetProposalSheet(kind: request.kind, service: model.service, stepUp: model.stepUp, copySecret: copySecret) {
                Task { await model.load() }
            }
        }
        .sheet(item: $model.cancelsWithRecoveryKey) { request in
            ResetCancelSheet(model: model, reset: request.reset)
        }
        .confirmationDialog(
            activationTitle,
            isPresented: Binding(
                get: { model.pendingActivation != nil },
                set: { if !$0 { model.pendingActivation = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingActivation
        ) { reset in
            Button(String(localized: "Finish Reset"), role: reset.kind == .startEmpty ? .destructive : nil) {
                Task { await model.activate(reset) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { reset in
            Text(activationMessage(reset))
        }
        .confirmationDialog(
            String(localized: "Cancel the reset?"),
            isPresented: Binding(
                get: { model.pendingCancel != nil },
                set: { if !$0 { model.pendingCancel = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingCancel
        ) { reset in
            Button(String(localized: "Cancel Reset"), role: .destructive) { Task { await model.cancel(reset) } }
            Button(String(localized: "Keep Waiting"), role: .cancel) {}
        } message: { reset in
            Text(reset.mine
                ? String(localized: "Your keys stay as they are, and the new recovery key you saved for this reset won't work.")
                : String(localized: "Your keys stay as they are. The device that asked for the reset can ask again."))
        }
        .alert(
            model.failure?.title ?? "",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private func noticeRow(_ notice: ResetNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: notice.text)
            } icon: {
                Image(systemName: symbol(notice.tone))
                    .foregroundStyle(tint(notice.tone))
            }
            HStack(spacing: 16) {
                if case .waitsForStepUp(let reset) = notice.kind {
                    Button(String(localized: "Confirm It's You")) { Task { await model.proposeAgain(reset) } }
                        .disabled(model.work != nil)
                }
                Button(String(localized: "Dismiss")) { Task { await model.dismiss(notice) } }
                    .disabled(model.work != nil)
            }
            .buttonStyle(.borderless)
        }
    }

    // Redrawn when the hold ends, so Finish turns on with no other change to the reset.
    private func pendingRow(_ reset: PendingResetInfo) -> some View {
        TimelineView(.explicit([ResetKeysModel.date(reset.heldUntilUs)])) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(verbatim: pendingText(reset))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: reset.mine ? "clock" : "exclamationmark.triangle.fill")
                        .foregroundStyle(reset.mine ? Color.secondary : Color.orange)
                }
                HStack(spacing: 16) {
                    if model.work == .cancelling || model.work == .activating {
                        ProgressView()
                    }
                    if model.cancelsWithoutRecoveryKey {
                        Button(String(localized: "Cancel Reset"), role: .destructive) { model.pendingCancel = reset }
                            .disabled(model.work != nil)
                    } else {
                        Button(String(localized: "Cancel with Recovery Key")) {
                            model.cancelsWithRecoveryKey = ResetCancelRequest(reset: reset)
                        }
                        .disabled(model.work != nil)
                    }
                    if reset.mine {
                        Button(String(localized: "Finish Reset")) { model.pendingActivation = reset }
                            .disabled(!model.canActivate(reset) || model.work != nil)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func pendingText(_ reset: PendingResetInfo) -> String {
        let finishes = ResetKeysModel.date(reset.heldUntilUs).formatted(date: .long, time: .shortened)
        if reset.mine {
            if model.canActivate(reset) {
                return String(localized: "Your key reset finished its wait. Finish it on this device to use your new keys.")
            }
            return String(format: String(localized: "Your key reset is waiting. You can finish it on this device from %@."), finishes)
        }
        let asked = ResetKeysModel.date(reset.takenAtUs).formatted(date: .long, time: .shortened)
        if let device = reset.proposedBy {
            return String(
                format: String(localized: "%1$@ asked to reset your keys on %2$@. It finishes on %3$@ unless you cancel it. If you didn't ask for this, cancel it now."),
                device,
                asked,
                finishes
            )
        }
        return String(
            format: String(localized: "A device asked to reset your keys on %1$@. It finishes on %2$@ unless you cancel it. If you didn't ask for this, cancel it now."),
            asked,
            finishes
        )
    }

    private var activationTitle: String {
        model.pendingActivation?.kind == .startEmpty
            ? String(localized: "Finish the reset and start empty?")
            : String(localized: "Finish the reset?")
    }

    private func activationMessage(_ reset: PendingResetInfo) -> String {
        switch reset.kind {
        case .keepScopeKeys:
            String(localized: "Your other devices sign out and join again from this device. Teammates confirm you again before you get team passwords.")
        case .startEmpty:
            String(localized: "TablePro Sync deletes everything you synced to it, passwords and query history included. This can't be undone.")
        }
    }

    private func symbol(_ tone: ResetNotice.Tone) -> String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ tone: ResetNotice.Tone) -> Color {
        switch tone {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        }
    }
}

// A device that is not certified at the current `av` cancels a reset only with the recovery key, whose identity key
// signs the cancel (core ADR 0056, Reset, Cancel).
struct ResetCancelSheet: View {
    let model: ResetKeysModel
    let reset: PendingResetInfo

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AccountRecoveryKeyField(text: $recoveryKey) {
                        Task { await cancelReset() }
                    }
                    .disabled(model.work != nil)
                } footer: {
                    Text("Type your recovery key. Hyphens and spaces don't matter.")
                }
            }
            .navigationTitle(String(localized: "Cancel the Reset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Cancel Reset")) {
                        Task { await cancelReset() }
                    }
                    .disabled(recoveryKey.trimmingCharacters(in: .whitespaces).isEmpty || model.work != nil)
                }
            }
        }
        .interactiveDismissDisabled(model.work != nil)
    }

    private func cancelReset() async {
        let key = recoveryKey
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        recoveryKey = ""
        if await model.cancel(reset, recoveryKey: key) {
            dismiss()
        }
    }
}
