//
//  UUIDCellFormTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct UUIDCellFormTests {
    private static let sample = UUID(uuidString: "0192F3A4-7B2C-7D1E-8F00-1A2B3C4D5E6F") ?? UUID()

    @Test(
        "A column typed as a UUID takes the canonical text",
        arguments: ["uuid", "UUID", "Nullable(UUID)", "uniqueidentifier"]
    )
    func nativeUUIDTypes(rawType: String) {
        let form = UUIDCellForm(columnType: .text(rawType: rawType), displayFormat: nil)
        #expect(form == .hyphenated)
        #expect(form?.value(for: Self.sample) == .text("0192f3a4-7b2c-7d1e-8f00-1a2b3c4d5e6f"))
    }

    @Test("timeuuid takes no generated value")
    func timeUUIDIsExcluded() {
        #expect(UUIDCellForm(columnType: .text(rawType: "timeuuid"), displayFormat: nil) == nil)
        #expect(UUIDCellForm(columnType: .text(rawType: "timeuuid"), displayFormat: .uuid) == nil)
    }

    @Test("A text column holds UUIDs only when its display format says so")
    func textNeedsTheDisplayFormat() {
        #expect(UUIDCellForm(columnType: .text(rawType: "CHAR"), displayFormat: nil) == nil)
        #expect(UUIDCellForm(columnType: .text(rawType: "CHAR"), displayFormat: .raw) == nil)
        #expect(UUIDCellForm(columnType: .text(rawType: "CHAR"), displayFormat: .uuid) == .hyphenated)
    }

    @Test("A CHAR(32) UUID column takes 32 hex digits")
    func compactText() {
        let form = UUIDCellForm(columnType: .text(rawType: "char(32)"), displayFormat: .uuid)
        #expect(form == .compact)
        #expect(form?.value(for: Self.sample) == .text("0192f3a47b2c7d1e8f001a2b3c4d5e6f"))
    }

    @Test("A text column typed with no length takes the form its values have")
    func compactFromSample() {
        let compact = UUIDCellForm(
            columnType: .text(rawType: "CHAR"), displayFormat: .uuid, sampleText: "0192F3A47B2C7D1E8F001A2B3C4D5E6F"
        )
        #expect(compact == .compact)
        let hyphenated = UUIDCellForm(
            columnType: .text(rawType: "CHAR"), displayFormat: .uuid, sampleText: "0192f3a4-7b2c-7d1e-8f00-1a2b3c4d5e6f"
        )
        #expect(hyphenated == .hyphenated)
        let declared = UUIDCellForm(
            columnType: .text(rawType: "char(36)"), displayFormat: .uuid, sampleText: "0192f3a47b2c7d1e8f001a2b3c4d5e6f"
        )
        #expect(declared == .hyphenated)
        #expect(UUIDCellForm(columnType: .text(rawType: "Nullable(FixedString(32))"), displayFormat: .uuid) == .compact)
    }

    @Test("A text column typed with no length takes the schema's length first, then its values")
    func lengthFromDeclaredType() {
        let lengthless = ColumnType.text(rawType: "CHAR")
        let compactSample = "0192f3a47b2c7d1e8f001a2b3c4d5e6f"
        #expect(UUIDCellForm(columnType: lengthless, displayFormat: .uuid, declaredType: "CHAR(32)") == .compact)
        #expect(
            UUIDCellForm(columnType: lengthless, displayFormat: .uuid, sampleText: compactSample, declaredType: "CHAR(36)")
                == .hyphenated
        )
        #expect(
            UUIDCellForm(columnType: lengthless, displayFormat: .uuid, sampleText: compactSample, declaredType: "CHAR")
                == .compact
        )
        #expect(
            UUIDCellForm(columnType: .text(rawType: "char(36)"), displayFormat: .uuid, declaredType: "CHAR(32)")
                == .hyphenated
        )
    }

    @Test("A BINARY(16) or RAW(16) UUID column takes the 16 bytes")
    func binary() {
        let form = UUIDCellForm(columnType: .blob(rawType: "BINARY"), displayFormat: .uuid)
        #expect(form == .bytes)
        let expected = Data([0x01, 0x92, 0xF3, 0xA4, 0x7B, 0x2C, 0x7D, 0x1E, 0x8F, 0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E, 0x6F])
        #expect(form?.value(for: Self.sample) == .bytes(expected))
        #expect(UUIDCellForm(columnType: .blob(rawType: "RAW(16)"), displayFormat: nil) == nil)
    }

    @Test("Other types never hold a generated UUID", arguments: [
        ColumnType.integer(rawType: "INT"), .timestamp(rawType: "TIMESTAMP"), .json(rawType: "JSON"),
        .array(rawType: "uuid[]", element: .text(rawType: "uuid"))
    ])
    func otherTypes(columnType: ColumnType) {
        #expect(UUIDCellForm(columnType: columnType, displayFormat: .uuid) == nil)
    }
}
