import Foundation
import GSS
import TableProMSSQLCore

enum MSSQLKerberosCredentials {
    private static let acquisitionQueue = DispatchQueue(
        label: "com.TablePro.mssql.kerberos-acquire",
        qos: .userInitiated
    )

    static func acquireTicket(principal: String, password: String, timeoutSeconds: Int) async throws -> String {
        let cachePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tablepro-krb5-\(UUID().uuidString)")
        return try await runCancellableBlocking(
            on: acquisitionQueue,
            deadline: .seconds(timeoutSeconds),
            timeoutError: { MSSQLCoreError.connectionTimedOut(isKerberos: true) },
            work: {
                try acquireTicketSync(principal: principal, password: password, cachePath: cachePath)
                return cachePath
            },
            discardLateResult: { path in try? FileManager.default.removeItem(atPath: path) }
        )
    }

    private static func acquireTicketSync(principal: String, password: String, cachePath: String) throws {
        let importedName = try importName(principal)
        defer {
            var releaseMinor: OM_uint32 = 0
            var releasable: gss_name_t? = importedName
            _ = gss_release_name(&releaseMinor, &releasable)
        }

        let attributes = NSMutableDictionary()
        attributes[kGSSICPassword] = password
        attributes[kGSSICKerberosCacheName] = "FILE:\(cachePath)"

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
            try? FileManager.default.removeItem(atPath: cachePath)
            throw MSSQLCoreError.kerberosAuthFailed(
                kind: MSSQLKerberosClassifier.classify(message) ?? .wrongPassword,
                serverMessage: message
            )
        }

        if cred != nil {
            var releaseMinor: OM_uint32 = 0
            _ = gss_release_cred(&releaseMinor, &cred)
        }
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
