#if canImport(CLibMongoc)
import CLibMongoc
import Foundation

// libmongoc keeps a pointer to this object and to the strings in `sslOptions`, so it must outlive every client it is
// installed on. A pool never calls an initiator from its monitor threads, so only single clients take one.
nonisolated final class MongoDBTunnelStreamInitiator: @unchecked Sendable {
    let tls: MongoDBTunnelTLS
    let sslOptions: mongoc_ssl_opt_t
    private let connectTimeoutMS: Int32
    private let ownedStrings: [UnsafeMutablePointer<CChar>]

    init(_ tls: MongoDBTunnelTLS, connectTimeoutMS: Int32) {
        var owned: [UnsafeMutablePointer<CChar>] = []
        func retained(_ text: String?) -> UnsafePointer<CChar>? {
            guard let text, let copy = strdup(text) else { return nil }
            owned.append(copy)
            return UnsafePointer(copy)
        }
        var options = mongoc_ssl_opt_t()
        options.ca_file = retained(tls.caFile)
        options.pem_file = retained(tls.certificateKeyFile)
        options.pem_pwd = retained(tls.certificateKeyPassword)
        options.allow_invalid_hostname = tls.allowsInvalidHostname
        options.weak_cert_validation = tls.allowsInvalidCertificate
        self.tls = tls
        self.sslOptions = options
        self.connectTimeoutMS = connectTimeoutMS
        self.ownedStrings = owned
    }

    deinit {
        ownedStrings.forEach { free($0) }
    }

    func install(on client: OpaquePointer) {
        mongoc_client_set_stream_initiator(client, { uri, host, context, error in
            guard let host, let context else { return nil }
            return Unmanaged<MongoDBTunnelStreamInitiator>.fromOpaque(context).takeUnretainedValue()
                .openStream(uri: uri, host: host, error: error)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func openStream(
        uri: OpaquePointer?,
        host: UnsafePointer<mongoc_host_list_t>,
        error: UnsafeMutablePointer<bson_error_t>?
    ) -> UnsafeMutablePointer<mongoc_stream_t>? {
        let hostName = Self.text(of: host.pointee.host)
        let hostAndPort = Self.text(of: host.pointee.host_and_port)
        // Only the forward reaches the server behind the tunnel; any other address would go around it.
        guard MongoDBTunnelTLS.loopbackHosts.contains(hostName.lowercased()) else {
            return Self.failure(error, MONGOC_ERROR_STREAM_CONNECT, "Refusing to dial \(hostAndPort) around the tunnel")
        }
        let timeoutMS = uri.map { mongoc_uri_get_option_as_int32($0, MONGOC_URI_CONNECTTIMEOUTMS, connectTimeoutMS) }
            ?? connectTimeoutMS
        guard let socket = Self.connect(hostName, port: host.pointee.port, family: host.pointee.family, timeoutMS: timeoutMS)
        else {
            return Self.failure(error, MONGOC_ERROR_STREAM_CONNECT, "Failed to connect to target host: \(hostAndPort)")
        }
        guard let base = mongoc_stream_socket_new(socket) else {
            mongoc_socket_destroy(socket)
            return Self.failure(error, MONGOC_ERROR_STREAM_SOCKET, "Failed to open a stream to \(hostAndPort)")
        }
        // libmongoc writes into the options it is given, so each stream gets its own copy.
        var options = sslOptions
        guard let stream = mongoc_stream_tls_new_with_hostname(base, tls.serverName, &options, 1) else {
            mongoc_stream_destroy(base)
            return Self.failure(error, MONGOC_ERROR_STREAM_SOCKET, "Failed to initialize TLS state for \(hostAndPort)")
        }
        guard mongoc_stream_tls_handshake_block(stream, tls.serverName, timeoutMS, error) else {
            mongoc_stream_destroy(stream)
            return nil
        }
        return mongoc_stream_buffered_new(stream, 1_024)
    }

    private static func connect(_ host: String, port: UInt16, family: Int32, timeoutMS: Int32) -> OpaquePointer? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0 else { return nil }
        defer { freeaddrinfo(addresses) }
        var next = addresses
        while let address = next?.pointee {
            next = address.ai_next
            guard let socket = mongoc_socket_new(address.ai_family, address.ai_socktype, address.ai_protocol) else {
                continue
            }
            let expiry = bson_get_monotonic_time() + Int64(timeoutMS) * 1_000
            if mongoc_socket_connect(socket, address.ai_addr, address.ai_addrlen, expiry) == 0 {
                return socket
            }
            mongoc_socket_destroy(socket)
        }
        return nil
    }

    private static func text<Field>(of field: Field) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func failure(
        _ error: UnsafeMutablePointer<bson_error_t>?,
        _ code: mongoc_error_code_t,
        _ message: String
    ) -> UnsafeMutablePointer<mongoc_stream_t>? {
        guard let error else { return nil }
        error.pointee.domain = MONGOC_ERROR_STREAM.rawValue
        error.pointee.code = code.rawValue
        withUnsafeMutableBytes(of: &error.pointee.message) { buffer in
            let bytes = message.utf8.prefix(buffer.count - 1)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return nil
    }
}
#endif
