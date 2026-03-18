import Foundation
import TableProPluginKit
import Testing

@Suite("ConnectionField")
struct ConnectionFieldTests {

    @Test("Default values: placeholder, isRequired, defaultValue, fieldType")
    func defaultValues() {
        let field = ConnectionField(id: "host", label: "Host")

        #expect(field.placeholder == "")
        #expect(field.isRequired == false)
        #expect(field.defaultValue == nil)
        #expect(field.fieldType == .text)
    }

    @Test("isSecure is false for .text")
    func isSecureForText() {
        let field = ConnectionField(id: "host", label: "Host", fieldType: .text)
        #expect(field.isSecure == false)
    }

    @Test("isSecure is true for .secure")
    func isSecureForSecure() {
        let field = ConnectionField(id: "pass", label: "Password", fieldType: .secure)
        #expect(field.isSecure == true)
    }

    @Test("isSecure is false for .dropdown")
    func isSecureForDropdown() {
        let options = [ConnectionField.DropdownOption(value: "a", label: "A")]
        let field = ConnectionField(id: "mode", label: "Mode", fieldType: .dropdown(options: options))
        #expect(field.isSecure == false)
    }

    @Test("secure param sets fieldType to .secure")
    func secureParam() {
        let field = ConnectionField(id: "pass", label: "Password", secure: true)
        #expect(field.fieldType == .secure)
        #expect(field.isSecure == true)
    }

    @Test("Explicit fieldType overrides secure param")
    func fieldTypeOverridesSecureParam() {
        let options = [ConnectionField.DropdownOption(value: "v", label: "V")]
        let field = ConnectionField(
            id: "mode",
            label: "Mode",
            secure: true,
            fieldType: .dropdown(options: options)
        )
        #expect(field.fieldType == .dropdown(options: options))
        #expect(field.isSecure == false)
    }

    @Test("DropdownOption stores value and label")
    func dropdownOption() {
        let option = ConnectionField.DropdownOption(value: "utf8", label: "UTF-8")
        #expect(option.value == "utf8")
        #expect(option.label == "UTF-8")
    }

    @Test("All properties stored correctly")
    func allPropertiesStored() {
        let field = ConnectionField(
            id: "port",
            label: "Port",
            placeholder: "3306",
            required: true,
            defaultValue: "3306",
            fieldType: .text
        )

        #expect(field.id == "port")
        #expect(field.label == "Port")
        #expect(field.placeholder == "3306")
        #expect(field.isRequired == true)
        #expect(field.defaultValue == "3306")
        #expect(field.fieldType == .text)
    }

    @Test("Codable round-trip for .text field")
    func codableText() throws {
        let field = ConnectionField(
            id: "host",
            label: "Host",
            placeholder: "localhost",
            required: true,
            defaultValue: "127.0.0.1",
            fieldType: .text
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.placeholder == field.placeholder)
        #expect(decoded.isRequired == field.isRequired)
        #expect(decoded.defaultValue == field.defaultValue)
        #expect(decoded.fieldType == .text)
    }

    @Test("Codable round-trip for .secure field")
    func codableSecure() throws {
        let field = ConnectionField(
            id: "password",
            label: "Password",
            required: true,
            fieldType: .secure
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.isRequired == field.isRequired)
        #expect(decoded.fieldType == .secure)
    }

    @Test("Codable round-trip for .dropdown field with options")
    func codableDropdown() throws {
        let options = [
            ConnectionField.DropdownOption(value: "utf8", label: "UTF-8"),
            ConnectionField.DropdownOption(value: "latin1", label: "Latin 1"),
        ]
        let field = ConnectionField(
            id: "charset",
            label: "Charset",
            defaultValue: "utf8",
            fieldType: .dropdown(options: options)
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.defaultValue == field.defaultValue)
        #expect(decoded.fieldType == .dropdown(options: options))
    }

    @Test("Codable round-trip with nil defaultValue")
    func codableNilDefaultValue() throws {
        let field = ConnectionField(id: "host", label: "Host")

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.defaultValue == nil)
        #expect(decoded.id == field.id)
        #expect(decoded.fieldType == .text)
    }

    // MARK: - IntRange

    @Test("IntRange init from ClosedRange")
    func intRangeFromClosedRange() {
        let range = ConnectionField.IntRange(0...15)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 15)
    }

    @Test("IntRange closedRange round-trip")
    func intRangeClosedRangeRoundTrip() {
        let range = ConnectionField.IntRange(3...42)
        #expect(range.closedRange == 3...42)
    }

    @Test("IntRange init from bounds")
    func intRangeFromBounds() {
        let range = ConnectionField.IntRange(lowerBound: 1, upperBound: 100)
        #expect(range.lowerBound == 1)
        #expect(range.upperBound == 100)
        #expect(range.closedRange == 1...100)
    }

    @Test("IntRange decoding rejects invalid bounds")
    func intRangeDecodingRejectsInvalidBounds() throws {
        let json = #"{"lowerBound":10,"upperBound":0}"#
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConnectionField.IntRange.self, from: data)
        }
    }

    // MARK: - isSecure for new types

    @Test("isSecure is false for .number")
    func isSecureForNumber() {
        let field = ConnectionField(id: "port", label: "Port", fieldType: .number)
        #expect(field.isSecure == false)
    }

    @Test("isSecure is false for .toggle")
    func isSecureForToggle() {
        let field = ConnectionField(id: "flag", label: "Flag", fieldType: .toggle)
        #expect(field.isSecure == false)
    }

    @Test("isSecure is false for .stepper")
    func isSecureForStepper() {
        let range = ConnectionField.IntRange(0...15)
        let field = ConnectionField(id: "db", label: "DB", fieldType: .stepper(range: range))
        #expect(field.isSecure == false)
    }

    // MARK: - Codable round-trips for new types

    @Test("Codable round-trip for .number field")
    func codableNumber() throws {
        let field = ConnectionField(
            id: "port",
            label: "Port",
            placeholder: "3306",
            defaultValue: "3306",
            fieldType: .number
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.placeholder == field.placeholder)
        #expect(decoded.defaultValue == field.defaultValue)
        #expect(decoded.fieldType == .number)
    }

    @Test("Codable round-trip for .toggle field")
    func codableToggle() throws {
        let field = ConnectionField(
            id: "compress",
            label: "Compress",
            defaultValue: "false",
            fieldType: .toggle
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.defaultValue == "false")
        #expect(decoded.fieldType == .toggle)
    }

    @Test("Codable round-trip for .stepper field with IntRange")
    func codableStepper() throws {
        let range = ConnectionField.IntRange(0...15)
        let field = ConnectionField(
            id: "redisDatabase",
            label: "Database Index",
            defaultValue: "0",
            fieldType: .stepper(range: range)
        )

        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: data)

        #expect(decoded.id == field.id)
        #expect(decoded.label == field.label)
        #expect(decoded.defaultValue == "0")
        #expect(decoded.fieldType == .stepper(range: range))
    }
}
