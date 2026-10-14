//
//  CrossEngineValueCoercerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CrossEngineValueCoercerTests {
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
    @Test
    func aTableWithNothingToReshapeNeedsNoCoercion() {
        let plain = coercer([.integer(bytes: 4), .text(length: nil, isFixed: false)])
        #expect(!plain.isNeeded)
        #expect(coercer([.boolean]).isNeeded)
        #expect(coercer([.timestamp(precision: nil, hasTimeZone: false)]).isNeeded)
    }

    // MARK: - Booleans

    /// PostgreSQL renders a boolean as `t` and `f`. Bound into a MySQL `TINYINT(1)` that is 0 in
    /// both cases outside strict mode, so every `true` in the table silently becomes `false`.
    @Test
    func postgresBooleansBecomeOneAndZero() {
        let row = coercer([.boolean, .boolean]).coerce([.text("t"), .text("f")])
        #expect(row == [.text("1"), .text("0")])
    }

    @Test
    func theOtherBooleanSpellingsAreNormalised() {
        let subject = coercer([.boolean])
        #expect(subject.coerce([.text("true")]) == [.text("1")])
        #expect(subject.coerce([.text("YES")]) == [.text("1")])
        #expect(subject.coerce([.text("off")]) == [.text("0")])
        #expect(subject.coerce([.text("0")]) == [.text("0")])
    }

    /// A MySQL `BIT(1)` arrives as one byte rather than as text.
    @Test
    func aSingleByteBooleanIsRead() {
        let subject = coercer([.boolean], from: .mysql)
        #expect(subject.coerce([.bytes(Data([1]))]) == [.text("1")])
        #expect(subject.coerce([.bytes(Data([0]))]) == [.text("0")])
    }

    /// A value that is not a boolean spelling is left alone rather than guessed at, so a column the
    /// source did not really use as one fails visibly instead of arriving wrong.
    @Test
    func anUnrecognisedBooleanIsLeftAlone() {
        #expect(coercer([.boolean]).coerce([.text("maybe")]) == [.text("maybe")])
        #expect(coercer([.boolean]).coerce([.null]) == [.null])
    }

    /// A `t` that was text on the source is text on the target too.
    @Test
    func aTextColumnIsNotTouched() {
        #expect(coercer([.text(length: nil, isFixed: false)]).coerce([.text("t")]) == [.text("t")])
    }

    /// A boolean copied into a text column keeps what the source wrote. `t` is the value there
    /// rather than a spelling of one, and rewriting it to `1` would change the data.
    @Test
    func aBooleanCopiedIntoTextKeepsItsOwnSpelling() {
        let subject = coercer([.text(length: nil, isFixed: false)], sources: [.boolean])
        #expect(subject.coerce([.text("t")]) == [.text("t")])
    }

    /// Oracle has no boolean and takes `NUMBER(1)`, so the target kind is a decimal while the
    /// values are still boolean-shaped. Deciding from the target alone left `t` bound into a number.
    @Test
    func aBooleanIntoANumericTargetIsStillNormalised() {
        let subject = coercer([.decimal(precision: 1, scale: nil)], sources: [.boolean])
        #expect(subject.coerce([.text("t")]) == [.text("1")])
    }

    // MARK: - Time zones

    @Test
    func aZoneOffsetIsStrippedForATargetWithoutOne() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: false)])
        #expect(subject.coerce([.text("2024-01-01 10:00:00+07")]) == [.text("2024-01-01 10:00:00")])
        #expect(subject.coerce([.text("2024-01-01T10:00:00.123456Z")]) == [.text("2024-01-01T10:00:00.123456")])
        #expect(subject.coerce([.text("2024-01-01 10:00:00-03:30")]) == [.text("2024-01-01 10:00:00")])
    }

    /// The crossing that motivates the whole coercion: PostgreSQL `timestamptz` to MySQL
    /// `DATETIME`. The source has a zone and the target does not, so the decision has to come from
    /// the target's side.
    @Test
    func aZonedSourceIsStrippedForAnUnzonedTarget() {
        let subject = coercer(
            [.timestamp(precision: nil, hasTimeZone: false)],
            sources: [.timestamp(precision: nil, hasTimeZone: true)]
        )
        #expect(subject.coerce([.text("2024-01-01 10:00:00+07")]) == [.text("2024-01-01 10:00:00")])
    }

    @Test
    func aZoneAwareTargetKeepsTheOffset() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: true)])
        #expect(subject.coerce([.text("2024-01-01 10:00:00+07")]) == [.text("2024-01-01 10:00:00+07")])
    }

    @Test
    func aPlainTimestampIsUnchanged() {
        let subject = coercer([.timestamp(precision: nil, hasTimeZone: false)])
        #expect(subject.coerce([.text("2024-01-01 10:00:00")]) == [.text("2024-01-01 10:00:00")])
        #expect(subject.coerce([.text("2024-01-01")]) == [.text("2024-01-01")])
    }

    // MARK: - Zero dates

    /// No engine but MySQL accepts `0000-00-00`, and a copy that sends it fails on that row.
    @Test
    func mySQLZeroDatesBecomeNull() {
        let subject = coercer([.date, .timestamp(precision: nil, hasTimeZone: false)], from: .mysql)
        #expect(subject.coerce([.text("0000-00-00"), .text("0000-00-00 00:00:00")]) == [.null, .null])
    }

    @Test
    func aZeroDateFromAnotherEngineIsLeftAlone() {
        #expect(coercer([.date], from: .postgres).coerce([.text("0000-00-00")]) == [.text("0000-00-00")])
    }

    // MARK: - Arrays into JSON

    private var arrayOfText: CanonicalTypeKind {
        .array(element: .text(length: nil, isFixed: false))
    }

    @Test
    func aPostgresArrayBecomesJson() {
        let subject = coercer([.json], sources: [arrayOfText], from: .postgres)
        #expect(subject.coerce([.text("{1,2,3}")]) == [.text("[1,2,3]")])
        #expect(subject.coerce([.text("{a,b}")]) == [.text("[\"a\",\"b\"]")])
        #expect(subject.coerce([.text("{}")]) == [.text("[]")])
    }

    /// A JSON object arrives with the same brackets an array literal uses, and it is already JSON.
    @Test
    func aJsonObjectIsNotMistakenForAnArray() {
        let subject = coercer([.json], sources: [arrayOfText], from: .postgres)
        #expect(subject.coerce([.text("{\"a\": 1}")]) == [.text("{\"a\": 1}")])
    }

    /// The brackets alone cannot tell an array from an object, so the source column decides. A
    /// `jsonb` `{}` went across as `[]`, which is valid JSON and a different type: `jsonb_typeof`
    /// came back `array`, the copy reported success, and nothing in the UI showed the difference.
    @Test
    func aJsonSourceIsNeverRewrittenAsAnArray() {
        let subject = coercer([.json], sources: [.json], from: .postgres)
        #expect(subject.coerce([.text("{}")]) == [.text("{}")])
        #expect(subject.coerce([.text("{\"a\": 1}")]) == [.text("{\"a\": 1}")])
        #expect(subject.coerce([.text("{ }")]) == [.text("{ }")])
    }

    /// A text column holding something array-shaped is text, not an array.
    @Test
    func aTextSourceIsNeverRewrittenAsAnArray() {
        let subject = coercer([.json], sources: [.text(length: nil, isFixed: false)], from: .postgres)
        #expect(subject.coerce([.text("{a,b}")]) == [.text("{a,b}")])
    }

    // MARK: - Shape

    /// The width is checked before the coercion, so a short row can never reach it. Guarded here
    /// too, because a positional reshape against the wrong column's type is silent.
    @Test
    func aShortRowIsNotReshapedPastItsEnd() {
        let subject = coercer([.boolean, .boolean, .boolean])
        #expect(subject.coerce([.text("t")]) == [.text("1")])
    }
}
