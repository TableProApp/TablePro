//
//  CLIToolVersionProbeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("CLI tool version probe")
struct CLIToolVersionProbeTests {
    private func script(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-probe-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    @Test("A tool's answer comes back as it printed it")
    func readsTheBanner() throws {
        let path = try script("printf '%s' 'mysqldump  Ver 8.4.11 for macos26.6 on arm64 (Homebrew)'")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CLIToolVersionProbe.versionOutput(of: path)?.contains("Ver 8.4.11") == true)
    }

    @Test("A tool that cannot run answers nothing")
    func missingBinary() {
        #expect(CLIToolVersionProbe.versionOutput(of: "/nonexistent/mysqldump") == nil)
    }

    @Test("A tool that fails answers nothing")
    func nonZeroExit() throws {
        let path = try script("printf '%s' 'half an answer'\nexit 1")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(CLIToolVersionProbe.versionOutput(of: path) == nil)
    }

    /// The deadline covers the process, and a wrapper that prints its version, starts a helper
    /// holding standard output and exits leaves EOF to the helper. Reading to EOF would wait for
    /// that helper, which is a dump that never starts.
    @Test("A child left holding standard output does not hold up the answer", .timeLimit(.minutes(1)))
    func survivingChildDoesNotBlock() throws {
        let path = try script("(sleep 30) &\nprintf '%s' 'mysqldump  Ver 8.4.11'")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let started = Date()
        let answer = CLIToolVersionProbe.versionOutput(of: path)
        #expect(answer?.contains("Ver 8.4.11") == true)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
