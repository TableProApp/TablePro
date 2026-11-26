//
//  ResetKeysSection.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// The reset rows of the account's keys page: a pending reset with its wait and its Cancel or Finish, the resets that
// ended, and the way to start one. Every device shows a pending reset (core ADR 0056, Reset, Proposal).
internal struct ResetKeysSection: View {
    @StateObject private var model: ResetKeysModel

    init() {
        self.init(model: ResetKeysModel())
    }

    init(model: @autoclosure @escaping () -> ResetKeysModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Section {
            ResetKeysRows(model: model)
        } header: {
            Text("Reset")
        }
    }
}

private struct ResetKeysRows: View {
    @ObservedObject var model: ResetKeysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reset = model.pending {
                pendingRow(reset)
            } else if let kind = model.offeredKind {
                startRow(kind)
            } else if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Loading")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(model.endedNotices) { notice in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    NoticeLabel(notice.text, severity: notice.state == .active ? .success : .info)
                    Spacer(minLength: 12)
                    Button(String(localized: "Dismiss")) { Task { await model.dismiss(notice) } }
                        .fixedSize()
                        .disabled(model.work != nil)
                }
            }

            if let failure = model.loadFailure {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NoticeLabel(failure)
                    Spacer(minLength: 12)
                    Button(String(localized: "Try Again")) { Task { await model.load() } }
                        .fixedSize()
                        .disabled(model.isLoading)
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $model.proposal) { request in
            ResetProposalSheet(kind: request.kind, service: model.service, stepUp: model.stepUp) {
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

    @ViewBuilder
    private func startRow(_ kind: ResetKindTag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(kind == .keepScopeKeys
                ? String(localized: "Lost your recovery key? Reset your keys from this Mac. Your passwords and query history stay.")
                : String(localized: "No other device and no recovery key? Reset your keys and start empty."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(kind == .keepScopeKeys ? String(localized: "Reset Keys…") : String(localized: "Reset and Start Empty…")) {
                model.proposal = ResetProposalRequest(kind: kind)
            }
            .fixedSize()
            .disabled(model.work != nil)
        }
    }

    // Redrawn when the hold ends, so Finish turns on with no other change to the reset.
    private func pendingRow(_ reset: PendingResetInfo) -> some View {
        TimelineView(.explicit([ResetKeysModel.date(reset.heldUntilUs)])) { _ in
            pendingContent(reset)
        }
    }

    private func pendingContent(_ reset: PendingResetInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeLabel(pendingText(reset), severity: reset.mine ? .info : .warning)
            HStack(spacing: 8) {
                Spacer()
                if model.work == .cancelling || model.work == .activating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Working"))
                }
                if model.cancelsWithoutRecoveryKey {
                    Button(String(localized: "Cancel Reset…")) { model.pendingCancel = reset }
                        .disabled(model.work != nil)
                } else {
                    Button(String(localized: "Cancel with Recovery Key…")) { model.cancelsWithRecoveryKey = ResetCancelRequest(reset: reset) }
                        .disabled(model.work != nil)
                }
                if reset.mine {
                    Button(String(localized: "Finish Reset…")) { model.pendingActivation = reset }
                        .disabled(!model.canActivate(reset) || model.work != nil)
                }
            }
        }
    }

    private func pendingText(_ reset: PendingResetInfo) -> String {
        let finishes = ResetKeysModel.date(reset.heldUntilUs).formatted(date: .long, time: .shortened)
        if reset.mine {
            if model.canActivate(reset) {
                return String(localized: "Your key reset finished its wait. Finish it on this Mac to use your new keys.")
            }
            return String(format: String(localized: "Your key reset is waiting. You can finish it on this Mac from %@."), finishes)
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
            String(localized: "Your other devices sign out and join again from this Mac. Teammates confirm you again before you get team passwords.")
        case .startEmpty:
            String(localized: "TablePro Sync deletes everything you synced to it, passwords and query history included. This can't be undone.")
        }
    }
}
