//
//  RemoteSQLiteAdmissionTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct RemoteSQLiteAdmissionTests {
    @Test func acceptsTheMatchingToken() {
        let token = RemoteSQLiteAdmission.newToken()
        let line = Data((RemoteSQLiteWire.admissionPrefix + token).utf8)
        #expect(RemoteSQLiteAdmission.isAuthorized(line: line, token: token))
    }

    @Test func rejectsAWrongToken() {
        let line = Data((RemoteSQLiteWire.admissionPrefix + "0000").utf8)
        #expect(!RemoteSQLiteAdmission.isAuthorized(line: line, token: "1111"))
    }

    @Test func rejectsAMissingPrefix() {
        let line = Data("1111".utf8)
        #expect(!RemoteSQLiteAdmission.isAuthorized(line: line, token: "1111"))
    }

    @Test func rejectsAnEmptyTokenEvenWhenPresented() {
        let line = Data(RemoteSQLiteWire.admissionPrefix.utf8)
        #expect(!RemoteSQLiteAdmission.isAuthorized(line: line, token: ""))
    }

    @Test func rejectsALineOverTheLengthCap() {
        let token = String(repeating: "a", count: RemoteSQLiteAdmission.maxLineLength + 10)
        let line = Data((RemoteSQLiteWire.admissionPrefix + token).utf8)
        #expect(!RemoteSQLiteAdmission.isAuthorized(line: line, token: token))
    }

    @Test func newTokenIs64HexCharacters() {
        let token = RemoteSQLiteAdmission.newToken()
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
    }

    @Test func launcherCommandCarriesNoUserDataAndFitsThePacketLimit() {
        let command = RemoteSQLiteAgentSource.launcherCommand()
        #expect(command.hasPrefix("sh -c 'b="))
        #expect(command.contains(RemoteSQLiteWire.noPythonNotice))
        #expect(command.contains("zlib.decompress"))
        // The exec request is one SSH packet: this command plus SSH_MSG_CHANNEL_REQUEST framing.
        // libssh2 rejects a payload at or above MAX_SSH_PACKET_LEN - 0x100 (34744) with -34; 256 B
        // covers the framing and still leaves room to spare.
        #expect(command.utf8.count + 256 < 34_744)
    }
}
