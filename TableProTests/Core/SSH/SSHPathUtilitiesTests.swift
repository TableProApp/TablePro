//
//  SSHPathUtilitiesTests.swift
//  TableProTests
//
//  Tests for SSH path utilities and token expansion
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SSH Path Utilities")
struct SSHPathUtilitiesTests {
    @Test("expandTilde expands ~/")
    func testExpandTilde() {
        let result = SSHPathUtilities.expandTilde("~/.ssh/id_rsa")
        let homeDir = NSHomeDirectory()
        #expect(result == "\(homeDir)/.ssh/id_rsa")
    }

    @Test("expandTilde returns absolute paths unchanged")
    func testExpandTildeAbsolutePath() {
        let result = SSHPathUtilities.expandTilde("/etc/ssh/id_rsa")
        #expect(result == "/etc/ssh/id_rsa")
    }

    @Test("expandSSHTokens expands %d to home directory")
    func testExpandTokenD() {
        let homeDir = NSHomeDirectory()
        let result = SSHPathUtilities.expandSSHTokens("%d/.ssh/key")
        #expect(result == "\(homeDir)/.ssh/key")
    }

    @Test("expandSSHTokens expands %h to hostname")
    func testExpandTokenH() {
        let result = SSHPathUtilities.expandSSHTokens(
            "/keys/%h/id_rsa",
            hostname: "example.com"
        )
        #expect(result == "/keys/example.com/id_rsa")
    }

    @Test("expandSSHTokens expands %u to local username")
    func testExpandTokenU() {
        let localUser = NSUserName()
        let result = SSHPathUtilities.expandSSHTokens("/keys/%u/id_rsa")
        #expect(result == "/keys/\(localUser)/id_rsa")
    }

    @Test("expandSSHTokens expands %r to remote username")
    func testExpandTokenR() {
        let result = SSHPathUtilities.expandSSHTokens(
            "/keys/%r/id_rsa",
            remoteUser: "deploy"
        )
        #expect(result == "/keys/deploy/id_rsa")
    }

    @Test("expandSSHTokens preserves %% as literal percent")
    func testExpandLiteralPercent() {
        let result = SSHPathUtilities.expandSSHTokens("/keys/%%backup/id_rsa")
        #expect(result == "/keys/%backup/id_rsa")
    }

    @Test("expandSSHTokens combines all tokens in a single path")
    func testExpandMultipleTokens() {
        let homeDir = NSHomeDirectory()
        let localUser = NSUserName()
        let result = SSHPathUtilities.expandSSHTokens(
            "%d/.ssh/%u_%h_%r_%%key",
            hostname: "example.com",
            remoteUser: "admin"
        )
        #expect(result == "\(homeDir)/.ssh/\(localUser)_example.com_admin_%key")
    }

    @Test("expandSSHTokens leaves %h unexpanded when hostname is nil")
    func testUnexpandedTokenH() {
        let result = SSHPathUtilities.expandSSHTokens("/keys/%h/id_rsa")
        #expect(result == "/keys/%h/id_rsa")
    }

    @Test("expandSSHTokens leaves %r unexpanded when remoteUser is nil")
    func testUnexpandedTokenR() {
        let result = SSHPathUtilities.expandSSHTokens("/keys/%r/id_rsa")
        #expect(result == "/keys/%r/id_rsa")
    }

    @Test("expandSSHTokens also expands tilde")
    func testExpandTokensWithTilde() {
        let homeDir = NSHomeDirectory()
        let result = SSHPathUtilities.expandSSHTokens("~/.ssh/id_rsa")
        #expect(result == "\(homeDir)/.ssh/id_rsa")
    }
}
