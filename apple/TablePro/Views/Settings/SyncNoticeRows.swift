import os
import SwiftUI
import TableProFFI

// A state stated at length at the top of the Sync pane: its symbol, a title, what it means and what can be done.
struct SyncNoticeRow<Actions: View>: View {
    let symbolName: String
    let title: String
    let message: String
    var tint: Color = .orange
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sync-notice")
    }
}

// TablePro Sync's own states: an upload that waits for the person, uploads paused past the license's grace, and the
// grace itself.
struct SyncServiceNoticeRow: View {
    let notice: SyncServiceNotice
    let review: () -> Void

    var body: some View {
        switch notice {
        case .awaitsUpload:
            SyncNoticeRow(
                symbolName: "arrow.up.circle",
                title: String(localized: "Your Organization Uses TablePro Sync"),
                message: String(localized: "This Mac starts syncing with TablePro Sync once you review what it uploads."),
                tint: .accentColor
            ) {
                Button(String(localized: "Review Upload…"), action: review)
                    .accessibilityIdentifier("settings-sync-review-upload")
            }
        case .awaitsMoveBack:
            SyncNoticeRow(
                symbolName: "arrow.uturn.backward.circle",
                title: String(localized: "Your Organization Uses iCloud"),
                message: String(localized: "This Mac goes back to iCloud once you review what the move deletes there."),
                tint: .accentColor
            ) {
                Button(String(localized: "Review Move Back…"), action: review)
                    .accessibilityIdentifier("settings-sync-review-move-back")
            }
        case .pullOnly(let selfHosted):
            SyncNoticeRow(
                symbolName: "arrow.down.circle",
                title: String(localized: "Uploads Paused"),
                message: selfHosted
                    ? String(localized: "Your server's license has expired. This Mac still downloads changes and keeps its own until your administrator renews it.")
                    : String(localized: "Your plan no longer includes TablePro Sync. This Mac still downloads changes and keeps its own until you renew.")
            ) {
                EmptyView()
            }
        case .grace(let until):
            SyncNoticeRow(
                symbolName: "clock",
                title: String(localized: "Your Server's License Has Expired"),
                message: Self.graceMessage(until),
                tint: .secondary
            ) {
                EmptyView()
            }
        }
    }

    private static func graceMessage(_ until: Date?) -> String {
        guard let until else {
            return String(localized: "Ask your administrator to renew it. TablePro Sync stops taking changes once the grace period ends.")
        }
        return String(
            format: String(localized: "TablePro Sync takes changes until %@. Ask your administrator to renew it."),
            until.formatted(date: .abbreviated, time: .omitted)
        )
    }
}

// Another Apple Account or TablePro account: nothing goes up to it until the person picks (core ADR 0054, Another account
// or server; 0066, Rules).
struct SyncNewIdentityNotice: View {
    @ObservedObject var moves: ProviderMoves

    @State private var isChoosing = false
    @State private var problem: String?
    // The prompt's account, which the answer names back; nothing is offered before it is read.
    @State private var plan: NewIdentityPlanInfo?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncNewIdentityNotice")

    var body: some View {
        SyncNoticeRow(
            symbolName: "person.crop.circle.badge.questionmark",
            title: String(localized: "Signed In to Another Account"),
            message: problem ?? Self.message(plan)
        ) {
            Button(String(localized: "Start Empty")) {
                choose(.startEmpty)
            }
            .disabled(isChoosing || plan == nil)
            .accessibilityIdentifier("settings-sync-start-empty")

            Button(String(localized: "Move My Data")) {
                choose(.moveMyData)
            }
            .disabled(isChoosing || plan == nil)
            .accessibilityIdentifier("settings-sync-move-my-data")
        }
        .task { await readPlan() }
    }

    static func message(_ plan: NewIdentityPlanInfo?) -> String {
        let choice = String(
            localized: "Move this Mac's data into the account it now syncs with, or start empty with what that account already holds."
        )
        guard let unsent = plan?.unsent, unsent > 0 else { return choice }
        let held = unsent == 1
            ? String(localized: "1 change here was never uploaded to the earlier account.")
            : String(format: String(localized: "%lld changes here were never uploaded to the earlier account."), Int64(clamping: unsent))
        return choice + " " + held
    }

    private func readPlan() async {
        do {
            plan = try await moves.planNewIdentity()
        } catch {
            Self.logger.error("The plan for the new account did not read: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            problem = ProviderMoves.message(for: error)
        }
    }

    private func choose(_ choice: NewIdentityChoiceTag) {
        guard let plan else { return }
        isChoosing = true
        problem = nil
        Task {
            defer { isChoosing = false }
            do {
                try await moves.chooseForNewIdentity(choice, for: plan)
            } catch {
                Self.logger.error("The choice for the new account failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
                problem = ProviderMoves.message(for: error)
                // An answer for an account that changed meanwhile asks again with the new one.
                self.plan = nil
                await readPlan()
            }
        }
    }
}
