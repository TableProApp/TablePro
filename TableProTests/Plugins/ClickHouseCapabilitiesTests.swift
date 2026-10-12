//
//  ClickHouseCapabilitiesTests.swift
//  TableProTests
//

import Foundation
import Testing

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
        #expect(!ClickHouseCapabilities.parse(nil).hasModifyComment)
        #expect(!ClickHouseCapabilities.parse("garbage").hasModifyComment)
    }

    @Test("MODIFY COMMENT needs ClickHouse 23.9 or later")
    func modifyCommentGate() {
        #expect(!ClickHouseCapabilities.parse("23.8").hasModifyComment)
        #expect(!ClickHouseCapabilities.parse("23.8.16.40").hasModifyComment)
        #expect(!ClickHouseCapabilities.parse("22.12").hasModifyComment)
        #expect(ClickHouseCapabilities.parse("23.9").hasModifyComment)
        #expect(ClickHouseCapabilities.parse("23.9.1.1854").hasModifyComment)
        #expect(ClickHouseCapabilities.parse("23.12").hasModifyComment)
        #expect(ClickHouseCapabilities.parse("24.3.2.23").hasModifyComment)
    }
}
