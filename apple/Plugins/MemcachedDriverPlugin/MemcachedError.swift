import Foundation
import TableProMemcachedCore
import TableProPluginKit

enum MemcachedError: Error, PluginDriverError {
    case notConnected
    case connectionClosed
    case timedOut
    case connectFailed(String)
    case authenticationRequired
    case authenticationFailed
    case server(MemcachedServerError)
    case command(MemcachedCommandError)
    case filter(MemcachedFilterRefusal)
    case refused(String)
    case unexpectedReply(String)

    var pluginErrorMessage: String {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Memcached")
        case .connectionClosed:
            return String(localized: "Memcached closed the connection")
        case .timedOut:
            return String(localized: "Memcached did not answer in time")
        case .connectFailed(let reason):
            return String(format: String(localized: "Could not connect to Memcached: %@"), reason)
        case .authenticationRequired:
            return String(localized: "This Memcached server requires a username and password")
        case .authenticationFailed:
            return String(localized: "Memcached rejected the username or password")
        case .server(let error):
            return error.message.isEmpty ? error.kind.rawValue : "\(error.kind.rawValue): \(error.message)"
        case .command(let error):
            return Self.describe(error)
        case .filter(let refusal):
            return Self.describe(refusal)
        case .refused(let message):
            return message
        case .unexpectedReply(let line):
            return String(format: String(localized: "Unexpected reply from Memcached: %@"), line)
        }
    }

    var errorDescription: String? { pluginErrorMessage }

    static func wrap(_ error: Error) -> Error {
        switch error {
        case let error as MemcachedServerError:
            return error.needsAuthentication ? MemcachedError.authenticationRequired : MemcachedError.server(error)
        case let error as MemcachedCommandError:
            return MemcachedError.command(error)
        case let error as MemcachedFilterRefusal:
            return MemcachedError.filter(error)
        case is MemcachedProtocolError:
            return MemcachedError.unexpectedReply(String(describing: error))
        default:
            return error
        }
    }

    private static func describe(_ error: MemcachedCommandError) -> String {
        switch error {
        case .empty:
            return String(localized: "Enter a Memcached command")
        case .unknownCommand(let name):
            return String(format: String(localized: "Unsupported Memcached command: %@"), name)
        case .wrongArguments(_, let usage):
            return String(format: String(localized: "Usage: %@"), usage)
        case .invalidKey(let key):
            return String(format: String(localized: "'%@' is not a valid key: a key is 1 to 250 bytes with no spaces or control characters"), key)
        case .invalidNumber(let text):
            return String(format: String(localized: "'%@' is not a valid number here"), text)
        case .unterminatedQuote:
            return String(localized: "A quoted value is missing its closing quote")
        }
    }

    private static func describe(_ refusal: MemcachedFilterRefusal) -> String {
        switch refusal {
        case .notKeyColumn:
            return String(localized: "Memcached can only filter by Key")
        case .unsupportedOperator(let op):
            return String(format: String(localized: "Memcached cannot filter keys with %@"), op)
        case .emptyList(let op):
            return String(format: String(localized: "Enter at least one value to filter with %@"), op)
        case .invalidPattern(let pattern):
            return String(format: String(localized: "'%@' is not a valid regular expression"), pattern)
        }
    }
}
