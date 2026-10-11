//
//  ResultMapDiagnosticsTests.swift
//  TableProTests
//

import Foundation
import TableProGeometry
import Testing

@testable import TablePro

// An SRID is an identifier, not a quantity, so it is named once here rather than written with the
// thousand separator the lint rule asks of a literal.
// swiftlint:disable number_separator
private let wgs84: Int32 = 4326
private let britishNationalGrid: Int32 = 27700
// swiftlint:enable number_separator

struct ResultMapDiagnosticsTests {
    private static func drawn(shapes: Int, rows: Int) -> ResultMapDiagnostics {
        var diagnostics = ResultMapDiagnostics()
        diagnostics.consideredRows = rows
        diagnostics.readableRows = rows
        diagnostics.drawnRows = rows
        diagnostics.drawnShapes = shapes
        diagnostics.drawnSRID = wgs84
        diagnostics.projectability = .geographic
        return diagnostics
    }

    // MARK: - Status

    /// A member the map could not place used to be skipped with the row reported as drawn.
    @Test("The status says how many parts were left out, and only when some were")
    func statusNamesDroppedParts() {
        let whole = Self.drawn(shapes: 1, rows: 1)
        var partial = whole
        partial.droppedParts = 7

        #expect(!whole.hasAnythingToReport)
        #expect(partial.hasAnythingToReport)
        #expect(partial.statusText.hasPrefix(whole.statusText))
        #expect(partial.statusText.count > whole.statusText.count)
        #expect(partial.statusText.contains("7"))
        #expect(!whole.statusText.contains("7"))
    }

    /// The count sits inside the sentence, so one left-out part needs a sentence of its own.
    @Test("One left-out part is not called parts")
    func oneDroppedPartIsSingular() {
        let whole = Self.drawn(shapes: 3, rows: 3)
        var partial = whole
        partial.droppedParts = 1

        #expect(partial.hasAnythingToReport)
        #expect(partial.statusText.hasPrefix(whole.statusText))
        let sentence = String(partial.statusText.dropFirst(whole.statusText.count))
        #expect(sentence.contains("1"))
        #expect(!sentence.contains("1 parts"))
        #expect(!sentence.contains(" are "))
    }

    @Test("The status keeps the SRID and what else was left out")
    func statusKeepsItsOtherSentences() {
        var diagnostics = Self.drawn(shapes: 12, rows: 9)
        #expect(diagnostics.statusText.contains("12"))
        #expect(diagnostics.statusText.contains("4326"))

        let clean = diagnostics.statusText
        diagnostics.unsupportedTypes = ["CIRCULARSTRING": 3]
        #expect(diagnostics.statusText.hasPrefix(clean))
        #expect(diagnostics.statusText.contains("CIRCULARSTRING"))
    }

    // MARK: - Why nothing drew

    /// An SRID the map has no entry for can be a geographic one, so calling it "a projected
    /// coordinate system" is a claim the map cannot make.
    @Test("An SRID the map cannot place is named without being called projected")
    func unsupportedSRIDIsNotCalledProjected() {
        var diagnostics = ResultMapDiagnostics()
        diagnostics.readableRows = 1
        diagnostics.projectability = .unsupported(srid: britishNationalGrid)

        let reason = diagnostics.emptyReason
        #expect(reason.contains("27700"))
        #expect(!reason.contains("projected coordinate system"))
        #expect(reason.hasPrefix(GeometryFieldPreview.Reason.unsupportedSRID(britishNationalGrid).message))
    }

    @Test("No SRID and coordinates out of range is its own reason")
    func noSRIDOutOfRange() {
        var named = ResultMapDiagnostics()
        named.readableRows = 1
        named.projectability = .unsupported(srid: britishNationalGrid)

        var unnamed = named
        unnamed.projectability = .unsupported(srid: nil)
        #expect(unnamed.emptyReason != named.emptyReason)
        #expect(!unnamed.emptyReason.contains("27700"))
    }

    /// Rows that read in a supported system and still place nothing were told they were "empty or
    /// null", which they are not: swapped axes are the usual cause.
    @Test("Values that read and still draw nothing are not called empty or null")
    func nothingDrawableIsNotCalledEmpty() {
        var nothingRead = ResultMapDiagnostics()
        nothingRead.emptyRows = 2

        var nothingDrawn = ResultMapDiagnostics()
        nothingDrawn.readableRows = 2
        nothingDrawn.unreadableRows = 2
        nothingDrawn.drawnSRID = wgs84
        nothingDrawn.projectability = .geographic

        #expect(!nothingDrawn.emptyReason.isEmpty)
        #expect(nothingDrawn.emptyReason != nothingRead.emptyReason)
    }

    @Test("A column of a type the map cannot draw is told which type")
    func undrawableTypeIsNamed() {
        var diagnostics = ResultMapDiagnostics()
        diagnostics.unsupportedTypes = ["CIRCULARSTRING": 3, "TIN": 1]
        #expect(diagnostics.emptyReason.contains("CIRCULARSTRING, TIN"))
    }
}
