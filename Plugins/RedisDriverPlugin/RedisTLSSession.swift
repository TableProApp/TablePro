#if canImport(CRedis)
import CRedis
import Foundation

nonisolated enum RedisTLSSession {
    static func initiate(
        on context: UnsafeMutablePointer<redisContext>,
        options: RedisTLSOptions
    ) throws(RedisTLSFailure) {
        let sslContext = try makeContext(options)
        defer { SSL_CTX_free(sslContext) }

        guard let ssl = SSL_new(sslContext) else {
            throw .handshakeFailed("Couldn't create new SSL instance")
        }
        do throws(RedisTLSFailure) {
            try configureSession(ssl, options: options)
        } catch {
            SSL_free(ssl)
            throw error
        }

        guard redisInitiateSSL(context, ssl) == REDIS_OK else {
            let failure = handshakeFailure(of: ssl, on: context)
            SSL_free(ssl)
            throw failure
        }
    }

    private static func makeContext(_ options: RedisTLSOptions) throws(RedisTLSFailure) -> OpaquePointer {
        guard let sslContext = SSL_CTX_new(TLS_client_method()) else {
            throw rejection(REDIS_SSL_CTX_CREATE_FAILED)
        }
        do throws(RedisTLSFailure) {
            try configureContext(sslContext, options: options)
            return sslContext
        } catch {
            SSL_CTX_free(sslContext)
            throw error
        }
    }

    private static func configureContext(
        _ sslContext: OpaquePointer,
        options: RedisTLSOptions
    ) throws(RedisTLSFailure) {
        SSL_CTX_ctrl(sslContext, SSL_CTRL_SET_MIN_PROTO_VERSION, Int(TLS1_2_VERSION), nil)
        let verifyMode = options.verifiesCertificate ? REDIS_SSL_VERIFY_PEER : REDIS_SSL_VERIFY_NONE
        SSL_CTX_set_verify(sslContext, verifyMode, nil)

        guard (options.clientCertificatePath == nil) == (options.clientKeyPath == nil) else {
            throw rejection(REDIS_SSL_CTX_CERT_KEY_REQUIRED)
        }

        if let caCertificatePath = options.caCertificatePath {
            guard SSL_CTX_load_verify_locations(sslContext, caCertificatePath, nil) == 1 else {
                throw rejection(REDIS_SSL_CTX_CA_CERT_LOAD_FAILED)
            }
        } else {
            guard SSL_CTX_set_default_verify_paths(sslContext) == 1 else {
                throw rejection(REDIS_SSL_CTX_CLIENT_DEFAULT_CERT_FAILED)
            }
        }

        guard let certificatePath = options.clientCertificatePath,
              let keyPath = options.clientKeyPath else { return }
        guard SSL_CTX_use_certificate_chain_file(sslContext, certificatePath) == 1 else {
            throw rejection(REDIS_SSL_CTX_CLIENT_CERT_LOAD_FAILED)
        }
        guard SSL_CTX_use_PrivateKey_file(sslContext, keyPath, SSL_FILETYPE_PEM) == 1 else {
            throw rejection(REDIS_SSL_CTX_PRIVATE_KEY_LOAD_FAILED)
        }
    }

    private static func configureSession(_ ssl: OpaquePointer, options: RedisTLSOptions) throws(RedisTLSFailure) {
        let namesServer = options.serverName.withCString { serverName in
            SSL_ctrl(
                ssl,
                SSL_CTRL_SET_TLSEXT_HOSTNAME,
                Int(TLSEXT_NAMETYPE_host_name),
                UnsafeMutableRawPointer(mutating: serverName)
            ) == 1
        }
        guard namesServer else {
            throw .handshakeFailed("Failed to set server_name/SNI")
        }
        guard let expectedHost = options.expectedHost else { return }
        guard SSL_set1_host(ssl, expectedHost) == 1 else {
            throw .handshakeFailed("Failed to set the name to verify")
        }
    }

    private static func handshakeFailure(
        of ssl: OpaquePointer,
        on context: UnsafeMutablePointer<redisContext>
    ) -> RedisTLSFailure {
        let message = errorMessage(of: context)
        let verifyResult = SSL_get_verify_result(ssl)
        let certificateNamesAnotherHost = verifyResult == Int(X509_V_ERR_HOSTNAME_MISMATCH)
            || verifyResult == Int(X509_V_ERR_IP_ADDRESS_MISMATCH)
        guard certificateNamesAnotherHost else { return .handshakeFailed(message) }
        let reason = String(cString: X509_verify_cert_error_string(verifyResult))
        return .certificateNameMismatch("\(message): \(reason)")
    }

    private static func rejection(_ error: redisSSLContextError) -> RedisTLSFailure {
        .contextRejected(code: Int(error.rawValue))
    }

    private static func errorMessage(of context: UnsafeMutablePointer<redisContext>) -> String {
        let errorText = context.pointee.errstr
        return withUnsafePointer(to: errorText) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: errorText)) {
                String(cString: $0)
            }
        }
    }
}
#endif
