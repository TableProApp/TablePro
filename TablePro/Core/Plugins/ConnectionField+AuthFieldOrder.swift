//
//  ConnectionField+AuthFieldOrder.swift
//  TablePro
//

import TableProPluginKit

extension Collection where Element == ConnectionField {
    /// Fields that decide whether the built-in Username and Password appear, mapped to whether
    /// Username is among what they hide.
    ///
    /// A field is a controller either by carrying the flag itself (an auth-method dropdown, a
    /// password-file toggle) or by gating a dependent field that carries it (SQL Server's Kerberos
    /// principal, Snowflake's OAuth token).
    var credentialControllerRoles: [String: Bool] {
        var roles: [String: Bool] = [:]
        for field in self where field.hidesUsername || field.hidesPassword {
            let controllerId = field.visibleWhen?.fieldId ?? field.id
            roles[controllerId] = (roles[controllerId] ?? false) || field.hidesUsername
        }
        return roles
    }

    /// Splits the fields so every credential controller renders above what it controls, and no
    /// further up than that.
    ///
    /// A controller below its dependents shifts position every time its own selection shows or
    /// hides them, which is why they are lifted at all. Lifting a password-only controller above
    /// Username as well is the other error: `usePgpass` is a toggle about the password, and it
    /// pushed the Username field third in PostgreSQL's Authentication section.
    func splitCredentialControllers() -> (
        usernameControllers: [ConnectionField],
        passwordControllers: [ConnectionField],
        rest: [ConnectionField]
    ) {
        let roles = credentialControllerRoles
        var usernameControllers: [ConnectionField] = []
        var passwordControllers: [ConnectionField] = []
        var rest: [ConnectionField] = []
        for field in self {
            guard let hidesUsername = roles[field.id] else {
                rest.append(field)
                continue
            }
            if hidesUsername {
                usernameControllers.append(field)
            } else {
                passwordControllers.append(field)
            }
        }
        return (usernameControllers, passwordControllers, rest)
    }
}
