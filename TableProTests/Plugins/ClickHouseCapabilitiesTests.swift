//
//  ClickHouseCapabilitiesTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("ClickHouse Capabilities")
struct ClickHouseCapabilitiesTests {
    @Test("The write-exception setting needs ClickHouse 23.8 or later")
    func writeExceptionSettingGate() {
        #expect(!ClickHouseCapabilities.parse("23.7").hasWriteExceptionInOutputFormatSetting)
        #expect(ClickHouseCapabilities.parse("23.8").hasWriteExceptionInOutputFormatSetting)
        #expect(ClickHouseCapabilities.parse("23.8.1.94").hasWriteExceptionInOutputFormatSetting)
        #expect(ClickHouseCapabilities.parse("24.1").hasWriteExceptionInOutputFormatSetting)
        #expect(!ClickHouseCapabilities.parse("19.17").hasWriteExceptionInOutputFormatSetting)
    }

    @Test("An unknown server version is treated as unsupported")
    func unknownVersionIsUnsupported() {
        #expect(!ClickHouseCapabilities.parse(nil).hasWriteExceptionInOutputFormatSetting)
        #expect(!ClickHouseCapabilities.parse("garbage").hasWriteExceptionInOutputFormatSetting)
    }
}
