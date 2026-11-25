//
//  SetupGuideGate.swift
//  TablePro
//

import Foundation

// The macOS rows of the gate table in core/docs/decisions/0049-a-setup-guide-shows-on-an-empty-library.md.
internal enum SetupGuideGate {
    internal enum Trigger: Equatable, Sendable {
        case launch
        case menu
    }

    internal struct Inputs: Equatable, Sendable {
        var trigger: Trigger
        var isUserSession: Bool
        var hasRoutedWork: Bool
        var isUITestSandbox: Bool
        var uiTestRequestsGuide: Bool
        var libraryReadable: Bool
        // The sample counts: it is a saved connection like any other.
        var connectionCount: Int
        var hasSeen: Bool
    }

    internal static func shouldPresent(_ inputs: Inputs) -> Bool {
        switch inputs.trigger {
        case .menu:
            return true
        case .launch:
            guard inputs.isUserSession, !inputs.hasRoutedWork else { return false }
            guard !inputs.isUITestSandbox || inputs.uiTestRequestsGuide else { return false }
            return inputs.libraryReadable && inputs.connectionCount == 0 && !inputs.hasSeen
        }
    }
}
