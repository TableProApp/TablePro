//
//  ConnectionWindowIdentity.swift
//  TablePro
//

import Foundation

internal enum ConnectionWindowIdentity {
    internal static func isConnectionWindow(_ identifier: String?) -> Bool {
        identifier == WindowIdentifier.connection
    }

    internal static func isDocumentInspectorWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == WindowIdentifier.documentInspector
            || identifier.hasPrefix("\(WindowIdentifier.documentInspector)-")
    }

    internal static func isPrimaryWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == WindowIdentifier.connection
            || identifier.hasPrefix("\(WindowIdentifier.connection)-")
    }

    internal static func isWelcomeWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == WindowIdentifier.welcome
            || identifier.hasPrefix("\(WindowIdentifier.welcome)-")
    }
}

internal enum WelcomeVisibilityPolicy {
    internal static func shouldPresentWelcome(
        closingWindowWasPrimary: Bool,
        remainingVisiblePrimaryWindows: Int
    ) -> Bool {
        closingWindowWasPrimary && remainingVisiblePrimaryWindows == 0
    }
}
