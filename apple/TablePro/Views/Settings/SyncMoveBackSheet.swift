import os
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
    @ObservedObject var moves: ProviderMoves

    @State private var step: Step = .loading
    @State private var plan: MoveBackPlanInfo?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMoveBackSheet")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Move Back to iCloud")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(step == .moving)

                primaryButton
            }
            .padding()
        }
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sync-move-back-sheet")
        .task {
            await loadPlan()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking what changed on TablePro Sync…")
                    .foregroundStyle(.secondary)
            }
        case .review(let plan):
            VStack(alignment: .leading, spacing: 10) {
                Text("This Mac downloads the latest from TablePro Sync, then syncs with iCloud again.")
                    .fixedSize(horizontal: false, vertical: true)

                if plan.icloudDeletions > 0 {
                    NoticeLabel(Self.deletionsLine(plan.icloudDeletions))
                }

                NoticeLabel(
                    String(localized: "This Mac stops syncing with devices still on TablePro Sync. Your data stays in TablePro Sync."),
                    severity: .info
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-sync-move-back-plan")
        case .moving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Moving back to iCloud…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if case .failed = step {
            Button(String(localized: "Try Again")) {
                Task { plan == nil ? await loadPlan() : await move() }
            }
            .keyboardShortcut(.defaultAction)
        } else if let plan, plan.icloudDeletions > 0 {
            // Not the default button: Return never confirms a deletion.
            Button(Self.confirmTitle(plan.icloudDeletions), role: .destructive) {
                Task { await move() }
            }
            .disabled(step == .moving)
            .accessibilityIdentifier("settings-sync-move-back-confirm")
        } else {
            Button(String(localized: "Move Back")) {
                Task { await move() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plan == nil || step == .moving)
            .accessibilityIdentifier("settings-sync-move-back-confirm")
        }
    }

    private func loadPlan() async {
        step = .loading
        do {
            let plan = try await moves.planMoveToICloud()
            self.plan = plan
            step = .review(plan)
        } catch {
            Self.logger.error("The move-back plan failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            step = .failed(ProviderMoves.message(for: error))
        }
    }

    // The count confirmed is the plan's; the engine refuses any other (core ADR 0054, Back to iCloud).
    private func move() async {
        guard let plan else { return }
        step = .moving
        do {
            try await moves.moveToICloud(confirmedDeletions: plan.icloudDeletions)
            dismiss()
        } catch {
            Self.logger.error("The move back to iCloud failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            // A plan that changed since it was shown is read again, so the person confirms the new count.
            self.plan = nil
            step = .failed(ProviderMoves.message(for: error))
        }
    }

    private static func deletionsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item deleted on TablePro Sync since this Mac moved is deleted from iCloud too, unless another device changed it there.")
            : String(
                format: String(localized: "%lld items deleted on TablePro Sync since this Mac moved are deleted from iCloud too, unless another device changed them there."),
                Int64(clamping: count)
            )
    }

    private static func confirmTitle(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "Move and Delete 1 Item")
            : String(format: String(localized: "Move and Delete %lld Items"), Int64(clamping: count))
    }
}
