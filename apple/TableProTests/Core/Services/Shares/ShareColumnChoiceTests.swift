//
//  ShareColumnChoiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ShareColumnChoiceTests {
    @Test("A rule-masked column starts masked with the rule's style, refuses Keep and offers only stricter styles")
    func ruleMaskedColumn() throws {
        let choice = ShareColumnChoice(index: 0, name: "phone", ruleStyle: .lastFour, detection: nil)
        #expect(choice.action == .mask)
        #expect(choice.style == .lastFour)
        #expect(!choice.allowsKeep)
        #expect(choice.allowedStyles == [.full, .lastFour, .null])
        #expect(choice.choosing(.keep) == nil)
        #expect(choice.choosing(style: .email) == nil)
        #expect(try #require(choice.choosing(.remove)).sharedColumn == nil)
        #expect(ShareColumnChoice(index: 0, name: "x", ruleStyle: .null, detection: nil).allowedStyles == [.null])
        #expect(ShareColumnChoice(index: 0, name: "x", ruleStyle: .full, detection: nil).allowedStyles == [.full, .null])
    }

    @Test("A rule's own style is already on the values, so only a stricter one is applied again")
    func ruleStyleIsNotAppliedTwice() throws {
        let choice = ShareColumnChoice(index: 3, name: "ip", ruleStyle: .hash, detection: nil)
        #expect(choice.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 3, applying: nil, masked: .hash))
        let stricter = try #require(choice.choosing(style: .full))
        #expect(stricter.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 3, applying: .full, masked: .full))
    }

    @Test("A detected column starts masked with the suggested style and may be kept")
    func detectedColumn() throws {
        let choice = ShareColumnChoice(index: 1, name: "contact", ruleStyle: nil, detection: .values(.email))
        #expect(choice.action == .mask)
        #expect(choice.style == .email)
        #expect(choice.allowedStyles == MaskingStyle.allCases)
        #expect(choice.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 1, applying: .email, masked: .email))
        let kept = try #require(choice.choosing(.keep))
        #expect(kept.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 1, applying: nil, masked: nil))
        #expect(kept.maskedStyle == nil)
    }

    @Test("Any other column starts kept")
    func plainColumn() {
        let choice = ShareColumnChoice(index: 0, name: "id", ruleStyle: nil, detection: nil)
        #expect(choice.action == .keep)
        #expect(choice.allowsKeep)
    }

    @Test("Defaults come from the source's rule masks and the detectors")
    func defaults() throws {
        let source = ShareResultSource(
            columns: ["id", "email", "password"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text"), .text(rawType: "text")],
            rows: [[.text("1"), .text("j•••@x.io"), .text("hunter2")]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [1: .email])
        )
        let choices = try #require(ShareColumnChoice.defaults(for: source, maxRows: 10))
        #expect(choices.map(\.action) == [.keep, .mask, .mask])
        #expect(choices.map(\.style) == [.full, .email, .full])
        #expect(choices.map(\.ruleStyle) == [nil, .email, nil])
        #expect(choices.map(\.detection) == [nil, nil, .name(.secret)])
    }
}
