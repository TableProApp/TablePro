//
//  CrossEngineValueCoercerTests.swift
//  TableProTests
//

import TableProPluginKit
import XCTest
@testable import TablePro

final class CrossEngineValueCoercerTests: XCTestCase {
    /// The target's kinds, with the source's taken to match unless a test says otherwise. Most
    /// coercions are decided by the target; the boolean one is the exception and names both.
    private func coercer(
        _ targets: [CanonicalTypeKind?],
        sources: [CanonicalTypeKind?]? = nil,
        from source: SQLTypeFamily = .postgres
    ) -> CrossEngineValueCoercer {
        let sourceKinds = sources ?? targets
        let pairs = targets.enumerated().map { index, target in
            CrossEngineValueCoercer.ColumnPair(
                source: index < sourceKinds.count ? sourceKinds[index] : nil, target: target
            )
        }
        return CrossEngineValueCoercer(pairs: pairs, from: source)
    }

    // MARK: - When it runs at all

    /// A table of numbers and strings runs the loop it ran before this existed.
    func testATableWithNothingToReshapeNeedsNoCoercion() {
        let plain = coercer([.integer(bytes: 4), .text(length: nil, isFixed: false)])
        XCTAssertFalse(plain.isNeeded)
        XCTAssertTrue(coercer([.boolean]).isNeeded)
        XCTAssertTrue(coercer([.timestamp(precision: nil, hasTimeZone: false)]).isNeeded)
    }

    // MARK: - Booleans

    /// PostgreSQL renders a boolean as `t` and `f`. Bound into a MySQL `TINYINT(1)` that is 0 in
    /// both cases outside strict mode, so every `true` in the table silently becomes `false`.
    func testPostgresBooleansBecomeOneAndZero() {
        let row = coercer([.boolean, .boolean]).coerce([.text("t"), .text("f")])
        XCTAssertEqual(row, [.text("1"), .text("0")])
    }

    func testTheOtherBooleanSpellingsAreNormalised() {
        let subject = coercer([.boolean])
        XCTAssertEqual(subject.coerce([.text("true")]), [.text("1")])
        XCTAssertEqual(subject.coerce([.text("YES")]), [.text("1")])
        XCTAssertEqual(subject.coerce([.text("off")]), [.text("0")])
        XCTAssertEqual(subject.coerce([.text("0")]), [.text("0")])
    }

    /// A MySQL `BIT(1)` arrives as one byte rather than as text.
    func testASingleByteBooleanIsRead() {
        let subject = coercer([.boolean], from: .mysql)
        XCTAssertEqual(subject.coerce([.bytes(Data([1]))]), [.text("1")])
        XCTAssertEqual(subject.coerce([.bytes(Data([0]))]), [.text("0")])
    }

    /// A value that is not a boolean spelling is left alone rather than guessed at, so a column the
    /// source did not really use as one fails visibly instead of arriving wrong.
    func testAnUnrecognisedBooleanIsLeftAlone() {
        XCTAssertEqual(coercer([.boolean]).coerce([.text("maybe")]), [.text("maybe")])
        XCTAssertEqual(coercer([.boolean]).coerce([.null]), [.null])
    }

    /// A `t` that was text on the source is text on the target too.
    func testATextColumnIsNotTouched() {
        XCTAssertEqual(
            coercer([.text(length: nil, isFixed: false)]).coerce([.text("t")]), [.text("t")]
        )
    }

    /// A boolean copied into a text column keeps what the source wrote. `t` is the value there
    /// rather than a spelling of one, and rewriting it to `1` would change the data.
    func testABooleanCopiedIntoTextKeepsItsOwnSpelling() {
        let subject = coercer([.text(length: nil, isFixed: false)], sources: [.boolean])
        XCTAssertEqual(subject.coerce([.text("t")]), [.text("t")])
    }

    /// Oracle has no boolean and takes `NUMBER(1)`, so the target kind is a decimal while the
    /// values are still boolean-shaped. Deciding from the target alone left `t` bound into a number.
    func testABooleanIntoANumericTargetIsStillNormalised() {
        let subject = coercer([.decimal(precision: 1, scale: nil)], sources: [.boolean])
        XCTAssertEqual(subject.coerce([.text("t")]), [.text("1")])
    }

    // MARK: - Time zones

    func testAZoneOffsetIsStrippedForATargetWithoutOne() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: false)])
        XCTAssertEqual(
            subject.coerce([.text("2024-01-01 10:00:00+07")]), [.text("2024-01-01 10:00:00")]
        )
        XCTAssertEqual(
            subject.coerce([.text("2024-01-01T10:00:00.123456Z")]), [.text("2024-01-01T10:00:00.123456")]
        )
        XCTAssertEqual(
            subject.coerce([.text("2024-01-01 10:00:00-03:30")]), [.text("2024-01-01 10:00:00")]
        )
    }

    /// The crossing that motivates the whole coercion: PostgreSQL `timestamptz` to MySQL
    /// `DATETIME`. The source has a zone and the target does not, so the decision has to come from
    /// the target's side.
    func testAZonedSourceIsStrippedForAnUnzonedTarget() {
        let subject = coercer(
            [.timestamp(precision: nil, hasTimeZone: false)],
            sources: [.timestamp(precision: nil, hasTimeZone: true)]
        )
        XCTAssertEqual(
            subject.coerce([.text("2024-01-01 10:00:00+07")]), [.text("2024-01-01 10:00:00")]
        )
    }

    func testAZoneAwareTargetKeepsTheOffset() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: true)])
        XCTAssertEqual(
            subject.coerce([.text("2024-01-01 10:00:00+07")]), [.text("2024-01-01 10:00:00+07")]
        )
    }

    func testAPlainTimestampIsUnchanged() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: false)])
        XCTAssertEqual(subject.coerce([.text("2024-01-01 10:00:00")]), [.text("2024-01-01 10:00:00")])
        XCTAssertEqual(subject.coerce([.text("2024-01-01")]), [.text("2024-01-01")])
    }

    // MARK: - Zero dates

    /// No engine but MySQL accepts `0000-00-00`, and a copy that sends it fails on that row.
    func testMySQLZeroDatesBecomeNull() {
        let subject = coercer([.date, .timestamp(precision: nil, hasTimeZone: false)], from: .mysql)
        XCTAssertEqual(
            subject.coerce([.text("0000-00-00"), .text("0000-00-00 00:00:00")]), [.null, .null]
        )
    }

    func testAZeroDateFromAnotherEngineIsLeftAlone() {
        XCTAssertEqual(coercer([.date], from: .postgres).coerce([.text("0000-00-00")]), [.text("0000-00-00")])
    }

    // MARK: - Arrays into JSON

    func testAPostgresArrayBecomesJson() {
        let subject = coercer([.json], from: .postgres)
        XCTAssertEqual(subject.coerce([.text("{1,2,3}")]), [.text("[1,2,3]")])
        XCTAssertEqual(subject.coerce([.text("{a,b}")]), [.text("[\"a\",\"b\"]")])
        XCTAssertEqual(subject.coerce([.text("{}")]), [.text("[]")])
    }

    /// A JSON object arrives with the same brackets an array literal uses, and it is already JSON.
    func testAJsonObjectIsNotMistakenForAnArray() {
        let subject = coercer([.json], from: .postgres)
        XCTAssertEqual(subject.coerce([.text("{\"a\": 1}")]), [.text("{\"a\": 1}")])
    }

    // MARK: - Shape

    /// The width is checked before the coercion, so a short row can never reach it. Guarded here
    /// too, because a positional reshape against the wrong column's type is silent.
    func testAShortRowIsNotReshapedPastItsEnd() {
        let subject = coercer([.boolean, .boolean, .boolean])
        XCTAssertEqual(subject.coerce([.text("t")]), [.text("1")])
    }
}
