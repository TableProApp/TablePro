import TableProPluginKit
import Testing

struct MySQLConnectionEncodingTests {
    @Test("A missing, empty or unknown field value is plain UTF-8")
    func fieldValueParsing() {
        #expect(MySQLConnectionEncoding(fieldValue: nil) == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "") == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "sjis") == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "utf8ViaLatin1") == .utf8ViaLatin1)
    }

    @Test("The connection's additional fields resolve to an encoding")
    func additionalFieldsParsing() {
        #expect(MySQLConnectionEncoding(additionalFields: [:]) == .utf8)
        #expect(MySQLConnectionEncoding(additionalFields: ["mysqlConnectionEncoding": "utf8ViaLatin1"]) == .utf8ViaLatin1)
        #expect(MySQLConnectionEncoding(additionalFields: ["other": "utf8ViaLatin1"]) == .utf8)
    }

    @Test("Only UTF-8 via Latin 1 changes the client character set, and only the client's")
    func sessionStatements() {
        #expect(MySQLConnectionEncoding.utf8.sessionStatements.isEmpty)
        #expect(MySQLConnectionEncoding.utf8ViaLatin1.sessionStatements == ["SET character_set_client = latin1"])
        #expect(MySQLConnectionEncoding.sessionCharacterSetName == "utf8mb4")
        #expect(MySQLConnectionEncoding.sessionFallbackStatement == "SET NAMES utf8")
    }

    @Test("The field is an advanced dropdown whose values the driver reads back")
    func fieldShape() throws {
        let field = MySQLConnectionEncoding.connectionField
        #expect(field.id == MySQLConnectionEncoding.fieldId)
        #expect(field.section == .advanced)
        guard case .dropdown(let options) = field.fieldType else {
            Issue.record("expected a dropdown")
            return
        }
        #expect(options.map(\.value) == MySQLConnectionEncoding.allCases.map(\.rawValue))
        for option in options {
            #expect(MySQLConnectionEncoding(fieldValue: option.value).rawValue == option.value)
        }
    }
}
