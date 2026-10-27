//
//  OracleDebugText.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

struct OracleDebugPluginError: Error, PluginDriverError {
    let message: String
    var detail: String?

    var pluginErrorMessage: String { message }
    var pluginErrorDetail: String? { detail }
}

// Everything the Oracle debugger says to a person, worded once.
enum OracleDebugText {
    static let fallbackSuffix = String(localized: "Debugging through DBMS_DEBUG instead.")

    static func kindName(_ kind: OracleDebugUnitKind) -> String {
        switch kind {
        case .procedure: return String(localized: "Procedure")
        case .function: return String(localized: "Function")
        case .package, .packageBody: return String(localized: "Package")
        case .trigger: return String(localized: "Trigger")
        case .type, .typeBody: return String(localized: "Type")
        }
    }

    static func unitUnreadable(_ name: String) -> String {
        String(format: String(localized: "TablePro can't read %@. Check that this account can see its source."), name)
    }

    static func noEntryPoints(_ name: String) -> String {
        String(format: String(localized: "%@ has no public procedure or function to start from."), name)
    }

    static func invalidPorts(_ text: String) -> String {
        String(format: String(localized: "“%@” isn't a port or a range of ports, such as 4000-4999."), text)
    }

    static func line(for notice: OracleDebugNotice) -> String {
        switch notice {
        case let .connectedOverJDWP(host, port):
            return String(format: String(localized: "Debugging through DBMS_DEBUG_JDWP. The database connected to TablePro at %@."), "\(host):\(port)")
        case let .fellBack(failure, host, port):
            return jdwpFailureSentence(failure, host: host, port: port) + " " + fallbackSuffix
        case .usingDBMSDebug(.chosen):
            return String(localized: "Debugging through DBMS_DEBUG.")
        case .usingDBMSDebug(.noDebuggerHost):
            return String(localized: "No debugger host is set, so the database can't connect back to TablePro. Debugging through DBMS_DEBUG.")
        case let .breakpointHasNoCode(unit, line):
            return String(format: String(localized: "Line %1$d of %2$@ has no code to stop at."), line, unit.name)
        case let .breakpointMoved(unit, from, to):
            return String(
                format: String(localized: "The breakpoint on line %1$d of %2$@ moved to line %3$d, the next line with code."),
                from, unit.name, to
            )
        case .serverOutput(let text):
            return text
        }
    }

    private static func jdwpFailureSentence(_ failure: OracleJDWPFailure, host: String, port: Int) -> String {
        let address = port > 0 ? "\(host):\(port)" : host
        switch failure {
        case .accessControlList:
            return String(format: String(localized: """
                The database isn't allowed to connect to TablePro at %@ (ORA-24247). A DBA can allow it with \
                DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE and the jdwp privilege.
                """), address)
        case .unreachable:
            return String(format: String(localized: "The database couldn't reach TablePro at %@."), address)
        case .packageUnavailable:
            return String(localized: "This database doesn't provide DBMS_DEBUG_JDWP.")
        case .timedOut:
            return String(format: String(localized: "The database didn't connect to TablePro at %@ in time."), address)
        case .noFreePort:
            return String(localized: "No port in the Debugger Ports range is free on this Mac.")
        case .handshakeFailed:
            return String(localized: "The connection from the database didn't complete the debugger handshake.")
        case .noDebuggerHost:
            return String(localized: "DBMS_DEBUG_JDWP needs a Debugger Host for the database to connect back to.")
        case .unexpectedPeer(let addresses):
            return String(
                format: String(localized: "A connection came from %@, which isn't the database server's address, so TablePro closed it."),
                addresses.joined(separator: ", ")
            )
        case .missingPrivilege:
            return String(localized: "Debugging needs the DEBUG CONNECT SESSION privilege.")
        case .other(let message):
            return message
        }
    }

    static func error(for missing: OracleDebugStatements.MissingPrivilege, unit: OracleDebugUnit) -> OracleDebugPluginError {
        switch missing {
        case .debugConnectSession(let user):
            return OracleDebugPluginError(
                message: String(localized: "Debugging needs the DEBUG CONNECT SESSION privilege."),
                detail: String(format: String(localized: "A DBA can grant it with GRANT DEBUG CONNECT SESSION TO %@."), user)
            )
        case .debugOnObject(let user):
            let qualified = "\(unit.owner).\(unit.name)"
            return OracleDebugPluginError(
                message: String(format: String(localized: "Debugging %@ needs the DEBUG privilege on it."), qualified),
                detail: String(
                    format: String(localized: "A DBA can grant it with GRANT DEBUG ON %1$@ TO %2$@, or grant DEBUG ANY PROCEDURE."),
                    qualified, user
                )
            )
        }
    }

    static func error(for error: Error, host: String?) -> Error {
        if error is OracleDebugPluginError || error is OraclePluginError || error is CancellationError { return error }
        if let core = error as? OracleCoreError { return core.asPluginError }
        if error is OracleJDWPError || error is OracleJDWPListenerError {
            return OracleDebugPluginError(message: String(localized: "The database's debugger sent data TablePro can't read, so the session ended."))
        }
        if error is OracleDebugPayload.ParseError {
            return OracleDebugPluginError(message: String(localized: "The database answered the debugger with data TablePro can't read."))
        }
        guard let debug = error as? OracleDebugError else {
            return OracleDebugPluginError(message: String(localized: "The debugger couldn't finish this step."), detail: error.localizedDescription)
        }
        switch debug {
        case .privilegeMissing(let message):
            return OracleDebugPluginError(
                message: String(localized: "Debugging needs the DEBUG CONNECT SESSION privilege."),
                detail: message
            )
        case .server(_, let message):
            return OracleDebugPluginError(message: String(localized: "The debugger couldn't start."), detail: message)
        case .jdwp(.missingPrivilege):
            return OracleDebugPluginError(
                message: String(localized: "Debugging needs the DEBUG CONNECT SESSION privilege."),
                detail: nil
            )
        case .jdwp(let failure):
            return OracleDebugPluginError(
                message: jdwpFailureSentence(failure, host: host ?? "", port: 0),
                detail: jdwpFailureAdvice(failure)
            )
        case .notPaused, .ended:
            return OracleDebugPluginError(message: String(localized: "The debug session has ended."))
        case let .unsupportedArgument(name, typeName):
            return OracleDebugPluginError(
                message: String(format: String(localized: "TablePro can't turn text into a %2$@ value for %1$@."), name, typeName),
                detail: String(localized: "Pass NULL or leave it at its default.")
            )
        case let .undeclarableArgument(name, typeName):
            return OracleDebugPluginError(
                message: String(format: String(localized: "TablePro can't pass any value of type %2$@ to %1$@."), name, typeName),
                detail: String(localized: "Debug it from a routine that calls it with that value.")
            )
        case let .ambiguousDefaults(subprogram, parameters):
            // String(localized:) does not inflect, so the plural is its own key.
            let format = parameters.count == 1
                ? String(localized: "Give %1$@ a value. Left at its default, the call also matches another overload of %2$@.")
                : String(localized: "Give %1$@ values. Left at their defaults, the call also matches another overload of %2$@.")
            return OracleDebugPluginError(
                message: String(format: format, ListFormatter.localizedString(byJoining: parameters), subprogram),
                detail: String(localized: "Oracle can't tell the overloads apart without it (PLS-00307), and TablePro can't read the default to pass it.")
            )
        case .ambiguousCall(let subprogram):
            return OracleDebugPluginError(
                message: String(format: String(localized: "This call matches more than one overload of %@, so Oracle can't run it (PLS-00307)."), subprogram),
                detail: String(localized: "Debug it from a routine that calls it with arguments only this overload takes.")
            )
        case .unitNotFound:
            return OracleDebugPluginError(message: String(localized: "TablePro can't read this unit's source."))
        case .malformedReply:
            return OracleDebugPluginError(message: String(localized: "The database's debugger sent data TablePro can't read, so the session ended."))
        case .debuggerStoppedAnswering:
            return OracleDebugPluginError(message: String(localized: "The database's debugger stopped answering, so the session ended."))
        case .debuggerRefused(let code):
            return OracleDebugPluginError(
                message: String(localized: "The database's debugger refused the request."),
                detail: String(format: String(localized: "JDWP error %d."), code)
            )
        case .unreadableAnswer:
            return OracleDebugPluginError(message: String(localized: "The database answered the debugger with data TablePro can't read."))
        }
    }

    // What the person can do about each way the database failed to connect back.
    static func jdwpFailureAdvice(_ failure: OracleJDWPFailure) -> String? {
        switch failure {
        case .accessControlList:
            return String(localized: "Or choose DBMS_DEBUG as the protocol, which needs no ACL entry.")
        case .unreachable(let message):
            return message + "\n" + String(localized: "Set Debugger Host to an address the server can reach, or choose DBMS_DEBUG as the protocol.")
        case .timedOut:
            return String(localized: "Set Debugger Host to an address the server can reach, or choose DBMS_DEBUG as the protocol.")
        case .packageUnavailable, .handshakeFailed:
            return String(localized: "Choose DBMS_DEBUG as the protocol.")
        case .noFreePort:
            return String(localized: "Choose other Debugger Ports, or DBMS_DEBUG as the protocol.")
        case .noDebuggerHost:
            return String(localized: "Set Debugger Host to an address the database server can reach this Mac at, or choose DBMS_DEBUG as the protocol.")
        case .unexpectedPeer:
            return String(localized: "If the server reaches this Mac through NAT or a load balancer, choose DBMS_DEBUG as the protocol.")
        case .missingPrivilege:
            return nil
        case .other(let message):
            return message
        }
    }

    static func failure(_ failure: OracleDebugFailure) -> (message: String, detail: String?) {
        switch failure {
        case .routineFailed(let message):
            return (String(localized: "The routine raised an error. Its changes were rolled back."), message.isEmpty ? nil : message)
        case .stopped:
            return (String(localized: "Stopped. The routine's changes were rolled back."), nil)
        case .stillRunning(let identity):
            let text = stillRunning(identity)
            return (text.message, text.detail)
        case .connectionLost(let message):
            return (String(localized: "The debug session's connection closed."), message)
        }
    }

    static func stillRunning(_ identity: OracleDebugSessionIdentity?) -> (message: String, detail: String) {
        let message = String(localized: "TablePro couldn't confirm that the routine ended. It may still be running on the server.")
        let rollback = String(localized: "Its uncommitted work rolls back when it ends.")
        guard let identity else {
            return (message, rollback + " " + String(localized: "A user with ALTER SYSTEM can find its session in V$SESSION and end it with ALTER SYSTEM KILL SESSION."))
        }
        guard let serial = identity.serial else {
            return (message, String(format: String(localized: "Session SID %d. %@"), identity.sid, rollback))
        }
        return (message, String(
            format: String(localized: "Session SID %1$d, SERIAL# %2$d. %3$@ A user with ALTER SYSTEM can end it now with ALTER SYSTEM KILL SESSION '%1$d,%2$d' IMMEDIATE."),
            identity.sid, serial, rollback
        ))
    }

    // Nil is SQL NULL, so a value the debugger can't read is said in words.
    static func text(for value: OracleDebugValue) -> String? {
        switch value {
        case .scalar(let text):
            return text
        case .record(let members):
            return "(" + members.map { "\($0.name) => \($0.value ?? "NULL")" }.joined(separator: ", ") + ")"
        case .collection(let count):
            guard let count else { return String(localized: "Collection") }
            // String(localized:) does not inflect, so the singular is its own key.
            if count == 1 { return String(localized: "Collection of 1 element") }
            return String(format: String(localized: "Collection of %d elements"), count)
        case .unavailable:
            return String(localized: "Not readable")
        }
    }
}
