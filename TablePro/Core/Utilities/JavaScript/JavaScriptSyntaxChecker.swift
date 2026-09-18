//
//  JavaScriptSyntaxChecker.swift
//  TablePro
//

import Foundation
import JavaScriptCore

/// Reports the syntax errors in a JavaScript document, using the engine that will run it.
///
/// `JSCheckScriptSyntax` parses without evaluating, so an editor can underline a mistake with the
/// same verdict the runtime would give and without touching the database. Reimplementing a
/// JavaScript parser to do this would disagree with the engine sooner or later; this cannot.
enum JavaScriptSyntaxChecker {
    struct Failure {
        let message: String
        /// 1-based, as JavaScriptCore reports it.
        let line: Int
    }

    /// The first syntax error, or nil when the document parses.
    static func firstFailure(in source: String) -> Failure? {
        guard let context = JSContext() else { return nil }
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }

        var exception: JSValueRef?
        let parsed = JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception)
        guard !parsed, let exception else { return nil }

        let value = JSValue(jsValueRef: exception, in: context)
        let line = value?.objectForKeyedSubscript("line")?.toInt32() ?? 0
        let message = value?.objectForKeyedSubscript("message")?.toString()
            ?? value?.toString()
            ?? String(localized: "This is not valid JavaScript.")
        return Failure(message: message, line: max(1, Int(line)))
    }
}
