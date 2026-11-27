import SwiftUI
import TableProFFI

// The move back to iCloud. A server can write deletions for any record it holds, so the sheet says how many iCloud
// records the move deletes and nothing is deleted before the person confirms that count (core ADR 0054, Back to iCloud).
struct SyncMoveBackSheet: View {
    private enum Step: Equatable {
        case loading
        case review(MoveBackPlanInfo)
        case moving
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    let moves: IOSProviderMoves
    // The sign-in the sheet opened under; the move refuses once another holds the account.
    let session: String?

    @State private var step: Step = .loading
    @State private var plan: MoveBackPlanInfo?
    @State private var confirmsDeletions = false

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(String(localized: "Move Back to iCloud"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                    .disabled(step == .moving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    primaryButton
                }
            }
            .interactiveDismissDisabled(step == .moving)
            .confirmationDialog(
                String(localized: "Delete from iCloud?"),
                isPresented: $confirmsDeletions,
                titleVisibility: .visible,
                presenting: plan
            ) { plan in
                Button(Self.confirmTitle(plan.icloudDeletions), role: .destructive) {
                    Task { await move() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: { plan in
                Text(MobileSyncText.iCloudDeletionsLine(plan.icloudDeletions))
            }
        }
        .accessibilityIdentifier("sync-move-back-sheet")
        .task {
            await loadPlan()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking what changed on TablePro Sync…")
                        .foregroundStyle(.secondary)
                }
            }
        case .review(let plan):
            Section {
                Text("This device downloads the latest from TablePro Sync, then syncs with iCloud again.")
                if plan.icloudDeletions > 0 {
                    Label(MobileSyncText.iCloudDeletionsLine(plan.icloudDeletions), systemImage: "trash")
                }
            } footer: {
                Text("This device stops syncing with devices still on TablePro Sync. Your data stays in TablePro Sync.")
            }
            .accessibilityIdentifier("sync-move-back-plan")
        case .moving:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Moving back to iCloud…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if case .failed = step {
            Button(String(localized: "Try Again")) {
                Task {
                    if plan == nil {
                        await loadPlan()
                    } else {
                        await move()
                    }
                }
            }
        } else {
            // A move that deletes on iCloud asks once more, naming the count.
            Button(String(localized: "Move Back")) {
                if let plan, plan.icloudDeletions > 0 {
                    confirmsDeletions = true
                } else {
                    Task { await move() }
                }
            }
            .disabled(plan == nil || step == .moving)
            .accessibilityIdentifier("sync-move-back-confirm")
        }
    }

    private func loadPlan() async {
        step = .loading
        do {
            let plan = try await moves.planMoveToICloud()
            self.plan = plan
            step = .review(plan)
        } catch {
            MobileSyncText.log("The move-back plan failed", error)
            step = .failed(MobileSyncText.message(for: error))
        }
    }

    // The count confirmed is the plan's; the engine refuses any other (core ADR 0054, Back to iCloud).
    private func move() async {
        guard let plan else { return }
        step = .moving
        do {
            try await moves.moveToICloud(confirmedDeletions: plan.icloudDeletions, confirmedUnder: session)
            dismiss()
        } catch {
            MobileSyncText.log("The move back to iCloud failed", error)
            // A plan that changed since it was shown is read again, so the person confirms the new count.
            self.plan = nil
            step = .failed(MobileSyncText.message(for: error))
        }
    }

    private static func confirmTitle(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "Move and Delete 1 Item")
            : String(format: String(localized: "Move and Delete %lld Items"), Int64(clamping: count))
    }
}
