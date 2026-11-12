//
//  LibPQNoticeOutputTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQNoticeOutputTests {
    private static let prefix = "NOTICE:  "

    @Test("Each line of a notice, DETAIL and HINT included, is its own output line")
    func splitsOnNewlines() {
        var output = LibPQNoticeOutput()
        output.record("NOTICE:  with extras\nDETAIL:  the detail\nHINT:  the hint\n")
        output.record("NOTICE:  step 1 done\n")
        #expect(output.take() == PluginServerOutput(
            lines: ["NOTICE:  with extras", "DETAIL:  the detail", "HINT:  the hint", "NOTICE:  step 1 done"],
            isTruncated: false
        ))
    }

    @Test("Only libpq's one trailing newline is dropped; the message's own whitespace stays")
    func trailingNewlineOnly() {
        var output = LibPQNoticeOutput()
        output.record("NOTICE:  padded  \n")
        output.record("NOTICE:  ends blank\n\n")
        output.record("  NOTICE:  no newline")
        #expect(output.take().lines == ["NOTICE:  padded  ", "NOTICE:  ends blank", "", "  NOTICE:  no newline"])
    }

    @Test("A carriage return stays on its line, and libpq's newline after it is still dropped")
    func carriageReturnStays() {
        var output = LibPQNoticeOutput()
        output.record("NOTICE:  first\r\nsecond\r\n")
        #expect(output.take().lines == ["NOTICE:  first\r", "second\r"])
    }

    @Test("Past 10,000 lines nothing more is kept and the output reads as cut short")
    func lineCap() {
        var output = LibPQNoticeOutput()
        for index in 1..<LibPQNoticeOutput.lineLimit {
            output.record("NOTICE:  row \(index)\n")
        }
        output.record("NOTICE:  last kept\nDETAIL:  dropped\n")
        output.record("NOTICE:  dropped too\n")
        let taken = output.take()
        #expect(taken.lines.count == LibPQNoticeOutput.lineLimit)
        #expect(taken.lines.last == "NOTICE:  last kept")
        #expect(taken.isTruncated)
    }

    @Test("One notice with more lines than the cap keeps the first 10,000")
    func oneNoticePastTheCap() {
        var output = LibPQNoticeOutput()
        output.record(String(repeating: "x\n", count: LibPQNoticeOutput.lineLimit * 5))
        let taken = output.take()
        #expect(taken.lines.count == LibPQNoticeOutput.lineLimit)
        #expect(taken.lines.allSatisfy { $0 == "x" })
        #expect(taken.isTruncated)
    }

    @Test("Exactly 10,000 lines is not cut short")
    func exactlyTheLineCap() {
        var output = LibPQNoticeOutput()
        for index in 1...LibPQNoticeOutput.lineLimit {
            output.record("NOTICE:  row \(index)\n")
        }
        let taken = output.take()
        #expect(taken.lines.count == LibPQNoticeOutput.lineLimit)
        #expect(!taken.isTruncated)
    }

    @Test(
        "A line past 32,767 bytes is cut before the scalar that crosses the limit",
        arguments: ["\u{E9}", "\u{20AC}", "\u{1F600}"]
    )
    func clipsOnAScalarBoundary(scalar: String) {
        let filler = String(repeating: "a", count: LibPQNoticeOutput.lineByteLimit - Self.prefix.utf8.count - 1)
        var output = LibPQNoticeOutput()
        output.record(Self.prefix + filler + scalar + "tail\nHINT:  kept\n")
        let taken = output.take()
        #expect(taken.lines == [Self.prefix + filler, "HINT:  kept"])
        #expect(taken.lines.first?.utf8.count == LibPQNoticeOutput.lineByteLimit - 1)
        #expect(taken.isTruncated)
    }

    @Test("A line of exactly 32,767 bytes is kept whole")
    func exactlyTheByteLimit() {
        let line = Self.prefix + String(repeating: "a", count: LibPQNoticeOutput.lineByteLimit - Self.prefix.utf8.count)
        var output = LibPQNoticeOutput()
        output.record(line + "\n")
        #expect(output.take() == PluginServerOutput(lines: [line], isTruncated: false))
    }

    @Test("Output is handed over once, and the cut-short flag goes with it")
    func takeOnce() {
        var output = LibPQNoticeOutput()
        for index in 0...LibPQNoticeOutput.lineLimit {
            output.record("NOTICE:  row \(index)\n")
        }
        #expect(output.take().isTruncated)
        #expect(output.take() == .none)
        output.record("NOTICE:  after the take\n")
        #expect(output.take() == PluginServerOutput(lines: ["NOTICE:  after the take"], isTruncated: false))
    }

    @Test("Server notices of every severity are output")
    func serverNoticesAreOutput() {
        #expect(LibPQNoticeOutput.isOutput(severity: "NOTICE", sqlState: "00000"))
        #expect(LibPQNoticeOutput.isOutput(severity: "WARNING", sqlState: "01000"))
        #expect(LibPQNoticeOutput.isOutput(severity: "INFO", sqlState: "00000"))
        #expect(LibPQNoticeOutput.isOutput(severity: "DEBUG", sqlState: "00000"))
        #expect(LibPQNoticeOutput.isOutput(severity: nil, sqlState: "00000"))
    }

    @Test("libpq's own notices, which carry no SQLSTATE, are not output")
    func libpqNoticesAreNotOutput() {
        #expect(!LibPQNoticeOutput.isOutput(severity: "NOTICE", sqlState: nil))
        #expect(!LibPQNoticeOutput.isOutput(severity: "NOTICE", sqlState: ""))
    }

    @Test("A message that ends the session is not output")
    func sessionEndingIsNotOutput() {
        #expect(!LibPQNoticeOutput.isOutput(severity: "FATAL", sqlState: "57P01"))
        #expect(!LibPQNoticeOutput.isOutput(severity: "PANIC", sqlState: "XX000"))
        #expect(!LibPQNoticeOutput.isOutput(severity: nil, sqlState: "08006"))
    }
}
