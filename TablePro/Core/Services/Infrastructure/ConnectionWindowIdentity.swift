//
//  ConnectionWindowIdentity.swift
//  TablePro
//

import Foundation

internal enum ConnectionWindowIdentity {
    internal static let connectionWindow = "main"
    internal static let documentInspectorWindow = "main-inspector"

    internal static func isConnectionWindow(_ identifier: String?) -> Bool {
        identifier == connectionWindow
    }

    internal static func isDocumentInspectorWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == documentInspectorWindow
            || identifier.hasPrefix("\(documentInspectorWindow)-")
    }

    internal static func isPrimaryWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == connectionWindow || identifier.hasPrefix("\(connectionWindow)-")
    }

    internal static func isWelcomeWindow(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == SceneId.welcome || identifier.hasPrefix("\(SceneId.welcome)-")
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
