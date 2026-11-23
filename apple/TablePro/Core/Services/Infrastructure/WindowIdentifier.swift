//
//  WindowIdentifier.swift
//  TablePro
//

import Foundation

// The first group doubles as each window's frame autosave name, so changing one throws away the position the
// user arranged. `ConnectionWindowIdentity` and `WindowManager` match the last group by prefix, so `dataFile`
// stays under the `connection` prefix or an open data file window stops counting as a primary window.
internal enum WindowIdentifier {
    internal static let welcome = "welcome"
    internal static let integrationsActivity = "integrations-activity"
    internal static let settings = "settings"
    internal static let acknowledgements = "acknowledgements"
    internal static let support = "support"
    internal static let compareSync = "compare-sync"
    internal static let signIn = "sign-in"

    // The connection editor's frame saves under `ConnectionEditorWindowFrame.autosaveName`.
    internal static let connectionForm = "connection-form"

    internal static let connection = "main"
    internal static let dataFile = "main-data-file"
}
