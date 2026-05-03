//
//  KeychainHelperTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("KeychainHelper")
struct KeychainHelperTests {
    private let helper = KeychainHelper.shared

    @Test("writeString and readString round trip")
    func writeAndReadStringRoundTrip() {
        let key = "test.string.roundtrip.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        let saved = helper.writeString("hello", forKey: key)
        #expect(saved)

        let loaded = helper.readString(forKey: key)
        #expect(loaded == "hello")
    }

    @Test("write and read Data round trip")
    func writeAndReadDataRoundTrip() {
        let key = "test.data.roundtrip.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        let payload = Data([0x00, 0x01, 0x02, 0xFF])
        let saved = helper.write(payload, forKey: key)
        #expect(saved)

        let result = helper.read(forKey: key)
        #expect(result == .found(payload))
    }

    @Test("delete removes item; subsequent read returns notFound")
    func deleteRemovesItem() {
        let key = "test.delete.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("temporary", forKey: key)
        helper.delete(forKey: key)

        #expect(helper.read(forKey: key) == .notFound)
        #expect(helper.readString(forKey: key) == nil)
    }

    @Test("write overwrites existing value")
    func writeOverwritesExistingValue() {
        let key = "test.upsert.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("first", forKey: key)
        _ = helper.writeString("second", forKey: key)

        #expect(helper.readString(forKey: key) == "second")
    }

    @Test("read returns notFound for missing key")
    func readReturnsNotFoundForMissingKey() {
        let key = "test.missing.\(UUID().uuidString)"
        #expect(helper.read(forKey: key) == .notFound)
        #expect(helper.readString(forKey: key) == nil)
        #expect(helper.readStringResult(forKey: key) == .notFound)
    }

    @Test("readStringResult exposes found case")
    func readStringResultExposesFound() {
        let key = "test.stringresult.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("payload", forKey: key)
        #expect(helper.readStringResult(forKey: key) == .found("payload"))
    }

    @Test("password sync flag defaults to false when unset")
    func passwordSyncFlagDefaultsFalse() {
        let defaultsKey = KeychainHelper.passwordSyncEnabledKey
        let previous = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == false)
    }
}
