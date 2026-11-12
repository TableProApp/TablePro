//
//  GatedOperationFailure.swift
//  TablePro
//

import Foundation

// Cancel at the gate's confirmation is the user's own choice: it shows nothing and the sheet keeps its edits.
internal enum GatedOperationFailure: Equatable {
    case cancelledByUser
    case refused(String)
    case failed(String)

    internal init(_ error: any Error) {
        guard let gateError = error as? ExecutionGateError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch gateError {
        case .cancelledByUser:
            self = .cancelledByUser
        case .denied(let reason):
            self = .refused(reason)
        }
    }

    internal var message: String? {
        switch self {
        case .cancelledByUser: nil
        case .refused(let reason), .failed(let reason): reason
        }
    }

    // A refusal and a Cancel both stop before the first statement: nothing to report or reload.
    internal var reportsFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
