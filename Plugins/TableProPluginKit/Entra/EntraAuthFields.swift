import Foundation

public enum EntraField {
    public static let tenantId = "entraTenantId"
    public static let clientId = "entraClientId"
    public static let account = "entraAccount"
}

public enum EntraAppRegistration {
    /// TablePro's own multi-tenant application ID, used when a connection does not name one.
    ///
    /// While this is empty every connection must supply a client ID. That is what tenants with
    /// application consent governance require in any case, and it keeps TablePro from borrowing
    /// another vendor's registration, which would make it indistinguishable from that vendor in
    /// customers' sign-in logs and Conditional Access policies.
    public static let defaultClientId = ""

    public static func clientId(from fields: [String: String]) -> String {
        let supplied = (fields[EntraField.clientId] ?? "").trimmingCharacters(in: .whitespaces)
        return supplied.isEmpty ? defaultClientId : supplied
    }

    public static func tenantId(from fields: [String: String]) -> String {
        let supplied = (fields[EntraField.tenantId] ?? "").trimmingCharacters(in: .whitespaces)
        return supplied.isEmpty ? EntraOAuth.defaultTenant : supplied
    }
}

public enum EntraAuthFields {
    /// Fields a driver adds when it offers Microsoft Entra ID sign-in. `gatedBy` names the
    /// driver's own authentication dropdown and `value` the option that selects Entra ID, so each
    /// driver keeps its existing field id.
    public static func standard(gatedBy fieldId: String, value: String) -> [ConnectionField] {
        let visible = FieldVisibilityRule(fieldId: fieldId, values: [value])
        return [
            ConnectionField(
                id: EntraField.tenantId,
                label: String(localized: "Directory (Tenant) ID"),
                placeholder: String(localized: "Optional, for a single-tenant directory"),
                section: .authentication,
                visibleWhen: visible
            ).withHidesUsername(true),
            ConnectionField(
                id: EntraField.clientId,
                label: String(localized: "Application (Client) ID"),
                placeholder: "00000000-0000-0000-0000-000000000000",
                required: EntraAppRegistration.defaultClientId.isEmpty,
                defaultValue: EntraAppRegistration.defaultClientId.isEmpty
                    ? nil
                    : EntraAppRegistration.defaultClientId,
                section: .authentication,
                hidesPassword: true,
                visibleWhen: visible
            )
        ]
    }
}
