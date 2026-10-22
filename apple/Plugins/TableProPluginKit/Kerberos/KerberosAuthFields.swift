import Foundation

// Kerberos sign-in for PostgreSQL and MariaDB, on the same Authentication picker as the IAM
// methods: a ticket takes the password's place, so only one of them can be on.
public enum KerberosAuthFields {
    public static let method = "kerberos"
    public static let principalFieldId = "kerberosPrincipal"
    public static let passwordFieldId = "kerberosPassword"
    public static let gssEncryptionFieldId = "gssEncryptionMode"
    public static let gssEncryptionModes = ["disable", "prefer", "require"]

    private static let pickerFieldId = "awsAuth"

    public static func isSelected(in additionalFields: [String: String]) -> Bool {
        additionalFields[pickerFieldId] == method
    }

    public static func standardWithAWS() -> [ConnectionField] {
        AWSAuthFields.standard(additionalMethods: [option]) + credentialFields
    }

    public static func standardWithAWSAndGoogleCloud() -> [ConnectionField] {
        GoogleCloudSQLAuthFields.standardWithAWS(additionalMethods: [option]) + credentialFields
    }

    // libpq's gssencmode. Shown under Kerberos only: GSS encryption needs the same ticket.
    public static func gssEncryptionField() -> ConnectionField {
        ConnectionField(
            id: gssEncryptionFieldId,
            label: String(localized: "GSS Encryption"),
            defaultValue: "prefer",
            fieldType: .dropdown(options: [
                .init(value: "disable", label: String(localized: "Disabled")),
                .init(value: "prefer", label: String(localized: "Preferred")),
                .init(value: "require", label: String(localized: "Required"))
            ]),
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: pickerFieldId, values: [method])
        )
    }

    private static var option: ConnectionField.DropdownOption {
        .init(value: method, label: String(localized: "Kerberos (GSSAPI)"))
    }

    // Both blank means the ticket kinit put in the credential cache.
    private static var credentialFields: [ConnectionField] {
        [
            ConnectionField(
                id: principalFieldId,
                label: String(localized: "Kerberos Principal"),
                placeholder: "user@REALM.COM",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: pickerFieldId, values: [method])
            ),
            ConnectionField(
                id: passwordFieldId,
                label: String(localized: "Password"),
                fieldType: .secure,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: pickerFieldId, values: [method])
            )
        ]
    }
}
