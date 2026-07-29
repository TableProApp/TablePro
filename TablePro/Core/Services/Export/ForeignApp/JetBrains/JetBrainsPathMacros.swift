//
//  JetBrainsPathMacros.swift
//  TablePro
//

import Foundation

/// Expands the path macros JetBrains IDEs write into their config XML, such as
/// `$USER_HOME$` in SSH key paths and recent-project entries.
enum JetBrainsPathMacros {
    static func expand(_ path: String) -> String {
        path.replacingOccurrences(of: "$USER_HOME$", with: NSHomeDirectory())
    }
}
