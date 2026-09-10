//
//  ScriptingSpecifiers.swift
//  TablePro
//

import AppKit
import Foundation

/// How a scriptable object says where it lives.
///
/// Every specifier is built by unique id rather than by name or index. A connection can be renamed
/// and two can share a name, and a tab's position moves whenever another one is opened or closed, so
/// a reference built on either would silently start pointing at something else. Name and index
/// lookups still work for the script author; they are just not what a returned reference is made of.
@MainActor
internal enum ScriptingSpecifiers {
    internal static func connection(uniqueId: String) -> NSScriptObjectSpecifier? {
        guard let application = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: ScriptingKeys.Element.connections,
            uniqueID: uniqueId
        )
    }

    internal static func tab(uniqueId: String, container: NSScriptObjectSpecifier?) -> NSScriptObjectSpecifier? {
        guard let container,
              let description = container.keyClassDescription
        else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: description,
            containerSpecifier: container,
            key: ScriptingKeys.Element.tabs,
            uniqueID: uniqueId
        )
    }
}
