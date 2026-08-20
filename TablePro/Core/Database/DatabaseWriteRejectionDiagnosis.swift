//
//  DatabaseWriteRejectionDiagnosis.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum DatabaseWriteRejectionDiagnosis: LocalizedError, Equatable {
    case serverEnforcedReadOnly(serverMessage: String)

    private static let readOnlyTransactionSqlState = "25006"
    private static let mysqlReadOnlyServerCodes: Set<Int> = [1_290, 1_836, 1_874]

    static func classify(_ error: Error) -> DatabaseWriteRejectionDiagnosis? {
        guard let driverError = error as? any PluginDriverError else { return nil }

        if driverError.pluginSqlState == readOnlyTransactionSqlState {
            return .serverEnforcedReadOnly(serverMessage: driverError.pluginErrorMessage)
        }

        if let code = driverError.pluginErrorCode, mysqlReadOnlyServerCodes.contains(code) {
            return .serverEnforcedReadOnly(serverMessage: driverError.pluginErrorMessage)
        }

        return nil
    }

    static func formatted(_ error: Error) -> String {
        guard let diagnosis = classify(error) else { return error.localizedDescription }
        return [diagnosis.errorDescription, diagnosis.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    var serverMessage: String {
        switch self {
        case .serverEnforcedReadOnly(let message): return message
        }
    }

    var errorDescription: String? {
        String(localized: "The database server rejected this write because the connection is read-only.")
    }

    var recoverySuggestion: String? {
        String(
            format: String(
                localized: """
                    The database server enforced this, not TablePro's Safe Mode. \
                    You are most likely connected to a read replica, or the server sets new transactions to read-only. \
                    Connect to the primary server to write.

                    Server response: %@
                    """
            ),
            serverMessage
        )
    }
}
