//
//  ValueDisplayFormatTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ValueDisplayFormat")
struct ValueDisplayFormatTests {
    @Test("rawValue strings stay stable")
    func rawValueStability() {
        #expect(ValueDisplayFormat.raw.rawValue == "raw")
        #expect(ValueDisplayFormat.uuid.rawValue == "uuid")
        #expect(ValueDisplayFormat.unixTimestamp.rawValue == "unixTimestamp")
        #expect(ValueDisplayFormat.unixTimestampMillis.rawValue == "unixTimestampMillis")
        #expect(ValueDisplayFormat.json.rawValue == "json")
        #expect(ValueDisplayFormat.phpSerialized.rawValue == "phpSerialized")
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        for format in ValueDisplayFormat.allCases {
            let encoded = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(ValueDisplayFormat.self, from: encoded)
            #expect(decoded == format)
        }
    }

    @Test("text column applicable formats include json and phpSerialized")
    func applicableForText() {
        let formats = ValueDisplayFormat.applicableFormats(for: .text(rawType: "TEXT"))
        #expect(formats.contains(.json))
        #expect(formats.contains(.phpSerialized))
        #expect(formats.contains(.uuid))
        #expect(formats.contains(.raw))
        #expect(!formats.contains(.unixTimestamp))
    }

    @Test("integer column applicable formats do not include json or phpSerialized")
    func applicableForInteger() {
        let formats = ValueDisplayFormat.applicableFormats(for: .integer(rawType: "INT"))
        #expect(!formats.contains(.json))
        #expect(!formats.contains(.phpSerialized))
        #expect(formats.contains(.unixTimestamp))
    }

    @Test("blob column does not include json or phpSerialized")
    func applicableForBlob() {
        let formats = ValueDisplayFormat.applicableFormats(for: .blob(rawType: "BLOB"))
        #expect(!formats.contains(.json))
        #expect(!formats.contains(.phpSerialized))
        #expect(formats.contains(.uuid))
    }

    @Test("nil column type returns only raw")
    func applicableForNil() {
        let formats = ValueDisplayFormat.applicableFormats(for: nil)
        #expect(formats == [.raw])
    }
}
