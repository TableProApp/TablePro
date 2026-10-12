//
//  NativeDumpPasswordExposure.swift
//  TablePro
//

import AppKit
import Foundation

/// One tool, `sqlpackage`, takes a password only in its argument list, where `ps` can read it.
/// The user is told before it runs rather than after, because the exposure lasts as long as the
/// transfer and there is no other channel to move it to.
///
/// Backup and restore both reach it through `NativeDumpService.start`, so the consent belongs to
/// both. It used to sit in the backup flow alone, which left a restore putting the same password in
/// the same argument list with nothing said.
@MainActor
enum NativeDumpPasswordExposure {
    /// False when the user declined, so the caller must not start.
    static func confirm(
        connection: DatabaseConnection,
        formatId: String?,
        window: NSWindow?
    ) async -> Bool {
        guard let descriptor = NativeDumpRegistry.descriptor(for: connection.type, formatId: formatId),
              descriptor.exposesPasswordInArguments,
              !connection.username.isEmpty
        else { return true }

        /// Asked the way the transfer itself asks. A keychain read alone answered "no password" for
        /// a connection whose password comes from a `PasswordSource` or `~/.pgpass`, so the warning
        /// was skipped for exactly the connections that still put one on the command line. A
        /// resolution that throws is treated as a password rather than as none: the transfer
        /// resolves it again and may well succeed the second time.
        do {
            let resolved = try await ConnectionCredentialResolver.resolvePassword(
                for: connection,
                fields: DatabaseDriverFactory.resolvedAdditionalFields(for: connection)
                    ?? connection.additionalFields,
                override: DatabaseManager.shared.session(for: connection.id)?.cachedPassword
            )
            guard !resolved.isEmpty else { return true }
        } catch {
            return await ask(window: window)
        }
        return await ask(window: window)
    }

    private static func ask(window: NSWindow?) async -> Bool {
        await AlertHelper.confirm(
            title: String(localized: "This tool takes your password on its command line."),
            message: String(
                localized: """
                    SqlPackage has no other way to receive one, so while it runs the password is \
                    readable by other processes on this Mac. Windows or Entra authentication \
                    avoids it.
                    """),
            confirmButton: String(localized: "Continue"),
            window: window
        )
    }
}
