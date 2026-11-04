//
//  KdbxDatabaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

    @Test("A numeric header field shorter than its type is malformed, not read past its end")
    func shortNumericHeaderField() {
        var file = KdbxTestFixture.le32(0x9AA2_D903) + KdbxTestFixture.le32(0xB54B_FB67) + KdbxTestFixture.le32(0x0003_0001)
        file += [6, 2, 0, 0xff, 0xff]
        file += [0, 0, 0]
        #expect(throws: KdbxError.malformedHeader) {
            _ = try KdbxDatabase.read(fileData: Data(file), mainKey: Array("key".utf8))
        }
    }

    @Test("A protected value of an unknown inner stream is never taken as the password")
    func unknownInnerStreamPassword() throws {
        let mainKey: [UInt8] = Array("unknown-stream-key".utf8)
        let title = "IntelliJ Platform DB \u{2014} unknown"
        let fileData = KdbxTestFixture.makeKdbx(
            mainKey: mainKey,
            title: title,
            userName: "dbuser",
            password: "p@ssw0rd!",
            innerStreamID: 99
        )

        let entry = try #require(try KdbxDatabase.read(fileData: fileData, mainKey: mainKey).first { $0.title == title })

        #expect(entry.password.isEmpty)
    }

    @Test("A key derivation past the round limit is refused before any work")
    func transformRoundsPastLimit() {
        let mainKey: [UInt8] = Array("rounds-key".utf8)
        let fileData = KdbxTestFixture.replacingTransformRounds(
            in: KdbxTestFixture.makeKdbx(mainKey: mainKey, title: "t", userName: "u", password: "p"),
            with: 50_000_001
        )

        #expect(throws: KdbxError.malformedHeader) {
            _ = try KdbxDatabase.read(fileData: fileData, mainKey: mainKey)
        }
    }

    @Test("A compressed body that inflates past 16 MiB is refused")
    func oversizedCompressedBody() {
        let mainKey: [UInt8] = Array("inflating-key".utf8)
        let fileData = KdbxTestFixture.makeKdbx(
            mainKey: mainKey,
            title: "t",
            userName: "u",
            password: "p",
            compressed: true,
            paddingByteCount: 16 * 1_024 * 1_024
        )

        #expect(throws: KdbxError.corruptedData) {
            _ = try KdbxDatabase.read(fileData: fileData, mainKey: mainKey)
        }
    }
}
