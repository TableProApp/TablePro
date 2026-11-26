//
//  AccountCodes.swift
//  TablePro
//

import Foundation

// Codes a newer server adds read as neutral text, never as a failure.
nonisolated internal enum AccountCodes {
    // A Linux app reports its distribution as the OS version ("Fedora 43"), and the iOS app its system with it
    // ("iPadOS 26.1").
    static func systemName(platform: String, osVersion: String) -> String {
        switch platform {
        case "macos":
            return osVersion.isEmpty ? "macOS" : String(format: String(localized: "macOS %@"), osVersion)
        case "linux":
            return osVersion.isEmpty ? "Linux" : osVersion
        default:
            return osVersion
        }
    }
}
