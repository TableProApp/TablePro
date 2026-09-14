//
//  PasswordSourceProbe.swift
//  TablePro
//

import Foundation
import Observation

/// Runs a password source once so the user can see it work before saving a connection around it.
///
/// The password itself is never reported, not even its length. What the user needs to know is
/// whether the command ran and what went wrong when it did not, and a settings pane that echoes a
/// production secret onto the screen is a worse tool than one that does not.
@Observable
@MainActor
final class PasswordSourceProbe {
    struct Outcome: Equatable {
        let isSuccess: Bool
        let message: String
    }

    private(set) var isRunning = false
    private(set) var outcome: Outcome?

    @ObservationIgnored private var task: Task<Void, Never>?

    func run(source: PasswordSource?, context: PasswordCommandTemplate.Context, sharedTemplate: String) {
        guard let source else { return }
        task?.cancel()
        isRunning = true
        outcome = nil
        task = Task { [weak self] in
            let result: Outcome
            do {
                _ = try await PasswordSourceResolver.resolve(
                    source,
                    context: context,
                    sharedTemplate: sharedTemplate
                )
                result = Outcome(isSuccess: true, message: String(localized: "Got a password."))
            } catch {
                result = Outcome(isSuccess: false, message: error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            self?.isRunning = false
            self?.outcome = result
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        isRunning = false
        outcome = nil
    }
}
