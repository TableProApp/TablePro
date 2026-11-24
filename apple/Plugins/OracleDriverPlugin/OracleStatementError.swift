//
//  OracleStatementError.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

// Thrown by the files the iOS app compiles too, so it reads the same as the driver's own query failure.
nonisolated struct OracleStatementError: PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }
}
