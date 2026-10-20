import SwiftUI
import TableProModels

extension View {
    func transactionAccessory(for coordinator: ConnectionCoordinator) -> some View {
        modifier(TransactionAccessoryPlacement(coordinator: coordinator))
    }

    func transactionBar(for coordinator: ConnectionCoordinator, isEnabled: Bool = true) -> some View {
        modifier(TransactionBarPlacement(coordinator: coordinator, isEnabled: isEnabled))
    }

    // A table row is a copy of the grid page, which reloads after a Roll Back; an edit in progress finishes first.
    func leavesAfterRollBack(of coordinator: ConnectionCoordinator, isTableRow: Bool, isEditing: Bool) -> some View {
        modifier(RollBackDismissal(coordinator: coordinator, isTableRow: isTableRow, isEditing: isEditing))
    }
}

private struct RollBackDismissal: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let coordinator: ConnectionCoordinator
    let isTableRow: Bool
    let isEditing: Bool

    @State private var rolledBack = false

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.sessionTransactions.rollBackCount(for: coordinator.connection.id)) {
                guard isTableRow else { return }
                rolledBack = true
                if !isEditing { dismiss() }
            }
            .onChange(of: isEditing) { _, editing in
                if !editing, rolledBack { dismiss() }
            }
    }
}

// The 26.0 tabViewBottomAccessory(content:) overload is avoided: it draws an empty capsule while nothing is held.
private struct TransactionAccessoryPlacement: ViewModifier {
    @Environment(AppState.self) private var appState
    let coordinator: ConnectionCoordinator

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: coordinator.transactionHold != nil) {
                TransactionAccessory(coordinator: coordinator, transactions: appState.sessionTransactions)
            }
        } else {
            content
        }
    }
}

// Goes on each screen, outside its own bar: on a navigation container it covers a pushed screen's last rows.
private struct TransactionBarPlacement: ViewModifier {
    @Environment(AppState.self) private var appState
    let coordinator: ConnectionCoordinator
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
        } else {
            content.bottomSafeAreaBar {
                if isEnabled, coordinator.transactionHold != nil {
                    TransactionIndicatorView(coordinator: coordinator, transactions: appState.sessionTransactions)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

@available(iOS 26.1, *)
private struct TransactionAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let coordinator: ConnectionCoordinator
    let transactions: SessionTransactionMonitor

    var body: some View {
        TransactionIndicatorView(
            coordinator: coordinator,
            transactions: transactions,
            prefersCompact: placement == .inline
        )
        .padding(.horizontal, 16)
    }
}

struct TransactionIndicatorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let coordinator: ConnectionCoordinator
    let transactions: SessionTransactionMonitor
    var prefersCompact = false

    // What each dialog was opened for, so a swapped session or newer work refuses rather than acts.
    @State private var rollBackTarget: SessionTransactionMonitor.HoldToken?
    @State private var commitTarget: SessionTransactionMonitor.HoldToken?

    private var connectionId: UUID { coordinator.connection.id }
    private var isBusy: Bool { transactions.isBusy(connectionId) }
    private var isCompact: Bool { prefersCompact || dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        if let hold = coordinator.transactionHold {
            bar(TransactionIndicatorContent(
                isAborted: hold == .aborted,
                connectionName: coordinator.displayName,
                activeDatabase: coordinator.activeDatabase,
                switchesDatabases: coordinator.supportsDatabaseSwitching,
                safeModeLevel: coordinator.connection.safeModeLevel
            ))
        }
    }

    // A button title never truncates: where the titles do not fit, as on an iPhone in portrait, the buttons show symbols.
    private func bar(_ content: TransactionIndicatorContent) -> some View {
        ViewThatFits(in: .horizontal) {
            row(content, iconOnly: isCompact)
            row(content, iconOnly: true)
        }
        .confirmationDialog(
            String(localized: "Roll Back the Transaction?"),
            isPresented: isPresenting($rollBackTarget),
            titleVisibility: .visible,
            presenting: rollBackTarget
        ) { target in
            Button(String(localized: "Roll Back"), role: .destructive) {
                perform { try await coordinator.rollBackTransaction(as: target) }
            }
        } message: { _ in
            Text("Its uncommitted changes are discarded.")
        }
        .confirmationDialog(
            String(localized: "Commit the Transaction?"),
            isPresented: isPresenting($commitTarget),
            titleVisibility: .visible,
            presenting: commitTarget
        ) { target in
            Button(String(localized: "Commit")) {
                // The level can change on another device while the dialog is up.
                guard !coordinator.connection.safeModeLevel.blocksWrites else { return }
                perform { try await coordinator.commitTransaction(as: target) }
            }
        } message: { _ in
            Text("Its changes are saved to the database.")
        }
    }

    private func row(_ content: TransactionIndicatorContent, iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            summary(content)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                rollBackButton
                if content.commit != .hidden {
                    commitButton(content.commit)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .modifier(TransactionButtonLabels(isCompact: iconOnly))
            .disabled(isBusy)
        }
    }

    private func summary(_ content: TransactionIndicatorContent) -> some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: content.symbolName)
                    .foregroundStyle(content.isAborted ? Color.red : Color.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                if !isCompact {
                    Text(content.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }

    // Never gated by Safe Mode: Roll Back is the one way out that keeps nothing.
    private var rollBackButton: some View {
        Button(role: .destructive) {
            rollBackTarget = coordinator.transactionToken
        } label: {
            Label("Roll Back", systemImage: TransactionIndicatorContent.rollBackSymbolName)
        }
    }

    private func commitButton(_ offer: TransactionIndicatorContent.CommitOffer) -> some View {
        Button {
            guard let target = coordinator.transactionToken else { return }
            if offer == .asksFirst {
                commitTarget = target
            } else {
                perform { try await coordinator.commitTransaction(as: target) }
            }
        } label: {
            Label("Commit", systemImage: TransactionIndicatorContent.commitSymbolName)
        }
    }

    private func isPresenting(_ target: Binding<SessionTransactionMonitor.HoldToken?>) -> Binding<Bool> {
        Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } }
        )
    }

    // The coordinator's alert lives on the TabView, so it outlasts this bar when a failure ends the hold.
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch is CancellationError {
                return
            } catch {
                guard !coordinator.showFailureAlert else { return }
                coordinator.failureAlertMessage = error.localizedDescription
                coordinator.showFailureAlert = true
            }
        }
    }
}

private struct TransactionButtonLabels: ViewModifier {
    let isCompact: Bool

    func body(content: Content) -> some View {
        if isCompact {
            content.labelStyle(.iconOnly)
        } else {
            content.labelStyle(.titleOnly)
        }
    }
}
