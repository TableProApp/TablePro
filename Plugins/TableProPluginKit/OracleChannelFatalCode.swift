import Foundation

public enum OracleChannelFatalCode {
    public static func isChannelFatal(_ codeDescription: String) -> Bool {
        switch codeDescription {
        case "connectionError", "messageDecodingFailure", "unexpectedBackendMessage":
            return true
        default:
            return false
        }
    }
}
