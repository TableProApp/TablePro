//
//  ConnectionTestResult.swift
//  TablePro
//

import Foundation

/// What Test Connection learned from a server that answered. A test that could not connect throws instead.
internal struct ConnectionTestResult: Equatable, Sendable {
    let succeeded: Bool
    /// The warning the server sent with the login, such as an Oracle password in its grace period.
    let warning: String?

    init(succeeded: Bool, warning: String? = nil) {
        self.succeeded = succeeded
        self.warning = succeeded ? warning : nil
    }
}
