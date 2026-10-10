//
//  MySQLLocalSocketTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MySQLLocalSocketTests {
    @Test("The field key and default path the app and driver share")
    func constants() {
        #expect(MySQLLocalSocket.fieldKey == "localSocketPath")
        #expect(MySQLLocalSocket.defaultPath == "/tmp/mysql.sock")
        #expect(MySQLLocalSocket.maximumPathBytes == 103)
    }

    @Test("A missing, empty or blank field means no socket, and the path is trimmed")
    func pathFromFields() {
        #expect(MySQLLocalSocket.path(in: [:]) == nil)
        #expect(MySQLLocalSocket.path(in: ["localSocketPath": ""]) == nil)
        #expect(MySQLLocalSocket.path(in: ["localSocketPath": "  \n"]) == nil)
        #expect(MySQLLocalSocket.path(in: ["sshForwardUnixSocketPath": "/tmp/mysql.sock"]) == nil)
        #expect(MySQLLocalSocket.path(in: ["localSocketPath": " /tmp/mysql.sock\n"]) == "/tmp/mysql.sock")
    }

    @Test("A relative path is rejected")
    func relativePath() {
        #expect(MySQLLocalSocket.issue(for: "mysql.sock") == .notAbsolute)
        #expect(MySQLLocalSocket.issue(for: "~/mysql.sock") == .notAbsolute)
        #expect(MySQLLocalSocket.issue(for: "./mysql.sock") == .notAbsolute)
        #expect(MySQLLocalSocket.issue(for: "/tmp/mysql.sock") == nil)
        #expect(MySQLLocalSocket.issue(for: MySQLLocalSocket.defaultPath) == nil)
    }

    @Test(
        "A NUL, control or invisible character is rejected",
        arguments: ["/tmp/prod.sock\u{0}/../dev.sock", "/tmp/a\nb.sock", "/tmp/\u{202E}kcos.b", "/tmp/a\u{200B}.sock", "/tmp/a\u{7F}.sock"]
    )
    func hiddenCharacters(_ path: String) {
        #expect(MySQLLocalSocket.issue(for: path) == .hiddenCharacter)
    }

    @Test("A space or non-ASCII letter is still a valid path")
    func visibleCharacters() {
        #expect(MySQLLocalSocket.issue(for: "/Users/me/Library/Application Support/Local/mysqld.sock") == nil)
        #expect(MySQLLocalSocket.issue(for: "/tmp/caf\u{E9}.sock") == nil)
    }

    @Test("The limit is 103 UTF-8 bytes, not 103 characters")
    func byteLimit() {
        let twoByte = "\u{E9}"
        let atLimit = "/" + String(repeating: twoByte, count: 51)
        #expect(atLimit.utf8.count == 103)
        #expect(MySQLLocalSocket.issue(for: atLimit) == nil)

        let overLimit = atLimit + "a"
        #expect(overLimit.utf8.count == 104)
        #expect(MySQLLocalSocket.issue(for: overLimit) == .tooLong(bytes: 104))

        let fewCharactersManyBytes = "/" + String(repeating: twoByte, count: 60)
        #expect(fewCharactersManyBytes.count == 61)
        #expect(MySQLLocalSocket.issue(for: fewCharactersManyBytes) == .tooLong(bytes: 121))

        let asciiAtLimit = "/" + String(repeating: "a", count: 102)
        #expect(MySQLLocalSocket.issue(for: asciiAtLimit) == nil)
        #expect(MySQLLocalSocket.issue(for: asciiAtLimit + "a") == .tooLong(bytes: 104))
    }

    @Test("Each issue names the problem and the numbers")
    func issueMessages() {
        #expect(MySQLLocalSocket.PathIssue.notAbsolute.message.contains("/"))
        let tooLong = MySQLLocalSocket.PathIssue.tooLong(bytes: 104).message
        #expect(tooLong.contains("104"))
        #expect(tooLong.contains("103"))
    }

    @Test("Preferred stays plaintext over a socket; every stricter mode encrypts on both transports")
    func tlsRule() {
        let cases: [(mode: SSLMode, socket: Bool, tcp: Bool)] = [
            (.disabled, false, false),
            (.preferred, false, true),
            (.required, true, true),
            (.verifyCa, true, true),
            (.verifyIdentity, true, true)
        ]
        let coveredModes = cases.map { $0.mode }
        #expect(coveredModes == SSLMode.allCases)
        for entry in cases {
            #expect(MySQLLocalSocket.attemptsTLS(entry.mode, overSocket: true) == entry.socket, "\(entry.mode) over a socket")
            #expect(MySQLLocalSocket.attemptsTLS(entry.mode, overSocket: false) == entry.tcp, "\(entry.mode) over TCP")
        }
    }
}
