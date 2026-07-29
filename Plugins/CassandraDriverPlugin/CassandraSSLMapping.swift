import CCassandra
import Foundation
import TableProPluginKit

enum CassandraSSLMapping {
    static func verifyFlags(for mode: SSLMode) -> Int32 {
        switch mode {
        case .disabled:
            return Int32(CASS_SSL_VERIFY_NONE.rawValue)
        case .preferred, .required:
            return Int32(CASS_SSL_VERIFY_NONE.rawValue)
        case .verifyCa:
            return Int32(CASS_SSL_VERIFY_PEER_CERT.rawValue)
        case .verifyIdentity:
            return Int32(CASS_SSL_VERIFY_PEER_CERT.rawValue | CASS_SSL_VERIFY_PEER_IDENTITY.rawValue)
        }
    }
}
