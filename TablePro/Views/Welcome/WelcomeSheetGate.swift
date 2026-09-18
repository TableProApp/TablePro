//
//  WelcomeSheetGate.swift
//  TablePro
//

import Foundation

internal enum WelcomeSheetGate {
    internal static func shouldPresent(hasSeen: Bool, isUITestSandbox: Bool, uiTestRequestsSheet: Bool) -> Bool {
        guard isUITestSandbox else { return !hasSeen }
        return uiTestRequestsSheet
    }
}
