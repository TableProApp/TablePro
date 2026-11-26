import os
import SwiftUI
import TableProFFI

// The move to TablePro Sync, or the first upload from a Mac that was off: what goes up and what stays, then the move
// (core ADR 0054, Moving between providers). Nothing goes up before the person confirms here.
struct SyncMoveSheet: View {
    private enum Step: Equatable {
        case loading
        case review(MovePlanInfo)
        case keys(KeyStateInfo)
        case moving
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var moves: ProviderMoves
    let fromICloud: Bool

    @State private var step: Step = .loading
    @State private var plan: MovePlanInfo?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMoveSheet")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(fromICloud ? String(localized: "Move to TablePro Sync") : String(localized: "Upload to TablePro Sync"))
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
        .accessibilityIdentifier("settings-sync-move-sheet")
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
                Text("Checking what this Mac uploads…")
                    .foregroundStyle(.secondary)
            }
        case .review(let plan):
            review(plan)
        case .keys(let state):
            NoticeLabel(Self.keysMessage(state), severity: .info)
        case .moving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(fromICloud ? String(localized: "Moving to TablePro Sync…") : String(localized: "Uploading to TablePro Sync…"))
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        }
    }

    private func review(_ plan: MovePlanInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac's data goes up to your TablePro account, end-to-end encrypted.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: Self.recordsLine(plan.records))
                if plan.secretsToSeal > 0 {
                    Text(verbatim: Self.secretsLine(plan.secretsToSeal))
                }
                if plan.stayingBehind > 0 {
                    Text(verbatim: Self.stayingBehindLine(plan.stayingBehind))
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if fromICloud {
                NoticeLabel(
                    String(
                        localized: """
                            This Mac stops syncing with devices still on iCloud. Move each of them to keep them \
                            together. TablePro's data stays in iCloud until you delete it.
                            """
                    )
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sync-move-plan")
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .keys:
            Button(String(localized: "Check Again")) {
                Task { await move() }
            }
            .keyboardShortcut(.defaultAction)
        case .failed:
            Button(String(localized: "Try Again")) {
                Task { plan == nil ? await loadPlan() : await move() }
            }
            .keyboardShortcut(.defaultAction)
        case .loading, .review, .moving:
            Button(fromICloud ? String(localized: "Move to TablePro Sync") : String(localized: "Upload")) {
                Task { await move() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plan == nil || step == .moving)
            .accessibilityIdentifier("settings-sync-move-confirm")
        }
    }

    private func loadPlan() async {
        step = .loading
        do {
            let plan = try await moves.planMoveToService()
            self.plan = plan
            step = .review(plan)
        } catch {
            Self.logger.error("The move plan failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            step = .failed(ProviderMoves.message(for: error))
        }
    }

    private func move() async {
        step = .moving
        do {
            switch try await moves.moveToService() {
            case .moved:
                dismiss()
            case .needsKeys(let state):
                step = .keys(state)
            }
        } catch {
            Self.logger.error("The move to TablePro Sync failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            step = .failed(ProviderMoves.message(for: error))
        }
    }

    // Two keys rather than inflection markup, which reads verbatim when a catalog lacks it.
    private static func recordsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item goes up.")
            : String(format: String(localized: "%lld items go up."), Int64(clamping: count))
    }

    private static func secretsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 password is encrypted for TablePro Sync, and this Mac keeps its own copy.")
            : String(
                format: String(localized: "%lld passwords are encrypted for TablePro Sync, and this Mac keeps its own copy of each."),
                Int64(clamping: count)
            )
    }

    private static func stayingBehindLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item stays on this Mac: a Local only or sample connection, or a category you turned off.")
            : String(
                format: String(localized: "%lld items stay on this Mac: Local only and sample connections, and categories you turned off."),
                Int64(clamping: count)
            )
    }

    // Recovery key setup and device approval come before the first upload (core ADR 0055, PersonalSyncProvider).
    private static func keysMessage(_ state: KeyStateInfo) -> String {
        switch state {
        case .needsApproval:
            String(localized: "Approve this Mac from another device signed in to your account, or use your recovery key, then check again.")
        case .locked:
            String(localized: "This Mac can no longer read your account's keys. Approve it again from another device, then check again.")
        case .noDeviceStore:
            String(localized: "This Mac has no place to keep its device keys, so it cannot use TablePro Sync.")
        case .noKeys, .unknown, .approved:
            String(localized: "Set up a recovery key for your account before this Mac uploads, then check again.")
        }
    }
}
