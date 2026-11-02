//
//  PluginStatementContext.swift
//  TableProPluginKit
//

import Foundation

// Not `@frozen`, and every field is a `var` with a default, so a later field is additive.
public struct PluginStatementContext: Sendable, Equatable {
    // From an external origin, a driver that declares `PluginCapabilities.readOnlyStatements` runs the statement in
    // the engine's read-only mode and throws when the session state does not allow it. A scripting driver refuses
    // every write whatever the origin.
    public var readOnly = false

    public var origin: PluginStatementOrigin = .app

    // The host already cut the text into the statement it approved, so the driver must not split it again.
    public var hostSplit = false

    // False when the approval did not cover dropping or emptying data.
    public var allowsDestructive = true

    // False when the statement may not run code on the server or reach its files.
    public var allowsServerCode = true

    public init() {}
}

public enum PluginStatementOrigin: Sendable, Equatable {
    case app
    // An MCP client, the AI assistant, AppleScript or Shortcuts.
    case external
}
