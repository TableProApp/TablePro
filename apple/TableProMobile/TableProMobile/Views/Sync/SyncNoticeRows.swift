import SwiftUI
import TableProFFI

// A state stated at length at the top of the Sync page: its symbol, a title, what it means and what can be done.
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
                }
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            actions()
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-notice")
    }
}

// TablePro Sync's own states: an upload or a move back that waits for the person, a sign-in it needs, uploads paused
// past the license's grace, and the grace itself.
struct SyncServiceNoticeRow: View {
    let notice: MobileSyncServiceNotice
    let review: () -> Void

    var body: some View {
        switch notice {
        case .awaitsUpload:
            SyncNoticeRow(
                symbolName: "arrow.up.circle",
                title: String(localized: "Your Organization Uses TablePro Sync"),
                message: String(localized: "This device starts syncing with TablePro Sync once you review what it uploads."),
                tint: .accentColor
            ) {
                Button(String(localized: "Review Upload"), action: review)
                    .accessibilityIdentifier("sync-review-upload")
            }
        case .awaitsMoveBack:
            SyncNoticeRow(
                symbolName: "arrow.uturn.backward.circle",
                title: String(localized: "Your Organization Uses iCloud"),
                message: String(localized: "This device goes back to iCloud once you review what the move deletes there."),
                tint: .accentColor
            ) {
                Button(String(localized: "Review Move Back"), action: review)
                    .accessibilityIdentifier("sync-review-move-back")
            }
        case .signedOut:
            SyncNoticeRow(
                symbolName: "person.crop.circle.badge.exclamationmark",
                title: String(localized: "Signed Out of TablePro"),
                message: String(localized: "Sign in to your TablePro account in Settings to keep syncing. Your data stays on this device meanwhile.")
            ) {
                EmptyView()
            }
        case .pullOnly(let selfHosted):
            SyncNoticeRow(
                symbolName: "arrow.down.circle",
                title: String(localized: "Uploads Paused"),
                message: selfHosted
                    ? String(localized: "Your server's license has expired. This device still downloads changes and keeps its own until your administrator renews it.")
                    : String(localized: "Your plan no longer includes TablePro Sync. This device still downloads changes and keeps its own until you renew.")
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

// Another Apple Account or TablePro account: nothing goes up to it until the person picks (core ADR 0054, Another
// account or server; 0066, Rules).
struct SyncNewIdentityNotice: View {
    let moves: IOSProviderMoves

    @State private var isChoosing = false
    @State private var problem: String?
    // The prompt's account, which the answer names back; nothing is offered before it is read.
    @State private var plan: NewIdentityPlanInfo?

    var body: some View {
        SyncNoticeRow(
            symbolName: "person.crop.circle.badge.questionmark",
            title: String(localized: "Signed In to Another Account"),
            message: problem ?? Self.message(plan)
        ) {
            HStack {
                Button(String(localized: "Start Empty")) {
                    choose(.startEmpty)
                }
                .disabled(isChoosing || plan == nil)
                .accessibilityIdentifier("sync-start-empty")
                Spacer()
                Button(String(localized: "Move My Data")) {
                    choose(.moveMyData)
                }
                .disabled(isChoosing || plan == nil)
                .accessibilityIdentifier("sync-move-my-data")
            }
        }
        .task { await readPlan() }
    }

    static func message(_ plan: NewIdentityPlanInfo?) -> String {
        let choice = String(
            localized: "Move this device's data into the account it now syncs with, or start empty with what that account already holds."
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
            MobileSyncText.log("The plan for the new account did not read", error)
            problem = MobileSyncText.message(for: error)
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
                MobileSyncText.log("The choice for the new account failed", error)
                problem = MobileSyncText.message(for: error)
                // An answer for an account that changed meanwhile asks again with the new one.
                self.plan = nil
                await readPlan()
            }
        }
    }
}
