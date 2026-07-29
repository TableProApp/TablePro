//
//  CloudSQLProxyError.swift
//  TablePro
//

import Foundation

enum CloudSQLProxyError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case noAvailablePort
    case invalidInstanceConnectionName
    case credentialsWriteFailed
    case startupFailed(stderrTail: String)
    case readinessTimeout(stderrTail: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return String(localized: "cloud-sql-proxy was not found. Install it with `brew install cloud-sql-proxy`, or download it in the Cloud SQL Auth Proxy settings.")
        case .noAvailablePort:
            return String(localized: "No available local port for the Cloud SQL Auth Proxy.")
        case .invalidInstanceConnectionName:
            return String(localized: "The instance connection name must be in the form project:region:instance.")
        case .credentialsWriteFailed:
            return String(localized: "Could not write the Google Cloud service account key to a temporary file.")
        case .startupFailed(let stderrTail):
            return stderrTail.isEmpty
                ? String(localized: "The Cloud SQL Auth Proxy failed to start.")
                : String(format: String(localized: "The Cloud SQL Auth Proxy failed to start: %@"), stderrTail)
        case .readinessTimeout(let stderrTail):
            return stderrTail.isEmpty
                ? String(localized: "The Cloud SQL Auth Proxy did not become ready in time.")
                : String(format: String(localized: "The Cloud SQL Auth Proxy did not become ready in time: %@"), stderrTail)
        }
    }
}
