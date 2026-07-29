import CCassandra
import Foundation
import TableProPluginKit

final class CassandraSigV4Context {
    let credentials: AWSCredentials
    let region: String

    init(credentials: AWSCredentials, region: String) {
        self.credentials = credentials
        self.region = region
    }
}

enum CassandraSigV4Authenticator {
    static func apply(to cluster: OpaquePointer, credentials: AWSCredentials, region: String) {
        var callbacks = CassAuthenticatorCallbacks(
            initial_callback: cassandraSigV4Initial,
            challenge_callback: cassandraSigV4Challenge,
            success_callback: nil,
            cleanup_callback: nil
        )
        let context = CassandraSigV4Context(credentials: credentials, region: region)
        let data = Unmanaged.passRetained(context).toOpaque()
        cass_cluster_set_authenticator_callbacks(cluster, &callbacks, cassandraSigV4DataCleanup, data)
    }
}

private func cassandraSigV4Initial(_ auth: OpaquePointer?, _ data: UnsafeMutableRawPointer?) {
    let bytes = Array(KeyspacesSigV4.initialResponse.utf8)
    bytes.withUnsafeBytes { raw in
        cass_authenticator_set_response(auth, raw.bindMemory(to: CChar.self).baseAddress, bytes.count)
    }
}

private func cassandraSigV4Challenge(
    _ auth: OpaquePointer?,
    _ data: UnsafeMutableRawPointer?,
    _ token: UnsafePointer<CChar>?,
    _ tokenSize: Int
) {
    guard let data else { return }
    let context = Unmanaged<CassandraSigV4Context>.fromOpaque(data).takeUnretainedValue()

    let challenge: Data
    if let token, tokenSize > 0 {
        challenge = Data(bytes: token, count: tokenSize)
    } else {
        challenge = Data()
    }
    guard let nonce = KeyspacesSigV4.nonce(fromChallenge: challenge) else { return }

    let response = KeyspacesSigV4.authResponse(
        nonce: nonce,
        credentials: context.credentials,
        region: context.region
    )
    response.withCString { pointer in
        cass_authenticator_set_response(auth, pointer, strlen(pointer))
    }
}

private func cassandraSigV4DataCleanup(_ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<CassandraSigV4Context>.fromOpaque(data).release()
}
