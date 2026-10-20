//
//  AWSDeadlineSession.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum AWSDeadlineSession {
    // A connect's AWS requests share its deadline; a later sign-in has none and uses the shared session.
    static func run<Value>(
        within deadline: ConnectionDeadline?,
        _ body: (URLSession) async throws -> Value
    ) async throws -> Value {
        guard let deadline else {
            return try await body(AWSHTTP.shared)
        }
        let timeout = ConnectionCredentialResolver.credentialRequestTimeout(for: deadline)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await body(session)
    }
}
