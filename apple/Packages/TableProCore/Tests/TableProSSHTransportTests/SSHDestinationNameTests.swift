//
//  SSHDestinationNameTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHDestinationNameTests {
    @Test("A host ssh refuses is refused", arguments: [
        "db$(touch /tmp/pwned).internal.example",
        "db`touch /tmp/pwned`.internal.example",
        "db;touch /tmp/pwned;.internal.example",
        "db|sh.internal.example",
        "db.internal.example\\",
        "db\n.internal.example",
        "replica.attacker.example\n[prod.corp.example",
        "db .example.com",
        "db\t.example.com",
        "db\r.example.com",
        "db\u{202E}.example.com",
        "-oProxyCommand=touch /tmp/pwned",
        "db'x.example.com",
        "db\"x.example.com",
        "db,evil.example",
    ])
    func hostileHostIsRefused(host: String) {
        #expect(!SSHDestinationName.isValidHost(host))
        #expect(SSHDestinationName.problem(host: host, user: "deploy") == .host(host))
    }

    @Test("A host ssh accepts is accepted", arguments: [
        "db.example.com",
        "10.0.0.5",
        "fe80::1%en0",
        "[fd00::5]",
        "bücher.example",
        "db_1.example.com",
        "",
    ])
    func ordinaryHostIsAccepted(host: String) {
        #expect(SSHDestinationName.isValidHost(host))
    }

    @Test("A user ssh would let reach a shell is refused", arguments: [
        "x; touch /tmp/pwned; true",
        "x$(touch /tmp/pwned)",
        "x\ntouch /tmp/pwned",
        "-oProxyCommand=touch /tmp/pwned",
        "x -oProxyCommand=touch",
        "x\\",
        "x\u{0}y",
        "x\ty",
    ])
    func hostileUserIsRefused(user: String) {
        #expect(!SSHDestinationName.isValidUser(user))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: user) == .user(user))
    }

    @Test("A user ssh accepts is accepted", arguments: [
        "deploy",
        "DOMAIN\\deploy",
        "first last",
        "bob,evil.example.net",
        "user@realm",
        "backup$",
        "",
    ])
    func ordinaryUserIsAccepted(user: String) {
        #expect(SSHDestinationName.isValidUser(user))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: user) == nil)
    }

    @Test("The explanation names the refused value")
    func explanationNamesTheValue() {
        #expect(SSHDestinationName.Problem.host("a;b").explanation.contains("a;b"))
        #expect(SSHDestinationName.Problem.user("c|d").explanation.contains("c|d"))
    }
}
