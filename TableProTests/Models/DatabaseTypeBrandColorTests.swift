//
//  DatabaseTypeBrandColorTests.swift
//  TableProTests
//
//  A database type's colour has one source: the plugin that declares it. The app used to carry a
//  second, hand-written table beside the registry, and the two had drifted on 12 of the 23 types
//  they both named, so one MySQL connection was teal in the type chooser and orange in the toolbar.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Database type brand colour")
struct DatabaseTypeBrandColorTests {
    /// The reason the hand-written fallback table could be deleted outright rather than kept for
    /// the types the registry might not cover. If this fails, some type has lost its registry
    /// entry and is now drawn in the grey fallback rather than its own colour.
    @Test("Every known type gets its colour from the plugin registry")
    func everyKnownTypeHasRegistryBranding() {
        for type in DatabaseType.allKnownTypes {
            let hex = PluginMetadataRegistry.shared.snapshot(for: type)?.brandColorHex
            guard let hex else {
                Issue.record("\(type.rawValue) has no registry snapshot, so it would draw grey")
                continue
            }
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            #expect(
                digits.count == 6 && digits.allSatisfy(\.isHexDigit),
                "\(type.rawValue) declares an unusable brand colour: \(hex)"
            )
        }
    }

    /// `themeColor` is the only accessor now. It reads the registry, so the colour a connection is
    /// drawn in cannot disagree with the colour its type is drawn in.
    @Test("themeColor reads the registry rather than a table of its own")
    func themeColorFollowsTheRegistry() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .redis] {
            #expect(type.themeColor == PluginManager.shared.brandColor(for: type))
        }
    }
}
