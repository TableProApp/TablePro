//
//  SafeModeGuard.swift
//  TablePro
//

import AppKit
import LocalAuthentication
import os

@MainActor
internal final class SafeModeGuard {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SafeModeGuard")

    internal enum Permission {
        case allowed
        case blocked(String)
    }

    internal static func checkPermission(
        level: SafeModeLevel,
        isWriteOperation: Bool,
        sql: String,
        operationDescription: String,
        window: NSWindow?,
        databaseType: DatabaseType? = nil
    ) async -> Permission {
        let effectiveLevel: SafeModeLevel
        if level.requiresPro && !LicenseManager.shared.isFeatureAvailable(.safeMode) {
            logger.info("Safe mode \(level.rawValue) requires Pro license; downgrading to silent")
            effectiveLevel = .silent
        } else {
            effectiveLevel = level
        }

        let effectiveIsWrite: Bool
        if let dbType = databaseType, !PluginManager.shared.supportsReadOnlyMode(for: dbType) {
            effectiveIsWrite = true
        } else {
            effectiveIsWrite = isWriteOperation
        }

        switch effectiveLevel {
        case .silent:
            return .allowed

        case .readOnly:
            if effectiveIsWrite {
                return .blocked(String(localized: "Cannot execute write queries: connection is read only"))
            }
            return .allowed

        case .alert:
            if effectiveIsWrite {
                guard await showConfirmationAlert(sql: sql, operationDescription: operationDescription, window: window) else {
                    return .blocked(String(localized: "Operation cancelled by user"))
                }
            }
            return .allowed

        case .alertFull:
            guard await showConfirmationAlert(sql: sql, operationDescription: operationDescription, window: window) else {
                return .blocked(String(localized: "Operation cancelled by user"))
            }
            return .allowed

        case .safeMode:
            if effectiveIsWrite {
                guard await showConfirmationAlert(sql: sql, operationDescription: operationDescription, window: window) else {
                    return .blocked(String(localized: "Operation cancelled by user"))
                }
                guard await authenticateUser() else {
                    return .blocked(String(localized: "Authentication required to execute write operations"))
                }
            }
            return .allowed

        case .safeModeFull:
            guard await showConfirmationAlert(sql: sql, operationDescription: operationDescription, window: window) else {
                return .blocked(String(localized: "Operation cancelled by user"))
            }
            guard await authenticateUser() else {
                return .blocked(String(localized: "Authentication required to execute operations"))
            }
            return .allowed
        }
    }

    private static func showConfirmationAlert(
        sql: String,
        operationDescription: String,
        window: NSWindow?
    ) async -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if (trimmed as NSString).length > 200 {
            preview = String(trimmed.prefix(200)) + "..."
        } else {
            preview = trimmed
        }

        return await AlertHelper.confirmDestructive(
            title: operationDescription,
            message: String(format: String(localized: "Are you sure you want to execute this query?\n\n%@"), preview),
            confirmButton: String(localized: "Execute"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

    private static func authenticateUser() async -> Bool {
        await Task.detached {
            let context = LAContext()
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: String(localized: "Authenticate to execute database operations")
                )
            } catch {
                await MainActor.run {
                    logger.warning("Biometric authentication failed: \(error.localizedDescription)")
                }
                return false
            }
        }.value
    }
}
