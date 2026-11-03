//
//  CloudSQLProxyError.swift
//  TablePro
//

import Foundation

enum CloudSQLProxyError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case downloadFailed(statusCode: Int)
    case checksumMismatch
    case noAvailablePort
    case invalidInstanceConnectionName
    case credentialsWriteFailed
    case startupFailed(stderrTail: String)
    case readinessTimeout(stderrTail: String)
    case portInUse(Int)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return String(localized: "cloud-sql-proxy was not found. Install it with “brew install cloud-sql-proxy”, or download it in the Cloud SQL Auth Proxy settings.")
        case .downloadFailed(let statusCode):
            return String(
                format: String(localized: "Couldn't download cloud-sql-proxy. The server answered with HTTP status %lld."),
                statusCode
            )
        case .checksumMismatch:
            return String(localized: "The downloaded cloud-sql-proxy didn't match its expected checksum, so it wasn't installed.")
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
        case .portInUse(let port):
            return String(
                format: String(localized: "Another program is already listening on local port %d. Choose another port for the Cloud SQL Auth Proxy, or leave it empty."),
                port
            )
        case .readinessTimeout(let stderrTail):
            return stderrTail.isEmpty
                ? String(localized: "The Cloud SQL Auth Proxy did not become ready in time.")
                : String(format: String(localized: "The Cloud SQL Auth Proxy did not become ready in time: %@"), stderrTail)
        }
    }
}
