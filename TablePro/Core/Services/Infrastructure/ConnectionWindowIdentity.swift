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
    /// A machine-started session answers the close of its last window by going back to the
    /// background, not by opening the connection list. Nobody asked for the window that just closed,
    /// so replacing it with another one the person did not request is the wrong answer.
    internal static func shouldPresentWelcome(
        closingWindowWasPrimary: Bool,
        remainingVisiblePrimaryWindows: Int,
        sessionOrigin: AppSessionOrigin
    ) -> Bool {
        sessionOrigin == .user && closingWindowWasPrimary && remainingVisiblePrimaryWindows == 0
    }
}
