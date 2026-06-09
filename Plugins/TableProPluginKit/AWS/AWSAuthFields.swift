import Foundation

public enum AWSAuthFields {
    public static func standard() -> [ConnectionField] {
        [
            ConnectionField(
                id: "awsAuth",
                label: String(localized: "Authentication"),
                defaultValue: "off",
                fieldType: .dropdown(options: [
                    .init(value: "off", label: String(localized: "Password")),
                    .init(value: "accessKey", label: String(localized: "AWS IAM (Access Key)")),
                    .init(value: "profile", label: String(localized: "AWS IAM (Profile)")),
                    .init(value: "sso", label: String(localized: "AWS IAM (SSO)"))
                ]),
                section: .authentication,
                hidesPassword: true
            ),
            ConnectionField(
                id: "awsRegion",
                label: String(localized: "AWS Region"),
                placeholder: "us-east-1",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey", "profile", "sso"])
            ),
            ConnectionField(
                id: "awsAccessKeyId",
                label: String(localized: "Access Key ID"),
                placeholder: "AKIA...",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey"])
            ),
            ConnectionField(
                id: "awsSecretAccessKey",
                label: String(localized: "Secret Access Key"),
                placeholder: "wJalr...",
                fieldType: .secure,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey"])
            ),
            ConnectionField(
                id: "awsSessionToken",
                label: String(localized: "Session Token"),
                placeholder: String(localized: "Optional, for temporary credentials"),
                fieldType: .secure,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey"])
            ),
            ConnectionField(
                id: "awsProfileName",
                label: String(localized: "Profile Name"),
                placeholder: "default",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["profile", "sso"])
            ).withDynamicOptions(.awsProfiles)
        ]
    }

    public static func elastiCacheReplicationGroupField() -> ConnectionField {
        ConnectionField(
            id: "awsReplicationGroupId",
            label: String(localized: "Cache Name / Replication Group ID"),
            placeholder: String(localized: "my-cache"),
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "awsAuth", values: ["accessKey", "profile", "sso"])
        )
    }
}
