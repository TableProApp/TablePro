import Foundation

/// Why a connection's extensions did not load. Every case fails the connect: a database that
/// needs an extension is not usable without it, and loading part of the list would leave the
/// user reading "no such function" for the part that is missing.
public enum LoadableExtensionError: Error, Equatable, Sendable {
    case malformedList
    case missingPath
    case controlCharacterInPath
    case relativePath(LoadableExtension)
    case pathTooLong(LoadableExtension)
    case invalidEntryPoint(LoadableExtension)
    case duplicate(LoadableExtension)
    case fileNotFound(LoadableExtension)
    case notAFile(LoadableExtension)
    case damagedSignature(LoadableExtension)
    case entryPointNotFound(LoadableExtension, detail: String)
    case initializationFailed(LoadableExtension, detail: String)
    case libraryNotLoaded(LoadableExtension, detail: String)
    case loadingUnavailable
    case loadingNotClosed
    case remoteSession

    public var failedExtension: LoadableExtension? {
        switch self {
        case .relativePath(let item), .pathTooLong(let item), .invalidEntryPoint(let item),
             .duplicate(let item), .fileNotFound(let item), .notAFile(let item),
             .damagedSignature(let item), .entryPointNotFound(let item, _),
             .initializationFailed(let item, _), .libraryNotLoaded(let item, _):
            return item
        case .malformedList, .missingPath, .controlCharacterInPath, .loadingUnavailable, .loadingNotClosed,
             .remoteSession:
            return nil
        }
    }
}

extension LoadableExtensionError: LocalizedError {
    public var errorDescription: String? {
        guard let item = failedExtension else {
            return String(localized: "The SQLite extensions for this connection could not be loaded.")
        }
        return String(format: String(localized: "Could not load the extension \"%@\"."), item.fileName)
    }

    public var failureReason: String? {
        switch self {
        case .malformedList:
            return String(localized: "The saved extension list is not in a format TablePro can read.")
        case .missingPath:
            return String(localized: "An extension in the list has no file.")
        case .controlCharacterInPath:
            return String(localized: "The path of an extension in the list contains a line break or another control character.")
        case .relativePath(let item):
            return String(format: String(localized: "\"%@\" is not a full path."), item.path)
        case .pathTooLong(let item):
            return String(format: String(localized: "The path \"%@\" is too long."), item.path)
        case .invalidEntryPoint(let item):
            return String(
                format: String(localized: "\"%@\" is not a valid entry point name."),
                item.entryPoint ?? ""
            )
        case .duplicate(let item):
            return String(format: String(localized: "\"%@\" is in the list more than once."), item.path)
        case .fileNotFound(let item):
            return String(format: String(localized: "There is no file at \"%@\"."), item.path)
        case .notAFile(let item):
            return String(format: String(localized: "\"%@\" is not a file."), item.path)
        case .damagedSignature(let item):
            return String(
                format: String(localized: "The code signature of \"%@\" is damaged, so macOS would stop TablePro when it loads."),
                item.path
            )
        case .entryPointNotFound(_, let detail), .initializationFailed(_, let detail),
             .libraryNotLoaded(_, let detail):
            return detail
        case .loadingUnavailable:
            return String(localized: "SQLite did not allow extension loading on this connection.")
        case .loadingNotClosed:
            return String(localized: "SQLite did not turn extension loading off again after loading.")
        case .remoteSession:
            return String(localized: "Extensions load only for a database file on this Mac, not for a database on a server.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .relativePath:
            return String(localized: "Choose the file again, or type a path that starts with / or ~.")
        case .invalidEntryPoint:
            return String(localized: "Use the name of a C function, such as sqlite3_vec_init, or leave it empty.")
        case .duplicate:
            return String(localized: "Remove the second entry.")
        case .fileNotFound, .notAFile, .controlCharacterInPath:
            return String(localized: "Choose the extension's file again in Edit Connection.")
        case .damagedSignature(let item):
            return String(format: String(localized: "Sign it again with: codesign --force --sign - \"%@\""), item.path)
        case .entryPointNotFound:
            return String(localized: "Enter the entry point the extension's documentation names.")
        case .libraryNotLoaded(let item, let detail) where detail.localizedCaseInsensitiveContains("system policy"):
            return String(
                format: String(localized: "macOS blocks a library downloaded from the internet. If you trust it, run: xattr -d com.apple.quarantine \"%@\""),
                item.expandedPath
            )
        case .libraryNotLoaded(_, let detail) where detail.localizedCaseInsensitiveContains("incompatible architecture"):
            return String(localized: "Use the build of the extension made for this Mac's processor.")
        case .remoteSession:
            return String(localized: "Remove the extensions from this connection in Edit Connection.")
        case .malformedList, .missingPath, .pathTooLong, .initializationFailed, .libraryNotLoaded,
             .loadingUnavailable, .loadingNotClosed:
            return nil
        }
    }
}
