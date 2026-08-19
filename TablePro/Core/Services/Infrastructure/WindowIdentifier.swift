//
//  WindowIdentifier.swift
//  TablePro
//

import Foundation

/// The first group doubles as each window's frame autosave name, so changing one of those values
/// throws away the position the user arranged. The second group is matched by prefix at runtime by
/// `ConnectionWindowIdentity` and `WindowManager`, so `documentInspector` has to stay under the
/// `connection` prefix or an open inspector stops counting as a primary window.
internal enum WindowIdentifier {
    internal static let welcome = "welcome"
    internal static let connectionForm = "connection-form"
    internal static let integrationsActivity = "integrations-activity"
    internal static let settings = "settings"
    internal static let acknowledgements = "acknowledgements"

    internal static let connection = "main"
    internal static let documentInspector = "main-inspector"
}
