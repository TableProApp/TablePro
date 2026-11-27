import SwiftUI
import TableProFFI

// The key step another flow presents as a sheet of its own, such as the move to TablePro Sync: a recovery key before
// the first personal sync (core ADR 0056, D6), this device's approval when the account already has keys, or the way
// back for a locked device. `onFinished` runs once, with true when this device now holds the keys; a swipe down counts
// as false.
struct KeysStepSheet: View {
    private enum Stage {
        case recoveryKey(AccountRecoveryKeyFlow)
        case approval(AccountApprovalFlow)
        case recover(AccountRecoverFlow)
        case locked(LockCauseTag)
        case unavailable
    }

    let state: KeyStateInfo
    let onFinished: @MainActor (Bool) -> Void

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var sceneDelegate: TableProSceneDelegate

    @State private var environment: AccountKeysEnvironment?
    @State private var stage: Stage?
    @State private var finished = false

    init(state: KeyStateInfo, onFinished: @escaping @MainActor (Bool) -> Void) {
        self.state = state
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            switch stage {
            case .recoveryKey(let flow)?:
                AccountRecoveryKeySheet(
                    flow: flow,
                    copySecret: { environment?.copySecret($0) },
                    onAskForApproval: {
                        flow.discard()
                        askForApproval(request: nil)
                    },
                    onClose: {
                        let done = flow.step == .done
                        flow.discard()
                        finish(done)
                    }
                )
            case .approval(let flow)?:
                AccountApprovalSheet(
                    flow: flow,
                    onAskAgain: {
                        flow.close()
                        askForApproval(request: nil)
                    },
                    onClose: {
                        let approved = flow.phase == .approved
                        flow.close()
                        finish(approved)
                    }
                )
                .id(flow.id)
            case .recover(let flow)?:
                AccountRecoverSheet(flow: flow) {
                    let done = flow.isDone
                    flow.discard()
                    finish(done)
                }
            case .locked(let cause)?:
                locked(cause)
            case .unavailable?:
                unavailable
            case nil:
                ProgressView()
            }
        }
        .onAppear(perform: begin)
        .onDisappear {
            guard !finished else { return }
            discardStage()
            finish(false)
        }
    }

    private func begin() {
        guard environment == nil else { return }
        environment = appState.keysEnvironment { [sceneDelegate] in sceneDelegate.presentationWindow }
        switch state {
        case .approved:
            finish(true)
        case .noKeys:
            guard let environment else { return }
            stage = .recoveryKey(AccountRecoveryKeyFlow(purpose: .setUp, flows: environment.flows))
        case .needsApproval(let request):
            askForApproval(request: request)
        case .locked(let cause):
            stage = .locked(cause)
        case .noDeviceStore, .unknown:
            stage = .unavailable
        }
    }

    private func askForApproval(request: String?) {
        guard let environment else { return }
        stage = .approval(AccountApprovalFlow(role: .newDevice, request: request, flows: environment.flows, clock: environment.clock))
    }

    private func useRecoveryKey() {
        guard let environment else { return }
        stage = .recover(AccountRecoverFlow(flows: environment.flows))
    }

    private func discardStage() {
        switch stage {
        case .recoveryKey(let flow)?: flow.discard()
        case .approval(let flow)?: flow.close()
        case .recover(let flow)?: flow.discard()
        case .locked?, .unavailable?, nil: break
        }
    }

    private func finish(_ holdsKeys: Bool) {
        guard !finished else { return }
        finished = true
        onFinished(holdsKeys)
    }

    private func locked(_ cause: LockCauseTag) -> some View {
        NavigationStack {
            Form {
                Section {
                    AccountKeysStatusRow(
                        symbol: "lock.trianglebadge.exclamationmark.fill",
                        tint: .orange,
                        title: AccountKeysText.lockTitle(cause),
                        message: AccountKeysText.lockMessage(cause)
                    )
                }
                if AccountKeysText.canAskForApproval(cause) || AccountKeysText.canRecover(cause) {
                    Section {
                        if AccountKeysText.canAskForApproval(cause) {
                            Button(String(localized: "Ask Another Device…")) {
                                askForApproval(request: nil)
                            }
                        }
                        if AccountKeysText.canRecover(cause) {
                            Button(String(localized: "Use Recovery Key…")) {
                                useRecoveryKey()
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "End-to-End Encryption"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { finish(false) }
                }
            }
        }
    }

    private var unavailable: some View {
        NavigationStack {
            Form {
                Section {
                    AccountKeysStatusRow(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: String(localized: "This device can't keep keys"),
                        message: state == .unknown
                            ? String(localized: "TablePro couldn't read this device's keys yet. Try again in a moment.")
                            : String(localized: "This device has no place to keep its keys, so it can't use TablePro Sync.")
                    )
                }
            }
            .navigationTitle(String(localized: "End-to-End Encryption"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { finish(false) }
                }
            }
        }
    }
}
