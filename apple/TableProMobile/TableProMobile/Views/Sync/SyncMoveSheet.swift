import SwiftUI
import TableProFFI

// The move to TablePro Sync, or the first upload from a device that was off: what goes up and what stays, then the
// move (core ADR 0054, Moving between providers). Nothing goes up before the person confirms here.
struct SyncMoveSheet: View {
    private enum Step: Equatable {
        case loading
        case review(MovePlanInfo)
        case keys(KeyStateInfo)
        case moving
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    let moves: IOSProviderMoves
    let fromICloud: Bool
    // The sign-in the sheet opened under; the move refuses once another holds the account.
    let session: String?
    // The recovery key or approval sheet for a device without the account's keys; it reports whether they are held now.
    let keysStep: (KeyStateInfo, @escaping (Bool) -> Void) -> AnyView

    @State private var step: Step = .loading
    @State private var plan: MovePlanInfo?
    @State private var keysState: KeyStateInfo?

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(fromICloud ? String(localized: "Move to TablePro Sync") : String(localized: "Upload to TablePro Sync"))
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
        }
        .accessibilityIdentifier("sync-move-sheet")
        .task {
            await loadPlan()
        }
        .sheet(item: keysBinding) { state in
            keysStep(state.value) { held in
                keysState = nil
                guard held else { return }
                Task { await move() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking what this device uploads…")
                        .foregroundStyle(.secondary)
                }
            }
        case .review(let plan):
            review(plan)
        case .keys(let state):
            Section {
                Label(MobileSyncText.keysMessage(state), systemImage: "key")
            }
        case .moving:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(fromICloud ? String(localized: "Moving to TablePro Sync…") : String(localized: "Uploading to TablePro Sync…"))
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
    private func review(_ plan: MovePlanInfo) -> some View {
        Section {
            Text(MobileSyncText.recordsLine(plan.records))
            if plan.secretsToSeal > 0 {
                Text(MobileSyncText.secretsLine(plan.secretsToSeal))
            }
            if plan.stayingBehind > 0 {
                Text(MobileSyncText.stayingBehindLine(plan.stayingBehind))
            }
        } footer: {
            Text("This device's data goes up to your TablePro account. Passwords, other secrets and query history are end-to-end encrypted; the server can read connections and saved queries.")
        }
        .accessibilityIdentifier("sync-move-plan")
        if fromICloud {
            Section {
                Label(
                    String(localized: "This device stops syncing with devices still on iCloud. Move each of them to keep them together. TablePro's data stays in iCloud until you delete it."),
                    systemImage: "info.circle"
                )
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .keys(let state):
            Button(keysButtonTitle(state)) {
                if Self.presentsKeysSheet(state) {
                    keysState = state
                } else {
                    Task { await move() }
                }
            }
        case .failed:
            Button(String(localized: "Try Again")) {
                Task {
                    if plan == nil {
                        await loadPlan()
                    } else {
                        await move()
                    }
                }
            }
        case .loading, .review, .moving:
            Button(fromICloud ? String(localized: "Move") : String(localized: "Upload")) {
                Task { await move() }
            }
            .disabled(plan == nil || step == .moving)
            .accessibilityIdentifier("sync-move-confirm")
        }
    }

    private func keysButtonTitle(_ state: KeyStateInfo) -> String {
        switch state {
        case .noKeys: String(localized: "Set Up Recovery Key")
        case .needsApproval, .locked: String(localized: "Approve This Device")
        case .noDeviceStore, .unknown, .approved: String(localized: "Check Again")
        }
    }

    private static func presentsKeysSheet(_ state: KeyStateInfo) -> Bool {
        switch state {
        case .noKeys, .needsApproval, .locked: true
        case .noDeviceStore, .unknown, .approved: false
        }
    }

    private var keysBinding: Binding<IdentifiedKeyState?> {
        Binding(
            get: { keysState.map(IdentifiedKeyState.init) },
            set: { keysState = $0?.value }
        )
    }

    private func loadPlan() async {
        step = .loading
        do {
            let plan = try await moves.planMoveToService()
            self.plan = plan
            step = .review(plan)
        } catch {
            MobileSyncText.log("The move plan failed", error)
            step = .failed(MobileSyncText.message(for: error))
        }
    }

    private func move() async {
        step = .moving
        do {
            switch try await moves.moveToService(confirmedUnder: session) {
            case .moved:
                dismiss()
            case .needsKeys(let state):
                step = .keys(state)
            }
        } catch {
            MobileSyncText.log("The move to TablePro Sync failed", error)
            step = .failed(MobileSyncText.message(for: error))
        }
    }
}

// A sheet item for the key state, which the core's enum does not make identifiable.
struct IdentifiedKeyState: Identifiable {
    let value: KeyStateInfo

    var id: String {
        switch value {
        case .noDeviceStore: "no-device-store"
        case .unknown: "unknown"
        case .noKeys: "no-keys"
        case .needsApproval(let request): "needs-approval-\(request ?? "")"
        case .approved(_, let keyDevice): "approved-\(keyDevice)"
        case .locked: "locked"
        }
    }
}
