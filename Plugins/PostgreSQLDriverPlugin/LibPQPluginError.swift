import Foundation
import TableProPluginKit

struct LibPQPluginError: Error {
    let message: String
    let sqlState: String?
    let detail: String?

    static let notConnected = LibPQPluginError(
        message: String(localized: "Not connected to database"), sqlState: nil, detail: nil)
    static let connectionFailed = LibPQPluginError(
        message: String(localized: "Failed to establish connection"), sqlState: nil, detail: nil)
    static let connectionTimedOut = LibPQPluginError(
        message: String(localized: "Timed out while connecting to the server"), sqlState: nil, detail: nil)
}

internal extension LibPQPluginError {
    private static let sqlStateField = Int32(UInt8(ascii: "C"))
    private static let detailField = Int32(UInt8(ascii: "D"))

    init(message: String, readingResultField readField: (Int32) -> String?) {
        self.init(
            message: message,
            sqlState: readField(Self.sqlStateField),
            detail: readField(Self.detailField)
        )
    }
}

extension LibPQPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginSqlState: String? { sqlState }
    var pluginErrorDetail: String? { detail }
}
