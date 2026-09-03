//
//  ScriptingApplication.swift
//  TablePro
//

import AppKit
import Foundation

/// What `tell application "TablePro"` can reach.
///
/// Cocoa Scripting finds elements through ordinary key-value coding on `NSApplication`, so the
/// dictionary's `connection` element is this property and nothing more is registered anywhere. The
/// two `valueIn…` accessors are the documented hooks for resolving `connection "prod"` and
/// `connection id "…"` without Cocoa walking the whole list, and the unique-id one is what makes a
/// reference returned by a command resolvable on a later event.
///
/// Nothing here runs at launch. Cocoa parses `TablePro.sdef` lazily, on the first Apple event the
/// app receives, so a session that is never scripted pays nothing for being scriptable.
internal extension NSApplication {
    @objc var scriptConnections: [ScriptConnection] {
        ScriptingSnapshot.connections()
    }

    @objc func valueInScriptConnections(withUniqueID id: Any) -> ScriptConnection? {
        guard let wanted = ScriptingSnapshot.uuid(from: id) else { return nil }
        return scriptConnections.first { $0.connectionId == wanted }
    }

    @objc func valueInScriptConnections(withName name: String) -> ScriptConnection? {
        scriptConnections.first { $0.name == name }
    }

    /// The connection the frontmost window is showing.
    @objc var scriptCurrentConnection: ScriptConnection? {
        ScriptingSnapshot.currentConnection()
    }

    /// The selected tab of the frontmost window, which is what `selection of current tab` reads.
    @objc var scriptCurrentTab: ScriptTab? {
        ScriptingSnapshot.currentTab()
    }
}
