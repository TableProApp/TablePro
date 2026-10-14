//
//  SafeModeLevelTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

struct SafeModeLevelTests {
    // MARK: - blocksAllWrites

    @Test("only readOnly blocks all writes")
    func blocksAllWrites() {
        #expect(SafeModeLevel.silent.blocksAllWrites == false)
        #expect(SafeModeLevel.alert.blocksAllWrites == false)
        #expect(SafeModeLevel.alertFull.blocksAllWrites == false)
        #expect(SafeModeLevel.safeMode.blocksAllWrites == false)
        #expect(SafeModeLevel.safeModeFull.blocksAllWrites == false)
        #expect(SafeModeLevel.readOnly.blocksAllWrites == true)
    }

    // MARK: - requiresConfirmation

    @Test("alert, alertFull, safeMode, safeModeFull require confirmation")
    func requiresConfirmation() {
        #expect(SafeModeLevel.silent.requiresConfirmation == false)
        #expect(SafeModeLevel.alert.requiresConfirmation == true)
        #expect(SafeModeLevel.alertFull.requiresConfirmation == true)
        #expect(SafeModeLevel.safeMode.requiresConfirmation == true)
        #expect(SafeModeLevel.safeModeFull.requiresConfirmation == true)
        #expect(SafeModeLevel.readOnly.requiresConfirmation == false)
    }

    // MARK: - requiresAuthentication

    @Test("safeMode and safeModeFull require authentication")
    func requiresAuthentication() {
        #expect(SafeModeLevel.silent.requiresAuthentication == false)
        #expect(SafeModeLevel.alert.requiresAuthentication == false)
        #expect(SafeModeLevel.alertFull.requiresAuthentication == false)
        #expect(SafeModeLevel.safeMode.requiresAuthentication == true)
        #expect(SafeModeLevel.safeModeFull.requiresAuthentication == true)
        #expect(SafeModeLevel.readOnly.requiresAuthentication == false)
    }

    // MARK: - appliesToAllQueries

    @Test("alertFull and safeModeFull apply to all queries")
    func appliesToAllQueries() {
        #expect(SafeModeLevel.silent.appliesToAllQueries == false)
        #expect(SafeModeLevel.alert.appliesToAllQueries == false)
        #expect(SafeModeLevel.alertFull.appliesToAllQueries == true)
        #expect(SafeModeLevel.safeMode.appliesToAllQueries == false)
        #expect(SafeModeLevel.safeModeFull.appliesToAllQueries == true)
        #expect(SafeModeLevel.readOnly.appliesToAllQueries == false)
    }

    // MARK: - iconName

    /// The fill used to mark two of the four levels that gate reads and both of the two that do
    /// not, so it said nothing. The weakest level drew the heaviest glyph in the toolbar.
    @Test("An icon is filled exactly when its level applies to all queries", arguments: SafeModeLevel.allCases)
    func fillMeansTheLevelAppliesToAllQueries(level: SafeModeLevel) {
        #expect(level.iconName.hasSuffix(".fill") == level.appliesToAllQueries)
    }

    /// The toolbar glyph is re-read only when the name changes, so two levels sharing one would
    /// leave the previous level's glyph in place.
    @Test("Every level draws its own symbol, and each one exists")
    func iconNamesAreDistinctAndResolve() {
        let names = SafeModeLevel.allCases.map(\.iconName)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not a system symbol"
            )
        }
    }

    // MARK: - Codable

    @Test("A macOS wire value decodes to its own level", arguments: SafeModeLevel.allCases)
    func decodesOwnWireValues(_ level: SafeModeLevel) {
        #expect(SafeModeLevel(wireValue: level.rawValue, isReadOnly: false) == level)
    }

    @Test("iOS wire values map to the nearest macOS level")
    func decodesIOSWireValues() {
        #expect(SafeModeLevel(wireValue: "off", isReadOnly: false) == .silent)
        #expect(SafeModeLevel(wireValue: "confirmWrites", isReadOnly: false) == .alert)
        #expect(SafeModeLevel(wireValue: "readOnly", isReadOnly: false) == .readOnly)
    }

    @Test("An unrecognized wire value requires confirmation instead of failing open")
    func unknownWireValueFailsClosed() {
        #expect(SafeModeLevel(wireValue: "someFutureLevel", isReadOnly: false) == .alert)
        #expect(SafeModeLevel(wireValue: "someFutureLevel", isReadOnly: true) == .readOnly)
    }

    @Test("A missing wire value honors the read-only flag")
    func missingWireValueHonorsReadOnly() {
        #expect(SafeModeLevel(wireValue: nil, isReadOnly: true) == .readOnly)
        #expect(SafeModeLevel(wireValue: nil, isReadOnly: false) == .silent)
    }
}
