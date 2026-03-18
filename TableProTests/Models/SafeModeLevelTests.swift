//
//  SafeModeLevelTests.swift
//  TableProTests
//

import SwiftUI
import Testing
@testable import TablePro

@Suite("SafeModeLevel")
struct SafeModeLevelTests {

    // MARK: - Raw Values

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(SafeModeLevel.silent.rawValue == "silent")
        #expect(SafeModeLevel.alert.rawValue == "alert")
        #expect(SafeModeLevel.alertFull.rawValue == "alertFull")
        #expect(SafeModeLevel.safeMode.rawValue == "safeMode")
        #expect(SafeModeLevel.safeModeFull.rawValue == "safeModeFull")
        #expect(SafeModeLevel.readOnly.rawValue == "readOnly")
    }

    // MARK: - Identifiable

    @Test("id returns rawValue for all cases")
    func idMatchesRawValue() {
        for level in SafeModeLevel.allCases {
            #expect(level.id == level.rawValue)
        }
    }

    // MARK: - CaseIterable

    @Test("allCases contains exactly 6 cases")
    func allCasesCount() {
        #expect(SafeModeLevel.allCases.count == 6)
    }

    // MARK: - displayName

    @Test("silent displayName")
    func displayNameSilent() {
        #expect(SafeModeLevel.silent.displayName == String(localized: "Silent"))
    }

    @Test("alert displayName")
    func displayNameAlert() {
        #expect(SafeModeLevel.alert.displayName == String(localized: "Alert"))
    }

    @Test("alertFull displayName")
    func displayNameAlertFull() {
        #expect(SafeModeLevel.alertFull.displayName == String(localized: "Alert (Full)"))
    }

    @Test("safeMode displayName")
    func displayNameSafeMode() {
        #expect(SafeModeLevel.safeMode.displayName == String(localized: "Safe Mode"))
    }

    @Test("safeModeFull displayName")
    func displayNameSafeModeFull() {
        #expect(SafeModeLevel.safeModeFull.displayName == String(localized: "Safe Mode (Full)"))
    }

    @Test("readOnly displayName")
    func displayNameReadOnly() {
        #expect(SafeModeLevel.readOnly.displayName == String(localized: "Read-Only"))
    }

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

    @Test("each case has the correct SF Symbol icon name")
    func iconNames() {
        #expect(SafeModeLevel.silent.iconName == "lock.open")
        #expect(SafeModeLevel.alert.iconName == "exclamationmark.triangle")
        #expect(SafeModeLevel.alertFull.iconName == "exclamationmark.triangle.fill")
        #expect(SafeModeLevel.safeMode.iconName == "lock.shield")
        #expect(SafeModeLevel.safeModeFull.iconName == "lock.shield.fill")
        #expect(SafeModeLevel.readOnly.iconName == "lock.fill")
    }

    // MARK: - badgeColor

    @Test("silent badge color is secondary")
    func badgeColorSilent() {
        #expect(SafeModeLevel.silent.badgeColor == .secondary)
    }

    @Test("alert and alertFull badge color is orange")
    func badgeColorAlert() {
        #expect(SafeModeLevel.alert.badgeColor == .orange)
        #expect(SafeModeLevel.alertFull.badgeColor == .orange)
    }

    @Test("safeMode, safeModeFull, and readOnly badge color is red")
    func badgeColorSafeAndReadOnly() {
        #expect(SafeModeLevel.safeMode.badgeColor == .red)
        #expect(SafeModeLevel.safeModeFull.badgeColor == .red)
        #expect(SafeModeLevel.readOnly.badgeColor == .red)
    }

    // MARK: - Codable

    @Test("round-trips through JSON encoding and decoding")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for level in SafeModeLevel.allCases {
            let data = try encoder.encode(level)
            let decoded = try decoder.decode(SafeModeLevel.self, from: data)
            #expect(decoded == level)
        }
    }
}
