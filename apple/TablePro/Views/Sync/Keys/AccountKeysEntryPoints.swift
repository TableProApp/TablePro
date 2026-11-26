//
//  AccountKeysEntryPoints.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// The key steps another flow presents as a sheet of its own, such as the move to TablePro Sync: a recovery key before
// the first personal sync (core ADR 0056, D6), or this Mac's approval when the account already has keys.

internal enum AccountRecoveryKeySetupResult: Equatable {
    case done
    case cancelled
    // Another device's setup applied first, so this Mac needs approval before it syncs.
    case approvalNeeded

    static func after(_ step: AccountRecoveryKeyFlow.Step) -> AccountRecoveryKeySetupResult {
        switch step {
        case .done: .done
        case .anotherDeviceWon: .approvalNeeded
        case .enterCurrentKey, .chooseDevices, .showKey, .typeBack: .cancelled
        }
    }
}

internal struct AccountRecoveryKeySetupSheet: View {
    @StateObject private var flow: AccountRecoveryKeyFlow
    private let environment: AccountKeysEnvironment
    private let onFinish: (AccountRecoveryKeySetupResult) -> Void

    init(environment: AccountKeysEnvironment = .live, onFinish: @escaping (AccountRecoveryKeySetupResult) -> Void) {
        self.environment = environment
        self.onFinish = onFinish
        _flow = StateObject(wrappedValue: AccountRecoveryKeyFlow(purpose: .setUp, flows: environment.flows))
    }

    var body: some View {
        AccountRecoveryKeySheet(
            flow: flow,
            copySecret: { environment.copySecret($0) },
            onAskForApproval: { finish(.approvalNeeded) },
            onClose: { finish(.after(flow.step)) }
        )
        .onDisappear { flow.discard() }
    }

    private func finish(_ result: AccountRecoveryKeySetupResult) {
        flow.discard()
        onFinish(result)
    }
}

internal enum AccountDeviceApprovalResult: Equatable {
    case approved
    case cancelled

    static func after(_ phase: AccountApprovalFlow.Phase) -> AccountDeviceApprovalResult {
        phase == .approved ? .approved : .cancelled
    }
}

// This Mac asking another device, or picking up the request it already has open. Ask Again starts a new request.
internal struct AccountDeviceApprovalSheet: View {
    private let environment: AccountKeysEnvironment
    private let openRequest: String?
    private let onFinish: (AccountDeviceApprovalResult) -> Void
    @State private var attempt = 0

    init(
        environment: AccountKeysEnvironment = .live,
        openRequest: String? = nil,
        onFinish: @escaping (AccountDeviceApprovalResult) -> Void
    ) {
        self.environment = environment
        self.openRequest = openRequest
        self.onFinish = onFinish
    }

    var body: some View {
        AccountDeviceApprovalAttempt(
            environment: environment,
            request: attempt == 0 ? openRequest : nil,
            onAskAgain: { attempt += 1 },
            onFinish: onFinish
        )
        .id(attempt)
    }
}

private struct AccountDeviceApprovalAttempt: View {
    @StateObject private var flow: AccountApprovalFlow
    private let onAskAgain: () -> Void
    private let onFinish: (AccountDeviceApprovalResult) -> Void

    init(
        environment: AccountKeysEnvironment,
        request: String?,
        onAskAgain: @escaping () -> Void,
        onFinish: @escaping (AccountDeviceApprovalResult) -> Void
    ) {
        self.onAskAgain = onAskAgain
        self.onFinish = onFinish
        _flow = StateObject(wrappedValue: AccountApprovalFlow(
            role: .newDevice,
            request: request,
            flows: environment.flows,
            clock: environment.clock
        ))
    }

    var body: some View {
        AccountApprovalSheet(
            flow: flow,
            onAskAgain: onAskAgain,
            onClose: {
                let result = AccountDeviceApprovalResult.after(flow.phase)
                flow.close()
                onFinish(result)
            }
        )
        .onDisappear { flow.close() }
    }
}
