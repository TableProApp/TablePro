import Foundation

public enum QuackExtensionLoader {
    /// LOAD first, because an installed extension loads without a download. Only when that fails does INSTALL
    /// run, then LOAD again. When both fail the INSTALL error is the one reported: the second LOAD says
    /// 'Install it first using "INSTALL quack"', a command that has just run, while INSTALL names the
    /// cause, such as "Failed to download extension" with no route to the extension repository (measured
    /// on DuckDB v2.0.0).
    ///
    /// `execute` runs one statement. A cancelled connect is rethrown as it is; an attempt that ended any
    /// other way is the caller's to tell apart, from its own state.
    public static func load(_ name: String, execute: (String) async throws -> Void) async throws {
        do {
            try await execute(loadStatement(name))
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // DuckDB found the file and ran it, and its init threw: an INSTALL keeps the same file, and a second
            // LOAD fails the same way. The motherduck extension's init calls api.motherduck.com, so each LOAD costs
            // about 10 s with no route there (measured on DuckDB v2.0.1).
            let text = error.localizedDescription
            if text.contains("Initialization function"), text.contains("threw an exception") {
                throw QuackConnectError.extensionNotLoaded(name: name, detail: text)
            }
        }

        var installFailure: (any Error)?
        do {
            try await execute(installStatement(name))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            installFailure = error
        }

        do {
            try await execute(loadStatement(name))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let installFailure {
                throw QuackConnectError.extensionNotInstalled(name: name, detail: installFailure.localizedDescription)
            }
            throw QuackConnectError.extensionNotLoaded(name: name, detail: error.localizedDescription)
        }
    }

    public static func loadStatement(_ name: String) -> String {
        "LOAD \(name)"
    }

    public static func installStatement(_ name: String) -> String {
        "INSTALL \(name)"
    }
}
