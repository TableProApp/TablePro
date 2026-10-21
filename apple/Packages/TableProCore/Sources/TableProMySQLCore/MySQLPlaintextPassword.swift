import Foundation

// Connector/C answers a server that asks for the password as typed (mysql_clear_password, or dialog for PAM)
// even without TLS, ignoring MYSQL_ENABLE_CLEARTEXT_PLUGIN. A server, or anyone who strips TLS on the way, can
// ask for it that way, so a session that might run without TLS allows only the methods that keep it hidden.
public enum MySQLPlaintextPassword {
    public static let methodsWithoutTLS = hiddenPasswordMethods.joined(separator: ",")

    // auth_gssapi_client answers with whatever ticket the credential cache holds, which can be the
    // one another connect is signing in with, so only a Kerberos sign-in may use it.
    public static let kerberosMethod = "auth_gssapi_client"

    private static let hiddenPasswordMethods = [
        "mysql_native_password",
        "caching_sha2_password",
        "sha256_password",
        "mysql_old_password",
        "client_ed25519",
        "parsec",
        kerberosMethod
    ]

    private static let typedPasswordMethods = ["mysql_clear_password", "dialog"]

    // nil leaves every method the connector has.
    public static func allowedMethods(withoutTLS: Bool, signsInWithKerberos: Bool) -> String? {
        if signsInWithKerberos {
            return withoutTLS ? methodsWithoutTLS : nil
        }
        let methods = withoutTLS ? hiddenPasswordMethods : hiddenPasswordMethods + typedPasswordMethods
        return methods.filter { $0 != kerberosMethod }.joined(separator: ",")
    }

    public static func isKerberosRefusal(code: UInt32, message: String) -> Bool {
        isRefusal(code: code) && message.contains("'\(kerberosMethod)'")
    }

    public static var kerberosRefusalMessage: String {
        String(localized: "This account signs in with Kerberos. Set Authentication to Kerberos (GSSAPI), then reconnect.")
    }

    // CR_PLUGIN_NOT_ALLOWED, which Connector/C 3.4.4 returns before it sends anything for the password.
    public static let refusedCode: UInt32 = 5_010

    public static func isRefusal(code: UInt32) -> Bool {
        code == refusedCode
    }

    public static var refusalMessage: String {
        String(
            localized: "The server asked for the password in plain text, which TablePro sends only over TLS. Set SSL Mode to Required, or turn TLS on for the server."
        )
    }
}
