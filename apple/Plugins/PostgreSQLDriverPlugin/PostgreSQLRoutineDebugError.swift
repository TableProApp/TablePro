//
//  PostgreSQLRoutineDebugError.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PostgreSQLRoutineDebugError: PluginDriverError, Equatable {
    case extensionMissing(database: String)
    case serverPackageMissing
    case notOwner(routine: String)
    case sharedMemoryUnavailable
    case routineNotFound(String)
    case notDebuggable
    case pseudoTypeParameter
    case hidesDebuggerNotice(value: String)
    case limitsTransactionTime(value: String)
    case targetAbandoned(process: Int?, port: Int?)
    case unavailable
    case notPaused
    case unsupportedCommand
    case noDefault(parameter: String)
    case defaultNotReadable(parameter: String)

    var pluginErrorMessage: String {
        switch self {
        case .extensionMissing(let database):
            return String(format: String(localized: "The PL/pgSQL debugger isn't installed in “%@”."), database)
        case .serverPackageMissing:
            return String(localized: "This server has no PL/pgSQL debugger.")
        case .notOwner(let routine):
            return String(format: String(localized: "Only the owner of %@ or a superuser can debug it."), routine)
        case .sharedMemoryUnavailable:
            return String(localized: "The server couldn't start the debugger.")
        case .routineNotFound(let routine):
            return String(format: String(localized: "%@ no longer exists"), routine)
        case .notDebuggable:
            return String(localized: "Only PL/pgSQL functions and procedures can be debugged.")
        case .pseudoTypeParameter:
            return String(localized: "Routines with polymorphic or record parameters can't be debugged.")
        case .hidesDebuggerNotice(let value):
            return String(
                format: String(
                    localized: "This routine sets client_min_messages to %@, which hides the notice the debugger starts with."
                ),
                value
            )
        case .limitsTransactionTime(let value):
            return String(
                format: String(
                    localized: "This routine sets transaction_timeout to %@, which would end it while it waits at a breakpoint."
                ),
                value
            )
        case .targetAbandoned:
            return PostgreSQLRoutineDebugProtocol.abandonedMessage
        case .unavailable:
            return String(localized: "This connection can't run the PL/pgSQL debugger.")
        case .notPaused:
            return String(localized: "The routine isn't paused.")
        case .unsupportedCommand:
            return String(localized: "The PL/pgSQL debugger can't step out of a routine.")
        case .noDefault(let parameter):
            return String(format: String(localized: "%@ has no default value."), parameter)
        case .defaultNotReadable(let parameter):
            return String(
                format: String(localized: "This server can't show the default value of %@, so enter a value for it."),
                parameter
            )
        }
    }

    var pluginErrorDetail: String? {
        switch self {
        case .extensionMissing:
            return String(localized: "Ask a superuser to run CREATE EXTENSION pldbgapi in this database.")
        case .serverPackageMissing:
            return String(
                localized: """
                    Install the pldebugger package for this PostgreSQL version on the server, then run \
                    CREATE EXTENSION pldbgapi in this database.
                    """
            )
        case .sharedMemoryUnavailable:
            return String(localized: "Add plugin_debugger to shared_preload_libraries and restart the server.")
        case .hidesDebuggerNotice:
            return String(localized: "Remove SET client_min_messages from the routine to debug it.")
        case .limitsTransactionTime:
            return String(localized: "Remove SET transaction_timeout from the routine to debug it.")
        case .targetAbandoned(let process, let port):
            return PostgreSQLRoutineDebugProtocol.abandonedDetail(process: process, port: port)
        case .notOwner, .routineNotFound, .notDebuggable, .pseudoTypeParameter, .unavailable, .notPaused,
             .unsupportedCommand, .noDefault, .defaultNotReadable:
            return nil
        }
    }
}
