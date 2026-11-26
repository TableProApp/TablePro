//
//  StepUpRetry.swift
//  TablePro
//

import AppKit
import Foundation
import TableProFFI

// RFC 9470's challenge as a call was answered with it: `sync.step_up_required` from a key flow, or
// `account.step_up_required` from the account (core ADR 0051, Keys on the wire, Step-up).
nonisolated internal struct StepUpChallenge: Equatable, Sendable {
    let acrValues: [String]
    let maxAgeSecs: UInt64?

    init(acrValues: [String], maxAgeSecs: UInt64?) {
        self.acrValues = acrValues
        self.maxAgeSecs = maxAgeSecs
    }

    init?(_ error: any Error) {
        guard case .Failed(let info)? = error as? CoreError else { return nil }
        if case .stepUp(let acrValues, let maxAgeSecs)? = info.sync {
            self.init(acrValues: acrValues, maxAgeSecs: maxAgeSecs)
        } else if let challenge = info.stepUp {
            self.init(acrValues: challenge.acrValues, maxAgeSecs: challenge.maxAgeSecs)
        } else {
            return nil
        }
    }
}

internal enum StepUpFailure: Equatable {
    // The person closed the sign-in page.
    case canceled
    case failed(message: String)
}

// A call that may need a fresh step-up. On a challenge the account steps up once and the call runs again; a second
// challenge goes to the caller, so a server that never takes the step-up cannot keep reopening the sign-in page.
@MainActor
internal struct StepUpRetry {
    let stepUp: @MainActor (StepUpChallenge) async throws -> Void

    func run<Value>(_ call: () async throws -> Value) async throws -> Value {
        do {
            return try await call()
        } catch {
            guard let challenge = StepUpChallenge(error) else { throw error }
            try await stepUp(challenge)
            return try await call()
        }
    }

    // The sign-in page opens over the window in front, as Sign In's does.
    static var live: StepUpRetry {
        StepUpRetry { challenge in
            try await AccountServices.shared.stepUp(
                acrValues: challenge.acrValues,
                maxAgeSecs: challenge.maxAgeSecs,
                using: WebAuthenticationSessionAuthenticator { NSApp.keyWindow ?? NSApp.mainWindow }
            )
        }
    }

    // Nil for an error the step-up did not cause, which the caller words.
    static func failure(_ error: any Error) -> StepUpFailure? {
        if StepUpChallenge(error) != nil {
            return .failed(message: String(localized: "The server still asks you to confirm it's you. Try again in a moment."))
        }
        guard let error = error as? AccountError else { return nil }
        switch error {
        case .canceled, .oauth("access_denied", _):
            return .canceled
        case .server(_, "step_up_other_account"):
            return .failed(message: String(
                localized: "The browser confirmed a different account. Confirm with the account this Mac is signed in to."
            ))
        default:
            return .failed(message: error.friendlyDescription ?? String(localized: "Could not confirm it's you. Try again."))
        }
    }
}
