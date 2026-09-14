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

    @Test func launcherCommandCarriesNoUserDataAndFitsTheArgumentLimit() {
        let command = RemoteSQLiteAgentSource.launcherCommand()
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains(RemoteSQLiteWire.noPythonNotice))
        #expect(command.contains("base64.b64decode"))
        // Well under the Linux MAX_ARG_STRLEN of 128 KiB.
        #expect(command.utf8.count < 100_000)
    }
}
