import Foundation

/// The messages the script runtime shows a user.
///
/// Gathered here rather than spelled at each throw site because the same wording has to reach the
/// result pane, the diagnostics gutter and the log, and because a message built by interpolating
/// into `String(localized:)` produces a key that never matches the catalog.
enum MongoScriptText {
    static func invalidDocument(_ text: String) -> String {
        String(format: String(localized: "This is not a document MongoDB can read: %@"), text)
    }

    static func invalidFilter(_ text: String) -> String {
        String(format: String(localized: "This filter is not a document MongoDB can read: %@"), text)
    }

    static func invalidPipeline(_ text: String) -> String {
        String(format: String(localized: "This pipeline is not something MongoDB can read: %@"), text)
    }

    static var cursorFailed: String {
        String(localized: "MongoDB did not return a cursor for this query.")
    }

    static func unsupportedCursorOption(_ key: String) -> String {
        String(format: String(localized: "A cursor has no .%@() modifier."), key)
    }

    static func wholeNumberExpected(_ key: String) -> String {
        String(format: String(localized: ".%@() takes a whole number."), key)
    }

    static func unsupportedBulkOperation(_ text: String) -> String {
        String(format: String(localized: "bulkWrite does not know this operation: %@"), text)
    }

    static var cancelled: String {
        String(localized: "The script was cancelled.")
    }

    static func unknownOperation(_ name: String) -> String {
        String(format: String(localized: "Unsupported script operation: %@"), name)
    }

    static var unknownCursor: String {
        String(localized: "This cursor has already been closed.")
    }

    static func cursorAlreadyStarted(_ key: String) -> String {
        String(format: String(localized: ".%@() cannot be set once the cursor has started."), key)
    }

    static var scriptEngineUnavailable: String {
        String(localized: "The MongoDB script engine could not start.")
    }

    static func timedOut(_ seconds: TimeInterval) -> String {
        String(
            format: String(localized: "The script did not finish within %d seconds and was abandoned."),
            Int(seconds.rounded())
        )
    }

    static func printedLines(_ count: Int) -> String {
        String(format: String(localized: "%d line(s) printed"), count)
    }

    static var outputColumn: String {
        String(localized: "output")
    }

    static var resultColumn: String {
        String(localized: "result")
    }

    static func switchedDatabase(_ name: String) -> String {
        String(format: String(localized: "Switched to %@"), name)
    }
}
