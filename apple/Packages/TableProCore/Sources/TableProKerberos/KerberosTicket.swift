import Foundation
@preconcurrency import GSS
import TableProCoreTypes

public enum KerberosTicketError: Error, Equatable, Sendable {
    case rejected(kind: KerberosFailureKind, message: String)
}

// A principal and password typed into a connection get their own FILE cache, so the ticket never
// joins the user's credentials or replaces the one kinit put in the default cache.
public enum KerberosTicket {
    private static let acquisitionQueue = DispatchQueue(
        label: "com.TablePro.kerberos.acquire",
        qos: .userInitiated
    )

    public static func acquire(
        principal: String,
        password: String,
        timeoutMilliseconds: Int,
        timeoutError: @escaping @Sendable () -> Error
    ) async throws -> String {
        let cachePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tablepro-krb5-\(UUID().uuidString)")
        return try await runCancellableBlocking(
            on: acquisitionQueue,
            deadline: .milliseconds(timeoutMilliseconds),
            timeoutError: timeoutError,
            work: {
                try acquireSync(principal: principal, password: password, cachePath: cachePath)
                return cachePath
            },
            discardLateResult: { discard($0) }
        )
    }

    public static func discard(_ cachePath: String) {
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    private static func acquireSync(principal: String, password: String, cachePath: String) throws {
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
            discard(cachePath)
            throw KerberosTicketError.rejected(
                kind: KerberosFailureClassifier.classify(message) ?? .wrongPassword,
                message: message
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
            throw KerberosTicketError.rejected(
                kind: .principalUnknown,
                message: String(format: String(localized: "Invalid Kerberos principal: %@"), principal)
            )
        }
        return name
    }
}
