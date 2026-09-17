//
//  LogRedaction.swift
//  TablePro
//

import Foundation

/// An error type whose whole description is the app's own vocabulary, with nothing a server or a
/// person supplied inside it. Conforming says the description is safe to publish in the system log.
///
/// Conform only when every case's text is a literal the app wrote. A case that interpolates a
/// server message, a table name, a path or a value is not publicly loggable, however app-owned the
/// type is.
internal protocol PubliclyLoggableError: Error {
    var publicLogDescription: String { get }
}

/// `Logger` redacts an interpolated value by default, and Apple's own reason is that it "prevents
/// the system from leaking potentially user-sensitive information in the log files". An error's
/// text is at once the most useful thing in a log line and the likeliest to carry someone's data:
/// PostgreSQL puts the offending value in a unique-violation message (`Key (email)=(a@b.com)`),
/// MySQL puts row data in its duplicate-key message, and a file error carries the person's paths.
///
/// So an error contributes two things to a line: a shape that is safe to publish, and a description
/// that is not. This publishes the first; the call site logs the second at `.private`, where a
/// developer with a logging profile can still read it and a shared sysdiagnose cannot.
internal enum LogRedaction {
    internal static func publicDescription(of error: Error) -> String {
        if let loggable = error as? PubliclyLoggableError {
            return loggable.publicLogDescription
        }

        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)

        guard mirror.displayStyle == .enum else {
            let nsError = error as NSError
            guard !nsError.domain.hasSuffix(typeName) else { return "\(typeName)(\(nsError.code))" }
            return "\(typeName)(\(nsError.domain), \(nsError.code))"
        }

        /// An enum case with a payload reports the case name as its single child's label, and the
        /// payload is what would carry the text. A case without one prints as its own name.
        if let caseName = mirror.children.first?.label {
            return "\(typeName).\(caseName)"
        }
        return "\(typeName).\(error)"
    }
}

internal extension Error {
    /// The part of this error that is safe to publish in the system log. The description itself is
    /// not: log it at `.private` beside this where a support workflow needs it.
    var publicLogShape: String { LogRedaction.publicDescription(of: self) }
}
