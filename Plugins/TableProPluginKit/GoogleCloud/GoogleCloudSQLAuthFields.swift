import Foundation

/// Cloud SQL IAM sign-in for PostgreSQL and MySQL, offered on the same Authentication picker as
/// AWS IAM: two pickers could both be switched on, and only one token can be the password.
public enum GoogleCloudSQLAuthFields {
    public static let applicationDefault = "gcpApplicationDefault"
    public static let serviceAccount = "gcpServiceAccount"
    public static let serviceAccountKeyFieldId = "gcpServiceAccountKey"
    public static let methods: Set<String> = [applicationDefault, serviceAccount]

    public static func standardWithAWS() -> [ConnectionField] {
        AWSAuthFields.standard(additionalMethods: [
            .init(value: applicationDefault, label: String(localized: "Google Cloud IAM (Application Default)")),
            .init(value: serviceAccount, label: String(localized: "Google Cloud IAM (Service Account)"))
        ]) + [
            ConnectionField(
                id: serviceAccountKeyFieldId,
                label: String(localized: "Service Account Key"),
                placeholder: String(localized: "File path or paste JSON"),
                required: true,
                fieldType: .secure,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: [serviceAccount])
            )
        ]
    }
}
