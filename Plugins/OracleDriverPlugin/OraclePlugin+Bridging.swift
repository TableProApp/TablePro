import Foundation
import os
import OSLog
import TableProOracleCore
import TableProPluginKit

private let bridgingLogger = Logger(subsystem: "com.TablePro.OracleDriver", category: "OracleBridging")

struct OraclePluginError: Error, PluginDriverError {
    let core: OracleCoreError

    var pluginErrorMessage: String {
        core.errorDescription ?? String(localized: "Query execution failed")
    }
}

extension OracleCoreError {
    var asPluginError: Error {
        if case .tlsHandshakeFailed(let kind, let serverMessage) = self {
            return kind.sslHandshakeError(serverMessage: serverMessage)
        }
        return OraclePluginError(core: self)
    }
}

extension OracleTLSFailureKind {
    func sslHandshakeError(serverMessage: String) -> SSLHandshakeError {
        switch self {
        case .clientCertRequired: return .clientCertRequired(serverMessage: serverMessage)
        case .cipherMismatch: return .cipherMismatch(serverMessage: serverMessage)
        case .untrustedCertificate: return .untrustedCertificate(serverMessage: serverMessage)
        case .unknown: return .unknown(serverMessage: serverMessage)
        }
    }
}

extension OracleRawCell {
    var asPluginCell: PluginCellValue {
        switch self {
        case .null: return .null
        case .string(let value): return .text(value)
        case .bytes(let data): return .bytes(data)
        }
    }
}

extension PluginCellValue {
    var oracleBindValue: OracleBindValue {
        switch self {
        case .null: return .null
        case .text(let value): return .text(value)
        case .bytes(let data): return .bytes(data)
        }
    }
}

extension OracleColumnRow {
    var pluginColumnInfo: PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: displayType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: nil,
            identityKind: identityGeneration.map(\.identityKind),
            isGenerated: isVirtual,
            allowedValues: nil,
            generationExpression: generationExpression,
            generationKind: isVirtual ? .virtual : nil,
            ddlSpelling: OracleTypeCatalog.ddlSpelling(forDeclaredType: displayType),
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: classificationTypeName
        )
    }
}

extension OracleIdentityGeneration {
    var identityKind: IdentityKind {
        switch self {
        case .always: return .always
        case .byDefault: return .byDefault
        }
    }
}

extension OracleRawResult {
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

extension SSLConfiguration {
    var oracleTLSDescription: OracleTLSDescription {
        OracleTLSDescription(
            mode: Self.oracleMode(for: mode),
            caCertificatePath: caCertificatePath,
            clientCertificatePath: clientCertificatePath,
            clientKeyPath: clientKeyPath
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
