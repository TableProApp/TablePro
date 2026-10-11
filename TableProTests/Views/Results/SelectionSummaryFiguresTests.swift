//
//  SelectionSummaryFiguresTests.swift
//  TableProTests
//

import Foundation
import TableProNumberFormatting
import Testing

@testable import TablePro

struct SelectionSummaryFiguresTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    private func numbers(_ texts: [String]) throws -> ExactNumericSummary {
        var accumulator = NumericSummaryAccumulator()
        for text in texts {
            let accepted = accumulator.add(text)
            #expect(accepted, "\(text) was not read as a number")
        }
        return try #require(accumulator.summary())
    }

    private func summary(
        valueCount: Int,
        emptyCount: Int = 0,
        notANumberCount: Int = 0,
        numbers: ExactNumericSummary?
    ) -> SelectionSummary {
        SelectionSummary(
            valueCount: valueCount,
            emptyCount: emptyCount,
            notANumberCount: notANumberCount,
            numbers: numbers,
            coversWholeColumn: false
        )
    }

    private func trackMilliseconds() throws -> SelectionSummary {
        summary(valueCount: 3, numbers: try numbers(["343719", "342562", "230619"]))
    }

    @Test("The bar's figures group per locale and the average gets four more digits")
    func barFiguresFollowTheLocale() throws {
        let figures = SelectionSummaryFigures(try trackMilliseconds(), locale: Self.english)
        #expect(figures.sum == "916,900")
        #expect(figures.average == "305,633.3333")
        #expect(figures.valueCount == 3)
    }

    @Test("The detail lists sum, average, minimum and maximum in that order")
    func detailListsEveryNumberFigure() throws {
        let figures = SelectionSummaryFigures(try trackMilliseconds(), locale: Self.english)
        #expect(figures.numberRows.map(\.figure) == [.sum, .average, .minimum, .maximum])
        #expect(figures.numberRows.map(\.value) == ["916,900", "305,633.3333", "230,619", "343,719"])
    }

    @Test("Copy gives plain text with no grouping, whatever the locale")
    func copyTextIsPlain() throws {
        for locale in [Self.english, Self.german] {
            let figures = SelectionSummaryFigures(try trackMilliseconds(), locale: locale)
            #expect(figures.numberRows.map(\.copyText) == ["916900", "305633.3333", "230619", "343719"])
        }
        #expect(SelectionSummaryFigures(try trackMilliseconds(), locale: Self.german).sum == "916.900")
    }

    @Test("Sum, minimum and maximum keep the inputs' scale, and the average drops trailing zeros")
    func centsStayCents() throws {
        let figures = SelectionSummaryFigures(
            summary(valueCount: 2, numbers: try numbers(["0.99", "0.01"])),
            locale: Self.english
        )
        #expect(figures.sum == "1.00")
        #expect(figures.average == "0.5")
        #expect(figures.numberRows.map(\.value) == ["1.00", "0.5", "0.01", "0.99"])
        #expect(figures.numberRows.map(\.copyText) == ["1.00", "0.5", "0.01", "0.99"])
    }

    @Test("The context menu copies the same text as the detail")
    func menuCopyMatchesTheDetail() throws {
        let numbers = try self.numbers(["0.99", "0.01", "2"])
        let figures = SelectionSummaryFigures(summary(valueCount: 3, numbers: numbers), locale: Self.english)
        for row in figures.numberRows {
            #expect(SelectionSummaryFigures.copyText(row.figure, of: numbers) == row.copyText)
        }
        for figure in [SelectionSummaryFigures.Figure.count, .numbers, .empty, .notANumber] {
            #expect(SelectionSummaryFigures.copyText(figure, of: numbers) == nil)
        }
    }

    @Test("Counts group on screen and copy as plain digits")
    func countRowsGroupAndCopyPlain() throws {
        let figures = SelectionSummaryFigures(
            summary(valueCount: 1_234, emptyCount: 2_000, numbers: try numbers(["1", "2"])),
            locale: Self.english
        )
        #expect(figures.countRows.map(\.figure) == [.count, .numbers, .empty])
        #expect(figures.countRows.map(\.value) == ["1,234", "2", "2,000"])
        #expect(figures.countRows.map(\.copyText) == ["1234", "2", "2000"])
    }

    @Test("Not a number is listed only when a cell was one")
    func notANumberOnlyWhenPresent() throws {
        let clean = SelectionSummaryFigures(try trackMilliseconds(), locale: Self.english)
        #expect(!clean.countRows.contains { $0.figure == .notANumber })

        let mixed = SelectionSummaryFigures(
            summary(valueCount: 4, notANumberCount: 1, numbers: try numbers(["1", "2", "3"])),
            locale: Self.english
        )
        #expect(mixed.countRows.map(\.figure) == [.count, .numbers, .empty, .notANumber])
        #expect(mixed.countRows.last?.value == "1")
    }

    @Test("A selection with no numbers offers only its counts")
    func noNumbersMeansCountsOnly() {
        let figures = SelectionSummaryFigures(
            summary(valueCount: 5, emptyCount: 1, numbers: nil),
            locale: Self.english
        )
        #expect(figures.sum == nil)
        #expect(figures.average == nil)
        #expect(figures.numberRows.isEmpty)
        #expect(figures.countRows.map(\.value) == ["5", "0", "1"])
    }
}
