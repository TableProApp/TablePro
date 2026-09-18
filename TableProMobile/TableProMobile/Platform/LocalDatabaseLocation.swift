import Foundation

nonisolated enum LocalDatabaseLocation: Equatable, Sendable {
    case inMemory
    case appFile(URL)
    case externalFile(URL)
    case notOnThisDevice(storedPath: String)

    static let inMemoryPath = ":memory:"

    var fileURL: URL? {
        switch self {
        case .appFile(let url), .externalFile(let url): url
        case .inMemory, .notOnThisDevice: nil
        }
    }
}

nonisolated enum LocalDatabaseFileSource: Equatable, Sendable {
    case inMemory
    case file(URL)
    case securityScoped(URL)
}

nonisolated enum LocalDatabaseOpenMode: Equatable, Sendable {
    case existingOnly
    case createNew
}

nonisolated enum LocalDatabaseFileError: LocalizedError, Equatable, Sendable {
    nonisolated enum UnavailableReason: Equatable, Sendable {
        case missing
        case notOnThisDevice
        case accessLost
    }

    case unavailable(fileName: String, reason: UnavailableReason)
    case accessDenied(fileName: String)
    case copyFailed(fileName: String, message: String)
    case creationFailed(fileName: String, message: String)
    case alreadyExists(fileName: String)
    case invalidName

    var errorDescription: String? {
        switch self {
        case .unavailable(let fileName, _):
            return String(format: String(localized: "“%@” isn't available on this device."), fileName)
        case .accessDenied(let fileName):
            return String(format: String(localized: "TablePro can't open “%@”."), fileName)
        case .copyFailed(let fileName, let message):
            return String(format: String(localized: "Could not copy “%1$@” into TablePro: %2$@"), fileName, message)
        case .creationFailed(let fileName, let message):
            return String(format: String(localized: "Could not create “%1$@”: %2$@"), fileName, message)
        case .alreadyExists(let fileName):
            return String(format: String(localized: "A database named “%@” already exists."), fileName)
        case .invalidName:
            return String(localized: "Database names can't be blank, contain a slash, or start with a period.")
        }
    }

    var recoverySuggestion: String? {
        guard case .unavailable = self else { return nil }
        return String(localized: "Edit the connection and choose the database file again.")
    }
}
