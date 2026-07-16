import Foundation
import GSS
import TableProMSSQLCore

struct MSSQLKerberosCache {
    let name: String
    let filePath: String

    func destroy() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}

enum MSSQLKerberosCredentials {
    static func acquireTicket(principal: String, password: String) throws -> MSSQLKerberosCache {
        let fileName = "tablepro-krb5-\(UUID().uuidString)"
        let filePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(fileName)
        let cacheName = "FILE:\(filePath)"

        let importedName = try importName(principal)
        defer {
            var releaseMinor: OM_uint32 = 0
            var releasable: gss_name_t? = importedName
            _ = gss_release_name(&releaseMinor, &releasable)
        }

        let attributes = NSMutableDictionary()
        attributes[kGSSICPassword] = password
        attributes[kGSSICKerberosCacheName] = cacheName

        var cred: gss_cred_id_t?
        var errorRef: Unmanaged<CFError>?
        let status = gss_aapl_initial_cred(
            importedName,
            &__gss_krb5_mechanism_oid_desc,
            attributes as CFDictionary,
            &cred,
            &errorRef
        )

        guard status == 0 else {
            let message = errorRef?.takeRetainedValue().localizedDescription
                ?? String(localized: "Kerberos ticket request failed")
            try? FileManager.default.removeItem(atPath: filePath)
            throw MSSQLCoreError.kerberosAuthFailed(
                kind: MSSQLKerberosClassifier.classify(message) ?? .wrongPassword,
                serverMessage: message
            )
        }

        if cred != nil {
            var releaseMinor: OM_uint32 = 0
            _ = gss_release_cred(&releaseMinor, &cred)
        }

        return MSSQLKerberosCache(name: cacheName, filePath: filePath)
    }

    private static func importName(_ principal: String) throws -> gss_name_t {
        var minor: OM_uint32 = 0
        var name: gss_name_t?
        let status = principal.withCString { cString -> OM_uint32 in
            var buffer = gss_buffer_desc(
                length: strlen(cString),
                value: UnsafeMutableRawPointer(mutating: cString)
            )
            return gss_import_name(&minor, &buffer, &__gss_c_nt_user_name_oid_desc, &name)
        }
        guard status == 0, let name else {
            throw MSSQLCoreError.kerberosAuthFailed(
                kind: .principalUnknown,
                serverMessage: String(
                    format: String(localized: "Invalid Kerberos principal: %@"),
                    principal
                )
            )
        }
        return name
    }
}
