//
//  AccountKeysModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI
import TableProLogRedaction

// Settings > Account > End-to-End Encryption: this Mac's key state, the devices holding the account's keys, the
// requests waiting for approval, and the sheets of each flow (core ADR 0056, Approving a device and Account flows).
@MainActor
internal final class AccountKeysModel: ObservableObject {
    enum Sheet: Identifiable {
        case recoveryKey(AccountRecoveryKeyFlow)
        case approval(AccountApprovalFlow)
        case removal(AccountRemovalFlow)
        case recover(AccountRecoverFlow)

        var id: UUID {
            switch self {
            case .recoveryKey(let flow): flow.id
            case .approval(let flow): flow.id
            case .removal(let flow): flow.id
            case .recover(let flow): flow.id
            }
        }
    }

    // How often an approved Mac reads the requests waiting for it while the page is on screen.
    static let requestsInterval: Duration = .seconds(5)

    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountKeys")

    @Published private(set) var state = AccountRemote<KeyStateInfo>()
    @Published private(set) var devices = AccountRemote<[AccountDeviceInfo]>()
    @Published private(set) var requests: [ApprovalRequestInfo] = []
    // The key device whose row is being removed.
    @Published private(set) var removing: String?
    @Published var sheet: Sheet?
    @Published var pendingRemoval: AccountDeviceInfo?
    @Published var actionFailure: AccountActionFailure?

    let environment: AccountKeysEnvironment
    private var changes: Set<AnyCancellable> = []
    private var reloading: Task<Void, Never>?
    private var reloadsAgain = false
    // Bumped when the account signs in or out, so a read still out for the old one lands nowhere.
    private var generation = 0

    init(environment: AccountKeysEnvironment) {
        self.environment = environment
        environment.keyChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &changes)
        environment.accountChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.forgetAccount()
                    await self?.reload()
                }
            }
            .store(in: &changes)
    }

    var isApproved: Bool {
        if case .approved? = state.value { return true }
        return false
    }

    // Devices first by this Mac, then by when each joined, oldest first.
    var sortedDevices: [AccountDeviceInfo] {
        (devices.value ?? []).sorted { lhs, rhs in
            if lhs.thisDevice != rhs.thisDevice { return lhs.thisDevice }
            return (lhs.addedAtUs ?? .max) < (rhs.addedAtUs ?? .max)
        }
    }

    // One read at a time; a change that lands during one reads again once it ends. A failed read keeps what was shown.
    func reload() async {
        if let reloading {
            reloadsAgain = true
            await reloading.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                reloadsAgain = false
                await read()
            } while reloadsAgain
        }
        reloading = task
        await task.value
        reloading = nil
    }

    // While the page is on screen. Cancelled with the page's task.
    func watchRequests() async {
        while !Task.isCancelled {
            do {
                try await environment.clock.sleep(for: Self.requestsInterval)
            } catch {
                return
            }
            guard isApproved, sheet == nil else { continue }
            await readRequests()
        }
    }

    // MARK: - Flows

    func setUpRecoveryKey() {
        sheet = .recoveryKey(AccountRecoveryKeyFlow(purpose: .setUp, flows: environment.flows))
    }

    func replaceRecoveryKey() {
        sheet = .recoveryKey(AccountRecoveryKeyFlow(purpose: .replace, flows: environment.flows))
    }

    // A new request, or the one this Mac already has open.
    func askForApproval() {
        var open: String?
        if case .needsApproval(let request)? = state.value {
            open = request
        }
        sheet = .approval(AccountApprovalFlow(role: .newDevice, request: open, flows: environment.flows, clock: environment.clock))
    }

    func approve(_ request: ApprovalRequestInfo) {
        sheet = .approval(AccountApprovalFlow(role: .approver(request), flows: environment.flows, clock: environment.clock))
    }

    func useRecoveryKey() {
        sheet = .recover(AccountRecoverFlow(flows: environment.flows))
    }

    // The row goes first, behind a fresh step-up (core ADR 0051, Step-up); then the recovery key and the review. A
    // device whose row is already gone goes straight to the recovery key.
    func remove(_ device: AccountDeviceInfo) async {
        pendingRemoval = nil
        let started = generation
        if let row = device.device {
            removing = device.keyDevice
            defer { removing = nil }
            do {
                try await environment.stepUp.run {
                    guard started == self.generation else { throw CancellationError() }
                    try await self.environment.flows().removeDeviceRow(device: row)
                }
            } catch {
                // The account changed while the row was going: nothing of the old one is shown.
                guard started == generation else { return }
                switch StepUpRetry.failure(error) {
                case .canceled?:
                    return
                case .failed(let message)?:
                    report(device, message)
                    return
                case nil:
                    report(device, AccountKeysText.message(for: error))
                    return
                }
            }
        }
        guard started == generation else { return }
        sheet = .removal(AccountRemovalFlow(
            lost: device,
            flows: environment.flows,
            portal: environment.portal,
            openURL: environment.openURL
        ))
        await readDevices()
    }

    // Genesis lost to another device's: this Mac asks that one instead.
    func askAfterAnotherDeviceWon() {
        closeSheet()
        askAgain()
    }

    func closeSheet() {
        guard let open = sheet else { return }
        sheet = nil
        sheetClosed(open)
    }

    // Starts again after a request that ended, so it never reuses the one that did.
    func askAgain() {
        closeSheet()
        sheet = .approval(AccountApprovalFlow(role: .newDevice, flows: environment.flows, clock: environment.clock))
    }

    // The sheet closed, by Done, Cancel or Escape: its flow drops what it held, and the page reads again.
    private func sheetClosed(_ closed: Sheet) {
        switch closed {
        case .recoveryKey(let flow): flow.discard()
        case .approval(let flow): flow.close()
        case .removal(let flow): flow.discard()
        case .recover(let flow): flow.discard()
        }
        Task { await reload() }
    }

    // MARK: - Reads

    // Another account's keys, devices and requests are never shown under this one.
    private func forgetAccount() {
        generation += 1
        closeSheet()
        pendingRemoval = nil
        actionFailure = nil
        state = AccountRemote()
        devices = AccountRemote()
        requests = []
    }

    private func read() async {
        let started = generation
        state.isLoading = true
        do {
            let value = try await environment.flows().keyState()
            guard started == generation else { return }
            state = AccountRemote(value: value)
        } catch {
            guard started == generation else { return }
            state.isLoading = false
            state.failure = AccountKeysText.message(for: error)
            return
        }
        if isApproved {
            await readDevices()
            await readRequests()
        } else {
            devices = AccountRemote()
            requests = []
        }
    }

    private func readDevices() async {
        let started = generation
        devices.isLoading = true
        do {
            let value = try await environment.flows().accountDevices()
            guard started == generation else { return }
            devices = AccountRemote(value: value)
        } catch {
            guard started == generation else { return }
            devices.isLoading = false
            devices.failure = AccountKeysText.message(for: error)
        }
    }

    private func readRequests() async {
        let started = generation
        do {
            let value = try await environment.flows().approvalRequests()
            guard started == generation else { return }
            requests = value
        } catch {
            Self.logger.notice(
                "Approval requests did not load: \(LogRedaction.publicDescription(of: error), privacy: .public)"
            )
        }
    }

    private func report(_ device: AccountDeviceInfo, _ message: String) {
        actionFailure = AccountActionFailure(
            title: String(format: String(localized: "Could not remove “%@”"), AccountKeysText.deviceName(device.name)),
            message: message
        )
    }
}
