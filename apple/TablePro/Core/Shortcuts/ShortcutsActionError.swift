//
//  ShortcutsActionError.swift
//  TablePro
//

import AppIntents
import Foundation

// The reason a Shortcuts action stopped, already localized: a refusal keeps the gate's own wording, and a driver's
// error is redacted the way a script's is.
internal struct ShortcutsActionError: LocalizedError, Equatable, CustomLocalizedStringResourceConvertible {
    internal let message: String

    internal var errorDescription: String? { message }

    internal var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(message))
    }

    internal static func wrapping(_ error: Error, secrets: [String] = []) -> Error {
        switch error {
        case is ShortcutsActionError, is IntentDataError:
            return error
        default:
            let scripting = ScriptingError.from(error, secrets: secrets)
            return ShortcutsActionError(
                message: scripting.errorDescription ?? String(localized: "The operation failed.")
            )
        }
    }
}
