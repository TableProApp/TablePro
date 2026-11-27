import Foundation
import TableProFFI

// What the move sheet asks for when this Mac does not hold the account's keys yet (core ADR 0055, a forced TablePro
// Sync still sets up the recovery key first; 0056, Approving a device). The sheets are M5c-1's.
enum SyncMoveKeysStep: Equatable, Identifiable {
    case setUpRecoveryKey
    case approveThisMac(request: String?)
    case openEncryptionSettings
    // No secret store, or a key state not read yet: nothing to present, only Check Again.
    case checkAgain

    var id: String {
        switch self {
        case .setUpRecoveryKey: "set-up"
        case .approveThisMac(let request): "approve-\(request ?? "")"
        case .openEncryptionSettings: "settings"
        case .checkAgain: "check"
        }
    }

    // None once this Mac holds the keys.
    static func step(for state: KeyStateInfo) -> SyncMoveKeysStep? {
        switch state {
        case .approved: nil
        case .noKeys: .setUpRecoveryKey
        case .needsApproval(let request): .approveThisMac(request: request)
        case .locked: .openEncryptionSettings
        case .noDeviceStore, .unknown: .checkAgain
        }
    }
}

// After a key sheet closes: move now, ask for approval next, or stay on the step.
enum SyncMoveKeysNext: Equatable {
    case move
    case present(SyncMoveKeysStep)
    case stay

    static func after(_ result: AccountRecoveryKeySetupResult) -> SyncMoveKeysNext {
        switch result {
        case .done: .move
        case .approvalNeeded: .present(.approveThisMac(request: nil))
        case .cancelled: .stay
        }
    }

    static func after(_ result: AccountDeviceApprovalResult) -> SyncMoveKeysNext {
        switch result {
        case .approved: .move
        case .cancelled: .stay
        }
    }
}
