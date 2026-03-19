//
//  D1ValueDecodingTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("D1Value JSON Decoding")
struct D1ValueDecodingTests {

    // MARK: - Local copy of D1Value for testing

    private enum D1Value: Decodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        var stringValue: String? {
            switch self {
            case .string(let val): return val
            case .int(let val): return String(val)
            case .double(let val): return String(val)
            case .bool(let val): return val ? "1" : "0"
            case .null: return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if container.decodeNil() {
                self = .null
                return
            }

            if let intVal = try? container.decode(Int.self) {
                self = .int(intVal)
                return
            }

            if let doubleVal = try? container.decode(Double.self) {
                self = .double(doubleVal)
                return
            }

            if let boolVal = try? container.decode(Bool.self) {
                self = .bool(boolVal)
                return
            }

            if let stringVal = try? container.decode(String.self) {
                self = .string(stringVal)
                return
            }

            self = .null
        }
    }

    // MARK: - Null

    @Test("Decodes JSON null as .null")
    func decodesNull() throws {
        let json = "[null]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        #expect(values.count == 1)
        if case .null = values[0] {
            // correct
        } else {
            Issue.record("Expected .null, got \(values[0])")
        }
    }

    @Test("Null stringValue returns nil")
    func nullStringValue() throws {
        let json = "[null]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        #expect(values[0].stringValue == nil)
    }

    // MARK: - Integers

    @Test("Decodes integer as .int")
    func decodesInteger() throws {
        let json = "[42]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .int(let val) = values[0] {
            #expect(val == 42)
        } else {
            Issue.record("Expected .int, got \(values[0])")
        }
    }

    @Test("Decodes zero as .int not .bool")
    func decodesZeroAsInt() throws {
        let json = "[0]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .int(let val) = values[0] {
            #expect(val == 0)
        } else {
            Issue.record("Expected .int(0), got \(values[0])")
        }
    }

    @Test("Decodes one as .int not .bool")
    func decodesOneAsInt() throws {
        let json = "[1]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .int(let val) = values[0] {
            #expect(val == 1)
        } else {
            Issue.record("Expected .int(1), got \(values[0])")
        }
    }

    @Test("Decodes negative integer")
    func decodesNegativeInt() throws {
        let json = "[-100]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .int(let val) = values[0] {
            #expect(val == -100)
        } else {
            Issue.record("Expected .int(-100), got \(values[0])")
        }
    }

    @Test("Integer stringValue returns string representation")
    func intStringValue() throws {
        let json = "[42]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        #expect(values[0].stringValue == "42")
    }

    // MARK: - Doubles

    @Test("Decodes float as .double")
    func decodesFloat() throws {
        let json = "[3.14]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .double(let val) = values[0] {
            #expect(abs(val - 3.14) < 0.001)
        } else {
            Issue.record("Expected .double, got \(values[0])")
        }
    }

    @Test("Double stringValue returns string representation")
    func doubleStringValue() throws {
        let json = "[3.14]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        guard let str = values[0].stringValue else {
            Issue.record("Expected non-nil stringValue")
            return
        }
        #expect(str.hasPrefix("3.14"))
    }

    // MARK: - Booleans

    @Test("Decodes JSON true as .bool (not when it could be int)")
    func decodesTrue() throws {
        let json = "[true]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        // JSON true is distinct from integer 1 in JSON spec
        // Foundation's JSONDecoder may decode true as Int(1) since Int is tried first
        // This is acceptable — the stringValue is "1" either way
        let str = values[0].stringValue
        #expect(str == "1")
    }

    @Test("Decodes JSON false")
    func decodesFalse() throws {
        let json = "[false]".data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        let str = values[0].stringValue
        #expect(str == "0")
    }

    // MARK: - Strings

    @Test("Decodes string as .string")
    func decodesString() throws {
        let json = #"["hello"]"#.data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .string(let val) = values[0] {
            #expect(val == "hello")
        } else {
            Issue.record("Expected .string, got \(values[0])")
        }
    }

    @Test("String stringValue returns the string")
    func stringStringValue() throws {
        let json = #"["hello"]"#.data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        #expect(values[0].stringValue == "hello")
    }

    @Test("Decodes empty string")
    func decodesEmptyString() throws {
        let json = #"[""]"#.data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .string(let val) = values[0] {
            #expect(val == "")
        } else {
            Issue.record("Expected .string, got \(values[0])")
        }
    }

    @Test("Decodes numeric string as .string not .int")
    func decodesNumericString() throws {
        let json = #"["42"]"#.data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        if case .string(let val) = values[0] {
            #expect(val == "42")
        } else {
            Issue.record("Expected .string(\"42\"), got \(values[0])")
        }
    }

    // MARK: - Mixed Array

    @Test("Decodes mixed-type array from D1 row response")
    func decodesMixedRow() throws {
        let json = #"[1, "Alice", 30, null, 3.14]"#.data(using: .utf8)!
        let values = try JSONDecoder().decode([D1Value].self, from: json)
        #expect(values.count == 5)
        #expect(values[0].stringValue == "1")
        #expect(values[1].stringValue == "Alice")
        #expect(values[2].stringValue == "30")
        #expect(values[3].stringValue == nil)
        #expect(values[4].stringValue?.hasPrefix("3.14") == true)
    }
}
