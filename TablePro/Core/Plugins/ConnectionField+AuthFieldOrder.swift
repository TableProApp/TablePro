//
//  ConnectionField+AuthFieldOrder.swift
//  TablePro
//

import TableProPluginKit

extension Collection where Element == ConnectionField {
    /// Fields that decide whether the built-in Username and Password appear: either they carry the
    /// flag themselves (an auth-method dropdown, a password-file toggle), or they gate a dependent
    /// field that carries it (SQL Server's Kerberos principal, Snowflake's OAuth token).
    var credentialControllerIds: Set<String> {
        Set(
            filter { $0.hidesUsername || $0.hidesPassword }
                .map { $0.visibleWhen?.fieldId ?? $0.id }
        )
    }

    /// Splits the fields so the credential controllers render above the built-in Username and
    /// Password. A controller placed below them shifts position every time its own selection shows
    /// or hides those credentials.
    func splitCredentialControllers() -> (controllers: [ConnectionField], rest: [ConnectionField]) {
        let controllerIds = credentialControllerIds
        var controllers: [ConnectionField] = []
        var rest: [ConnectionField] = []
        for field in self {
            if controllerIds.contains(field.id) {
                controllers.append(field)
            } else {
                rest.append(field)
            }
        }
        return (controllers, rest)
    }
}
