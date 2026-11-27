import Foundation
import os
import OSLog
import TableProOracleCore
import TableProPluginKit

nonisolated private let bridgingLogger = Logger(subsystem: "com.TablePro.OracleDriver", category: "OracleBridging")

nonisolated struct OraclePluginError: Error, PluginDriverError {
    let core: OracleCoreError

    var pluginErrorMessage: String {
        core.errorDescription ?? String(localized: "Query execution failed")
    }
}

nonisolated extension OracleCoreError {
    var asPluginError: Error {
        if case .tlsHandshakeFailed(let kind, let serverMessage) = self {
            return kind.sslHandshakeError(serverMessage: serverMessage)
        }
        return OraclePluginError(core: self)
    }
}

nonisolated extension OracleTLSFailureKind {
    func sslHandshakeError(serverMessage: String) -> SSLHandshakeError {
        switch self {
        case .clientCertRequired: return .clientCertRequired(serverMessage: serverMessage)
        case .cipherMismatch: return .cipherMismatch(serverMessage: serverMessage)
        case .untrustedCertificate: return .untrustedCertificate(serverMessage: serverMessage)
        case .unknown: return .unknown(serverMessage: serverMessage)
        }
    }
}

nonisolated extension OracleRawResult {
    func toPluginResult(executionTime: TimeInterval) -> PluginQueryResult {
        let names = columns.map(\.name)
        let typeNames = columns.map(\.typeName)
        return PluginQueryResult(
            columns: names,
            columnTypeNames: typeNames,
            rows: rows.map { $0.map(\.asPluginCell) },
            rowsAffected: affectedRows,
            timing: PluginQueryTiming(total: executionTime),
            isTruncated: isTruncated,
            columnMeta: OracleTypeCatalog.resultColumnMeta(columns: names, typeNames: typeNames)
        )
    }
}

nonisolated extension SSLConfiguration {
    func oracleTLSDescription(serverName: String?) -> OracleTLSDescription {
        OracleTLSDescription(
            mode: Self.oracleMode(for: mode),
            caCertificatePath: caCertificatePath,
            clientCertificatePath: clientCertificatePath,
            clientKeyPath: clientKeyPath,
            serverName: serverName
        )
    }

    private static func oracleMode(for mode: SSLMode) -> OracleTLSDescription.Mode {
        switch mode {
        case .disabled:
            return .disabled
        case .preferred:
            bridgingLogger.warning("Oracle SSL mode 'Preferred' is not supported by OracleNIO; falling back to plain TCP. Use 'Required' to enforce TCPS.")
            return .disabled
        case .required:
            return .required
        case .verifyCa:
            return .verifyCA
        case .verifyIdentity:
            return .verifyIdentity
        }
    }
}
