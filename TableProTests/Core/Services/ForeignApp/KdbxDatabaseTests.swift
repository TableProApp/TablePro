//
//  KdbxDatabaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("KdbxDatabase")
struct KdbxDatabaseTests {
    @Test("reads entry and decrypts ChaCha20-protected password")
    func roundTrip() throws {
        let mainKey: [UInt8] = Array("super-secret-main-key".utf8)
        let title = "IntelliJ Platform DB \u{2014} a1b2c3"
        let fileData = KdbxTestFixture.makeKdbx(
            mainKey: mainKey,
            title: title,
            userName: "dbuser",
            password: "p@ssw0rd!"
        )

        let entries = try KdbxDatabase.read(fileData: fileData, mainKey: mainKey)
        let entry = entries.first { $0.title == title }

        #expect(entry != nil)
        #expect(entry?.userName == "dbuser")
        #expect(entry?.password == "p@ssw0rd!")
    }

    @Test("reads gzip-compressed KDBX payload")
    func compressedRoundTrip() throws {
        let mainKey: [UInt8] = Array("compressed-main-key".utf8)
        let title = "IntelliJ Platform DB \u{2014} gz"
        let fileData = KdbxTestFixture.makeKdbx(
            mainKey: mainKey,
            title: title,
            userName: "dbuser",
            password: "p@ssw0rd!",
            compressed: true
        )

        let entries = try KdbxDatabase.read(fileData: fileData, mainKey: mainKey)
        let entry = entries.first { $0.title == title }

        #expect(entry?.userName == "dbuser")
        #expect(entry?.password == "p@ssw0rd!")
    }

    @Test("wrong main key is rejected by stream-start check")
    func wrongKeyThrows() {
        let fileData = KdbxTestFixture.makeKdbx(
            mainKey: Array("correct".utf8),
            title: "t",
            userName: "u",
            password: "p"
        )

        #expect(throws: (any Error).self) {
            _ = try KdbxDatabase.read(fileData: fileData, mainKey: Array("incorrect".utf8))
        }
    }

    @Test("malformed signature throws")
    func malformedThrows() {
        #expect(throws: (any Error).self) {
            _ = try KdbxDatabase.read(fileData: Data([0x00, 0x01, 0x02, 0x03]), mainKey: [])
        }
    }
}
