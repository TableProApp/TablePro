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

    // The host wrote it against the engine's own catalogs, so `execute(query:context:)` may run it where only built-in
    // functions, operators and relations resolve. Honoured for the app's own statements only.
    public var readsCatalog = false

    // How the engine lexes this session's text, so the driver binds and quotes as the server reads. Nil from a host
    // that does not say.
    public var lexicalFeatures: SQLLexicalFeatures?

    // The type the user gave each parameter, by position: `.text` and `.other` are written as strings, `.integer` and
    // `.decimal` as numbers, `.boolean` as TRUE or FALSE. Nil, or a nil entry, where none was given.
    public var parameterKinds: [PluginColumnKind?]?

    public init() {}
}

public enum PluginStatementOrigin: Sendable, Equatable {
    case app
    // An MCP client, the AI assistant, AppleScript or Shortcuts.
    case external
}
