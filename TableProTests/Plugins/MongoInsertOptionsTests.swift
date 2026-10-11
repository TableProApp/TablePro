//
//  MongoInsertOptionsTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoInsertOptionsTests {
    /// libbson 1.28.1's `bson_validate_flags_t`, which the test target cannot import.
    private enum LibbsonValidation {
        static let utf8 = 1 << 0
        static let dollarKeys = 1 << 1
        static let dotKeys = 1 << 2
        static let utf8AllowNull = 1 << 3
        static let emptyKeys = 1 << 4
    }

    /// `_mongoc_default_insert_vflags` in libmongoc 1.28.1, used when an insert passes no options.
    private let libmongocInsertDefault = LibbsonValidation.utf8 | LibbsonValidation.utf8AllowNull
        | LibbsonValidation.emptyKeys

    private func validate(in json: String) throws -> Int {
        let data = try #require(json.data(using: .utf8))
        let options = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(options.keys.sorted() == ["validate"])
        let number = try #require(options["validate"] as? NSNumber)
        #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
        return number.intValue
    }

    @Test("An insert asks for libmongoc's default check without the one that refuses a field named \"\"")
    func dropsOnlyTheEmptyNameCheck() throws {
        let validate = try validate(in: MongoInsertOptions.json)
        #expect(validate & LibbsonValidation.emptyKeys == 0)
        #expect(validate == libmongocInsertDefault & ~LibbsonValidation.emptyKeys)
    }

    @Test("An insert keeps the UTF-8 check and adds no key check of its own")
    func keepsTheRestOfTheDefault() throws {
        let validate = try validate(in: MongoInsertOptions.json)
        #expect(validate != 0)
        #expect(validate & LibbsonValidation.utf8 != 0)
        #expect(validate & LibbsonValidation.utf8AllowNull != 0)
        #expect(validate & (LibbsonValidation.dollarKeys | LibbsonValidation.dotKeys) == 0)
    }

    @Test("The options text carries the value the type names")
    func textMatchesValue() throws {
        #expect(try validate(in: MongoInsertOptions.json) == MongoInsertOptions.validation)
    }
}
