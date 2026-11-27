import Foundation
import Network
import NIOCore

// A connect that fails below the TNS exchange throws Network.framework's or SwiftNIO's own error, whose description is
// a struct dump. These are the cases a user can act on, in words.
public enum OracleTransportFailure {
    public static func isConnectionRefused(_ error: any Error) -> Bool {
        posixCode(of: error) == ECONNREFUSED
    }

    public static func detail(_ error: any Error) -> String? {
        if case .connectTimeout(let amount) = error as? ChannelError {
            let seconds = max(1, Int((Double(amount.nanoseconds) / 1_000_000_000).rounded()))
            return String(format: String(localized: "no answer within %lld seconds"), seconds)
        }
        if let nwError = error as? NWError, case .dns = nwError {
            return String(localized: "the host name could not be resolved")
        }
        if let code = posixCode(of: error), let text = strerror(code) {
            return String(cString: text)
        }
        return nil
    }

    private static func posixCode(of error: any Error) -> Int32? {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            return code.rawValue
        }
        if let ioError = error as? IOError {
            return ioError.errnoCode
        }
        if let posixError = error as? POSIXError {
            return posixError.code.rawValue
        }
        return nil
    }
}
