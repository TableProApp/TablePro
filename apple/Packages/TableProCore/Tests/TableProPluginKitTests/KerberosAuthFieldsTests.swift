import Foundation
import TableProPluginKit
import Testing

struct KerberosAuthFieldsTests {
    private func pickerValues(_ fields: [ConnectionField]) -> [String] {
        guard case .dropdown(let options) = fields.first(where: { $0.id == "awsAuth" })?.fieldType else { return [] }
        return options.map(\.value)
    }

    @Test("Kerberos joins the one Authentication picker after the IAM methods")
    func kerberosJoinsThePicker() {
        #expect(pickerValues(KerberosAuthFields.standardWithAWS()) == ["off", "accessKey", "profile", "sso", "kerberos"])
        #expect(pickerValues(KerberosAuthFields.standardWithAWSAndGoogleCloud()) == [
            "off", "accessKey", "profile", "sso", "gcpApplicationDefault", "gcpServiceAccount", "kerberos"
        ])
        #expect(KerberosAuthFields.standardWithAWSAndGoogleCloud().filter { $0.id == "awsAuth" }.count == 1)
    }

    @Test("The principal and password show only for Kerberos, and the password is a secret")
    func credentialFieldsAreGated() throws {
        let fields = KerberosAuthFields.standardWithAWS()
        let principal = try #require(fields.first { $0.id == KerberosAuthFields.principalFieldId })
        let password = try #require(fields.first { $0.id == KerberosAuthFields.passwordFieldId })
        let kerberosOnly = FieldVisibilityRule(fieldId: "awsAuth", values: ["kerberos"])
        #expect(principal.visibleWhen == kerberosOnly)
        #expect(password.visibleWhen == kerberosOnly)
        #expect(password.isSecure)
        #expect(!principal.isRequired && !password.isRequired)
        #expect(!principal.hidesUsername)
    }

    @Test("GSS Encryption offers libpq's three gssencmode values and defaults to prefer")
    func gssEncryptionField() {
        let field = KerberosAuthFields.gssEncryptionField()
        guard case .dropdown(let options) = field.fieldType else {
            Issue.record("Expected a dropdown")
            return
        }
        #expect(options.map(\.value) == KerberosAuthFields.gssEncryptionModes)
        #expect(field.defaultValue == "prefer")
        #expect(field.visibleWhen == FieldVisibilityRule(fieldId: "awsAuth", values: ["kerberos"]))
    }

    @Test("Only the Kerberos picker value selects it")
    func isSelected() {
        #expect(KerberosAuthFields.isSelected(in: ["awsAuth": "kerberos"]))
        for value in ["off", "accessKey", "gcpApplicationDefault", ""] {
            #expect(!KerberosAuthFields.isSelected(in: ["awsAuth": value]))
        }
        #expect(!KerberosAuthFields.isSelected(in: [:]))
    }

    @Test("The existing pickers stay as they were")
    func existingPickersUnchanged() {
        #expect(pickerValues(AWSAuthFields.standard()) == ["off", "accessKey", "profile", "sso"])
        #expect(pickerValues(GoogleCloudSQLAuthFields.standardWithAWS()) == [
            "off", "accessKey", "profile", "sso", "gcpApplicationDefault", "gcpServiceAccount"
        ])
    }
}
