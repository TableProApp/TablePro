//
//  RowGenerationEngineTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct RowGenerationEngineTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private static func generator(_ kind: RowGeneratorKind, _ change: (inout RowGeneratorSettings) -> Void = { _ in }) -> RowGeneratorSettings {
        var settings = RowGeneratorSettings(kind: kind, dateStart: date(2024, 1, 1), dateEnd: date(2024, 12, 31))
        change(&settings)
        return settings
    }

    private static func engine(
        _ table: RowGenerationTable,
        _ columns: [String: RowGeneratorSettings],
        seed: UInt64 = 42,
        rowCount: Int = 100,
        booleanStyle: RowGenerationBooleanStyle = .words,
        nullsAreDistinct: Bool = true
    ) -> RowGenerationEngine {
        RowGenerationEngine(
            table: table,
            settings: RowGenerationSettings(rowCount: rowCount, seed: seed, columns: columns),
            booleanStyle: booleanStyle,
            nullsAreDistinct: nullsAreDistinct,
            calendar: calendar
        )
    }

    private static func texts(_ rows: [[PluginCellValue]], column: Int) -> [String?] {
        rows.map { $0[column].asText }
    }

    private static let people = RowGenerationTable(columns: [
        RowGenerationColumn(name: "id", typeName: "integer", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false, ownership: .assigned),
        RowGenerationColumn(name: "name", typeName: "varchar(80)", valueClass: .text(maxLength: 80), isNullable: false),
        RowGenerationColumn(name: "email", typeName: "varchar(120)", valueClass: .text(maxLength: 120), isNullable: false, isUnique: true),
        RowGenerationColumn(name: "born", typeName: "date", valueClass: .date),
        RowGenerationColumn(name: "active", typeName: "boolean", valueClass: .boolean, isNullable: false)
    ])

    private static let peopleSettings: [String: RowGeneratorSettings] = [
        "id": generator(.serverDefault),
        "name": generator(.fullName),
        "email": generator(.email),
        "born": generator(.date),
        "active": generator(.boolean)
    ]

    @Test("The same seed and settings give the same rows, and another seed gives other rows")
    func seedDecidesTheRows() throws {
        let first = try Self.engine(Self.people, Self.peopleSettings).nextRows(200)
        let again = try Self.engine(Self.people, Self.peopleSettings).nextRows(200)
        let other = try Self.engine(Self.people, Self.peopleSettings, seed: 43).nextRows(200)

        #expect(first == again)
        #expect(first != other)
    }

    @Test("A column the server fills is left out of every row")
    func serverDefaultColumnIsLeftOut() throws {
        let engine = Self.engine(Self.people, Self.peopleSettings)
        let row = try engine.nextRow()

        #expect(engine.columnNames == ["name", "email", "born", "active"])
        #expect(row.count == 4)
    }

    @Test("Changing one column's generator leaves every other column's values as they were")
    func columnsDrawFromTheirOwnStreams() throws {
        var changed = Self.peopleSettings
        changed["name"] = Self.generator(.city)
        let before = try Self.engine(Self.people, Self.peopleSettings).nextRows(50)
        let after = try Self.engine(Self.people, changed).nextRows(50)

        #expect(Self.texts(before, column: 1) == Self.texts(after, column: 1))
        #expect(Self.texts(before, column: 2) == Self.texts(after, column: 2))
        #expect(Self.texts(before, column: 0) != Self.texts(after, column: 0))
    }

    @Test("A unique email column never repeats")
    func uniqueEmailsNeverRepeat() throws {
        let rows = try Self.engine(Self.people, Self.peopleSettings).nextRows(20_000)
        let emails = Self.texts(rows, column: 1).compactMap { $0 }

        #expect(Set(emails).count == 20_000)
        #expect(emails.allSatisfy { $0.contains("@example.") })
    }

    @Test("A unique name column past the names it knows numbers the rest, inside the column's length")
    func uniqueWordsTakeASuffix() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "city", typeName: "varchar(12)", valueClass: .text(maxLength: 12), isNullable: false, isUnique: true)
        ])
        let values = try Self.engine(table, ["city": Self.generator(.city)]).nextRows(300).compactMap { $0[0].asText }

        #expect(Set(values).count == 300)
        #expect(values.allSatisfy { $0.count <= 12 })
    }

    @Test("A unique number range as wide as the row count uses every number once")
    func uniqueRangeFillsEveryValue() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "code", typeName: "smallint", valueClass: .integer(minimum: -32_768, maximum: 32_767), isNullable: false, isUnique: true)
        ])
        let settings = ["code": Self.generator(.integerRange) { $0.integerMinimum = 1; $0.integerMaximum = 300 }]
        let values = try Self.engine(table, settings).nextRows(300).compactMap { $0[0].asText.flatMap { Int($0) } }

        #expect(Set(values) == Set(1...300))
    }

    @Test("A unique column with no values left reports which column ran out")
    func exhaustedUniqueColumnThrows() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "flag", typeName: "char(1)", valueClass: .text(maxLength: 1), isNullable: false, isUnique: true)
        ])
        let engine = Self.engine(table, ["flag": Self.generator(.list) { $0.values = ["a", "b"] }])

        #expect(throws: RowGenerationError.uniqueValuesExhausted(["flag"])) {
            try engine.nextRows(3)
        }
    }

    @Test("A key over two columns never repeats as a pair")
    func compositeKeyNeverRepeats() throws {
        let table = RowGenerationTable(
            columns: [
                RowGenerationColumn(name: "user_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false),
                RowGenerationColumn(name: "role_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false)
            ],
            uniqueGroups: [["user_id", "role_id"]]
        )
        let settings = [
            "user_id": Self.generator(.integerRange) { $0.integerMinimum = 1; $0.integerMaximum = 6 },
            "role_id": Self.generator(.integerRange) { $0.integerMinimum = 1; $0.integerMaximum = 4 }
        ]
        let rows = try Self.engine(table, settings).nextRows(20)
        let pairs = rows.map { "\($0[0].asText ?? "")/\($0[1].asText ?? "")" }

        #expect(Set(pairs).count == 20)
    }

    private static func integerColumn(_ name: String, nullable: Bool = false, unique: Bool = false) -> RowGenerationColumn {
        RowGenerationColumn(
            name: name, typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: nullable, isUnique: unique
        )
    }

    private static func range(_ low: Int64, _ high: Int64) -> RowGeneratorSettings {
        generator(.integerRange) { $0.integerMinimum = low; $0.integerMaximum = high }
    }

    @Test("A key over two columns fills every combination when the rows need them all")
    func compositeKeyReachesEveryCombination() throws {
        let table = RowGenerationTable(columns: [Self.integerColumn("a"), Self.integerColumn("b")], uniqueGroups: [["a", "b"]])
        let rows = try Self.engine(table, ["a": Self.range(1, 10), "b": Self.range(1, 10)], seed: 1).nextRows(100)

        #expect(Set(rows.map { "\($0[0].asText ?? "")/\($0[1].asText ?? "")" }).count == 100)
    }

    @Test("Two keys that share a column both hold once one of them redraws it")
    func overlappingKeysBothHold() throws {
        let table = RowGenerationTable(
            columns: [Self.integerColumn("a"), Self.integerColumn("b"), Self.integerColumn("c")],
            uniqueGroups: [["a", "b"], ["b", "c"]]
        )
        let settings = ["a": Self.range(1, 5), "b": Self.range(1, 5), "c": Self.range(1, 5)]
        let rows = try Self.engine(table, settings, seed: 1).nextRows(25)

        #expect(Set(rows.map { "\($0[0].asText ?? "")/\($0[1].asText ?? "")" }).count == 25)
        #expect(Set(rows.map { "\($0[1].asText ?? "")/\($0[2].asText ?? "")" }).count == 25)
    }

    @Test("A key that counts two NULLs as equal never repeats a NULL combination")
    func nullsCanCollide() throws {
        let table = RowGenerationTable(
            columns: [Self.integerColumn("a", nullable: true), Self.integerColumn("b", nullable: true)],
            uniqueGroups: [["a", "b"]]
        )
        var nullable = Self.range(1, 3)
        nullable.nullRatio = 1
        let rows = try Self.engine(table, ["a": nullable, "b": nullable], nullsAreDistinct: false).nextRows(4)

        #expect(Set(rows.map { "\($0[0].asText ?? "NULL")/\($0[1].asText ?? "NULL")" }).count == 4)
    }

    @Test("A unique pattern walks the values it can make instead of giving up or writing NULL")
    func uniquePatternFillsItsSpace() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "code", typeName: "char(2)", valueClass: .text(maxLength: 2), isNullable: false, isUnique: true)
        ])
        let values = try Self.engine(table, ["code": Self.generator(.pattern) { $0.pattern = "##" }], seed: 1).nextRows(100)
            .compactMap { $0[0].asText }

        #expect(Set(values).count == 100)
    }

    @Test("A range as wide as BIGINT still gives numbers")
    func widestRangeGivesNumbers() throws {
        let table = RowGenerationTable(columns: [Self.integerColumn("big")])
        let rows = try Self.engine(table, ["big": Self.range(0, .max)]).nextRows(20)

        #expect(rows.allSatisfy { $0[0].asText.flatMap { Int64($0) } != nil })
    }

    @Test("A foreign key column that must not repeat keeps the rest of its key on the same referenced row")
    func uniqueMemberOfCompositeReference() throws {
        let tuples: [[PluginCellValue]] = [["1", "eu"], ["2", "us"], ["3", "ap"]]
        let table = RowGenerationTable(
            columns: [
                RowGenerationColumn(
                    name: "shop_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false,
                    isUnique: true, reference: RowGenerationReferenceSlot(sourceId: "fk", position: 0)
                ),
                RowGenerationColumn(
                    name: "region", typeName: "text", valueClass: .text(maxLength: nil), isNullable: false,
                    reference: RowGenerationReferenceSlot(sourceId: "fk", position: 1)
                )
            ],
            references: [RowGenerationReferenceSource(id: "fk", referencedTable: "shops", columns: ["shop_id", "region"], tuples: tuples)]
        )
        let rows = try Self.engine(table, ["shop_id": Self.generator(.reference), "region": Self.generator(.reference)]).nextRows(3)

        #expect(rows.allSatisfy { row in tuples.contains(row) })
        #expect(Set(rows.map { $0[0] }).count == 3)
    }

    @Test("Columns of one foreign key take their values from the same referenced row")
    func compositeReferenceKeepsRowsTogether() throws {
        let tuples: [[PluginCellValue]] = [["1", "eu"], ["2", "us"], ["3", "ap"]]
        let table = RowGenerationTable(
            columns: [
                RowGenerationColumn(
                    name: "shop_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false,
                    reference: RowGenerationReferenceSlot(sourceId: "fk", position: 0)
                ),
                RowGenerationColumn(
                    name: "region", typeName: "text", valueClass: .text(maxLength: nil), isNullable: false,
                    reference: RowGenerationReferenceSlot(sourceId: "fk", position: 1)
                )
            ],
            references: [RowGenerationReferenceSource(id: "fk", referencedTable: "shops", columns: ["shop_id", "region"], tuples: tuples)]
        )
        let settings = ["shop_id": Self.generator(.reference), "region": Self.generator(.reference)]
        let rows = try Self.engine(table, settings).nextRows(100)

        #expect(rows.allSatisfy { row in tuples.contains(row) })
        #expect(Set(rows.map { $0[0] }).count == 3)
    }

    @Test("A NULL ratio of one gives NULL on a nullable column and never on a NOT NULL one")
    func nullRatioOnlyReachesNullableColumns() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "note", typeName: "text", valueClass: .text(maxLength: nil)),
            RowGenerationColumn(name: "title", typeName: "text", valueClass: .text(maxLength: nil), isNullable: false)
        ])
        let settings = [
            "note": Self.generator(.text) { $0.nullRatio = 1 },
            "title": Self.generator(.text) { $0.nullRatio = 1 }
        ]
        let rows = try Self.engine(table, settings).nextRows(50)

        #expect(rows.allSatisfy { $0[0].isNull })
        #expect(rows.allSatisfy { !$0[1].isNull })
    }

    @Test("Text never runs past the column's declared length")
    func textFitsTheColumn() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "name", typeName: "varchar(8)", valueClass: .text(maxLength: 8), isNullable: false),
            RowGenerationColumn(name: "body", typeName: "varchar(12)", valueClass: .text(maxLength: 12), isNullable: false)
        ])
        let settings = [
            "name": Self.generator(.fullName),
            "body": Self.generator(.text) { $0.minLength = 5; $0.maxLength = 200 }
        ]
        let rows = try Self.engine(table, settings).nextRows(200)

        #expect(rows.allSatisfy { ($0[0].asText?.count ?? 0) <= 8 })
        #expect(rows.allSatisfy { ($0[1].asText?.count ?? 0) <= 12 })
    }

    @Test("A sequence counts up from its start by its step")
    func sequenceCountsUp() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "id", typeName: "bigint", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false, isUnique: true)
        ])
        let rows = try Self.engine(table, ["id": Self.generator(.sequence) { $0.integerMinimum = 101; $0.sequenceStep = 5 }]).nextRows(3)

        #expect(Self.texts(rows, column: 0) == ["101", "106", "111"])
    }

    @Test("Dates, timestamps and decimals are written in the form every engine reads")
    func valuesUseEngineNeutralText() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "day", typeName: "date", valueClass: .date, isNullable: false),
            RowGenerationColumn(name: "at", typeName: "timestamp", valueClass: .timestamp, isNullable: false),
            RowGenerationColumn(name: "price", typeName: "numeric(8,2)", valueClass: .decimal(precision: 8, scale: 2), isNullable: false)
        ])
        let settings = [
            "day": Self.generator(.date) { $0.dateStart = Self.date(2024, 2, 1); $0.dateEnd = Self.date(2024, 2, 29) },
            "at": Self.generator(.dateTime),
            "price": Self.generator(.decimalRange) { $0.decimalMinimum = -5; $0.decimalMaximum = 5; $0.decimalScale = 2 }
        ]
        let rows = try Self.engine(table, settings).nextRows(300)
        let days = Self.texts(rows, column: 0).compactMap { $0 }

        #expect(days.allSatisfy { $0.hasPrefix("2024-02-") && $0.count == 10 })
        #expect(days.contains("2024-02-29"))
        #expect(Self.texts(rows, column: 1).allSatisfy { ($0 ?? "").range(of: #"^2024-\d\d-\d\d \d\d:\d\d:\d\d$"#, options: .regularExpression) != nil })
        let prices = Self.texts(rows, column: 2).compactMap { $0 }
        #expect(prices.allSatisfy { $0.range(of: #"^-?\d\.\d\d$"#, options: .regularExpression) != nil })
        #expect(prices.allSatisfy { (Double($0) ?? 99) >= -5 && (Double($0) ?? 99) <= 5 })
    }

    @Test("A boolean is written the way the engine's dialect spells one")
    func booleanFollowsTheDialect() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "active", typeName: "boolean", valueClass: .boolean, isNullable: false)
        ])
        let words = try Self.engine(table, ["active": Self.generator(.boolean)]).nextRows(40)
        let digits = try Self.engine(table, ["active": Self.generator(.boolean)], booleanStyle: .digits).nextRows(40)
        let always = try Self.engine(table, ["active": Self.generator(.boolean) { $0.trueRatio = 1 }]).nextRows(40)

        #expect(Set(Self.texts(words, column: 0)) == ["true", "false"])
        #expect(Set(Self.texts(digits, column: 0)) == ["1", "0"])
        #expect(Set(Self.texts(always, column: 0)) == ["true"])
    }

    @Test("A UUID carries its version, and version 7 sorts in row order")
    func uuidsCarryTheirVersion() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "v4", typeName: "uuid", valueClass: .uuid, isNullable: false),
            RowGenerationColumn(name: "v7", typeName: "uuid", valueClass: .uuid, isNullable: false)
        ])
        let settings = ["v4": Self.generator(.uuid), "v7": Self.generator(.uuid) { $0.uuidVersion = .v7 }]
        let rows = try Self.engine(table, settings).nextRows(20)
        let fourth = Self.texts(rows, column: 0).compactMap { $0 }
        let seventh = Self.texts(rows, column: 1).compactMap { $0 }

        #expect(fourth.allSatisfy { UUID(uuidString: $0) != nil && Array($0)[14] == "4" })
        #expect(seventh.allSatisfy { UUID(uuidString: $0) != nil && Array($0)[14] == "7" })
        #expect(seventh == seventh.sorted())
    }

    @Test("A pattern fills digits and letters and keeps escaped characters")
    func patternExpands() throws {
        let table = RowGenerationTable(columns: [
            RowGenerationColumn(name: "code", typeName: "text", valueClass: .text(maxLength: nil), isNullable: false)
        ])
        let rows = try Self.engine(table, ["code": Self.generator(.pattern) { $0.pattern = "ORD-##-??\\#" }]).nextRows(30)

        #expect(Self.texts(rows, column: 0).allSatisfy { ($0 ?? "").range(of: #"^ORD-\d\d-[A-Z]{2}#$"#, options: .regularExpression) != nil })
    }
}

struct RowGenerationValueTextTests {
    @Test("Day numbers round trip through the calendar date")
    func dayNumbersRoundTrip() {
        for day: Int64 in [-719_468, -1, 0, 59, 365, 11_016, 19_782, 2_932_896] {
            let civil = RowGenerationValueText.civil(fromDayNumber: day)
            #expect(RowGenerationValueText.dayNumber(year: civil.year, month: civil.month, day: civil.day) == day)
        }
        #expect(RowGenerationValueText.date(dayNumber: 0) == "1970-01-01")
        #expect(RowGenerationValueText.date(dayNumber: 19_782) == "2024-02-29")
        #expect(RowGenerationValueText.dateTime(second: 86_399) == "1970-01-01 23:59:59")
    }

    @Test("A decimal is written from whole steps, signs and leading zeros included")
    func decimalsKeepTheirPlaces() {
        #expect(RowGenerationValueText.decimal(steps: 12_345, scale: 2) == "123.45")
        #expect(RowGenerationValueText.decimal(steps: -5, scale: 2) == "-0.05")
        #expect(RowGenerationValueText.decimal(steps: 7, scale: 0) == "7")
    }
}
