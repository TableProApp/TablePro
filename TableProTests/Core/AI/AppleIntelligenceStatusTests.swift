//
//  AppleIntelligenceStatusTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AppleIntelligenceStatus")
struct AppleIntelligenceStatusTests {
    @Test("Every status has reason text", arguments: [
        AppleIntelligenceStatus.available,
        .osNotSupported,
        .deviceNotEligible,
        .notEnabled,
        .modelNotReady,
        .unknown
    ])
    func statusTextNonEmpty(_ status: AppleIntelligenceStatus) {
        #expect(!status.statusText.isEmpty)
    }

    @Test("Only notEnabled offers to open System Settings")
    func canOpenSettingsOnlyWhenNotEnabled() {
        #expect(AppleIntelligenceStatus.notEnabled.canOpenSystemSettings)
        let others: [AppleIntelligenceStatus] = [
            .available, .osNotSupported, .deviceNotEligible, .modelNotReady, .unknown
        ]
        for status in others {
            #expect(!status.canOpenSystemSettings)
        }
    }

    @Test("isAvailable is true only for available")
    func isAvailableFlag() {
        #expect(AppleIntelligenceStatus.available.isAvailable)
        #expect(!AppleIntelligenceStatus.modelNotReady.isAvailable)
        #expect(!AppleIntelligenceStatus.notEnabled.isAvailable)
    }

    @Test("Facade returns a defined status")
    func facadeReturnsDefinedStatus() {
        let valid: Set<AppleIntelligenceStatus> = [
            .available, .osNotSupported, .deviceNotEligible, .notEnabled, .modelNotReady, .unknown
        ]
        #expect(valid.contains(AppleIntelligenceAvailability.currentStatus()))
    }
}
