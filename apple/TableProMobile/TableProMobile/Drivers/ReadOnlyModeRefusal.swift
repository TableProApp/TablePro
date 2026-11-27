import Foundation

// Safe Mode Read-Only's refusal from a driver that runs the statement in the engine's read-only transaction. The message
// is the one the engine's Mac plugin shows, from the file both apps compile.
nonisolated enum ReadOnlyModeRefusal: LocalizedError, Equatable {
    case sessionNotIdle(message: String)
    case refused(message: String, serverMessage: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotIdle(let message):
            return message
        case .refused(let message, let serverMessage):
            let server = serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return server.isEmpty ? message : "\(message)\n\(server)"
        }
    }
}
