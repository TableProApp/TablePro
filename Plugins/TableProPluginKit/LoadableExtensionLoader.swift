import Foundation

/// Loads a connection's extensions into one SQLite handle, in order, through the C API only.
///
/// The two closures are the only calls that touch SQLite, so each engine supplies them from its own
/// handle and the sequence stays in one place:
///
/// - `setLoadingEnabled` sets `SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION` and answers whether loading is
///   on afterwards. That option opens `sqlite3_load_extension` and leaves the `load_extension()` SQL
///   function refused, which `sqlite3_enable_load_extension` would open as well.
/// - `loadExtension` calls `sqlite3_load_extension` and answers its error text, nil on success.
///
/// Loading is turned off again whatever happened, and a handle it will not turn off for fails the
/// connect rather than being handed to the user with the C API still open.
public enum LoadableExtensionLoader {
    public static func load(
        _ extensions: [LoadableExtension],
        setLoadingEnabled: (Bool) -> Bool,
        loadExtension: (_ file: String, _ entryPoint: String?) -> String?,
        diagnoseOpenFailure: (String) -> String? = LoadableExtensionDiagnosis.openFailure
    ) throws {
        guard !extensions.isEmpty else { return }
        try LoadableExtensionPreflight.validate(extensions)
        guard setLoadingEnabled(true) else { throw LoadableExtensionError.loadingUnavailable }

        var failure: Error?
        var loadedFiles = Set<String>()
        for item in extensions {
            do {
                let file = try LoadableExtensionPreflight.resolveFile(for: item)
                let key = LoadableExtensionPreflight.loadedFileKey(for: file, entryPoint: item.entryPoint)
                guard loadedFiles.insert(key).inserted else { throw LoadableExtensionError.duplicate(item) }
                if let message = loadExtension(file, item.entryPoint) {
                    throw LoadableExtensionDiagnosis.error(
                        forSQLiteMessage: message,
                        loading: item,
                        from: file,
                        diagnoseOpenFailure: diagnoseOpenFailure
                    )
                }
            } catch {
                failure = error
                break
            }
        }

        let stillEnabled = setLoadingEnabled(false)
        if let failure { throw failure }
        if stillEnabled { throw LoadableExtensionError.loadingNotClosed }
    }
}

/// Turns SQLite's error text into the reason the user can act on.
public enum LoadableExtensionDiagnosis {
    public static func error(
        forSQLiteMessage message: String,
        loading item: LoadableExtension,
        from file: String,
        diagnoseOpenFailure: (String) -> String? = openFailure
    ) -> LoadableExtensionError {
        if message.hasPrefix("dlsym("), let symbol = missingSymbol(in: message) {
            return .entryPointNotFound(
                item,
                detail: String(format: String(localized: "The file has no function named %@."), symbol)
            )
        }
        let initializationPrefix = "error during initialization:"
        if message.hasPrefix(initializationPrefix) {
            let reason = message.dropFirst(initializationPrefix.count).trimmingCharacters(in: .whitespaces)
            return .initializationFailed(
                item,
                detail: String(format: String(localized: "The extension failed to start: %@"), reason)
            )
        }
        let reason = diagnoseOpenFailure(file).map { dyldReason(in: $0, for: file) } ?? message
        return .libraryNotLoaded(item, detail: reason)
    }

    /// SQLite reports a failed open against the path it retried with ".dylib" appended, so the
    /// reason for the file itself comes from opening it directly. Nil when it opens.
    public static func openFailure(_ file: String) -> String? {
        guard let handle = dlopen(file, RTLD_NOW | RTLD_LOCAL) else {
            return dlerror().map { String(cString: $0) }
        }
        dlclose(handle)
        return nil
    }

    /// dyld lists every place it looked, `tried: '<path>' (<reason>), '<path>' (<reason>)`. The file
    /// that was asked for is not always first: with `DYLD_LIBRARY_PATH` set, as it is under a test
    /// host, dyld tries that folder first and reports "no such file" there. So the reason given for
    /// the file itself wins, then the first reason that is not "no such file". A reason can hold
    /// parentheses of its own, as in "mach-o file, but is an incompatible architecture (have
    /// 'x86_64', need 'arm64')".
    public static func dyldReason(in message: String, for file: String) -> String {
        let attempts = triedPaths(in: message)
        let resolved = (file as NSString).resolvingSymlinksInPath
        if let own = attempts.first(where: { $0.path == file || $0.path == resolved }) {
            return own.reason
        }
        return attempts.first { $0.reason != "no such file" }?.reason ?? attempts.first?.reason ?? message
    }

    private static func triedPaths(in message: String) -> [(path: String, reason: String)] {
        guard let tried = message.range(of: "tried: ") else { return [] }
        var attempts: [(path: String, reason: String)] = []
        var index = tried.upperBound
        while let open = message[index...].firstIndex(of: "'"),
              let close = message[message.index(after: open)...].firstIndex(of: "'"),
              message[close...].hasPrefix("' ("),
              let reasonEnd = matchingParenthesis(in: message, from: message.index(close, offsetBy: 3)) {
            let path = String(message[message.index(after: open)..<close])
            let reason = String(message[message.index(close, offsetBy: 3)..<reasonEnd])
            attempts.append((path: path, reason: reason))
            index = message.index(after: reasonEnd)
        }
        return attempts
    }

    private static func matchingParenthesis(in message: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < message.endIndex {
            switch message[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = message.index(after: index)
        }
        return nil
    }

    private static func missingSymbol(in message: String) -> String? {
        guard let comma = message.firstIndex(of: ","),
              let close = message[comma...].firstIndex(of: ")")
        else { return nil }
        let symbol = message[message.index(after: comma)..<close].trimmingCharacters(in: .whitespaces)
        return symbol.isEmpty ? nil : symbol
    }
}
