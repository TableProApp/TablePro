import CLibMongoc
import CRedis
import Darwin
import Foundation
@testable import TableProMobile
import TableProPluginKit
import TableProTLSTestFixtures
import Testing

struct MongoDBTunnelTLSTests {
    @Test("A connection dialing a tunnel's forward checks the certificate against the server behind it")
    func tunneledConnectionVerifiesTheServerName() {
        let config = DriverConnectionConfig(
            host: "127.0.0.1",
            port: 50_123,
            username: "u",
            password: "p",
            database: "app",
            ssl: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem"),
            additionalFields: ["preTunnelHost": "db.example.com"]
        )

        #expect(connection(for: config).tunnelTLS == MongoDBTunnelTLS(
            serverName: "db.example.com",
            caFile: "/certs/ca.pem",
            certificateKeyFile: nil,
            certificateKeyPassword: nil,
            allowsInvalidHostname: false,
            allowsInvalidCertificate: false
        ))
    }

    @Test("A direct connection, or one without TLS, keeps libmongoc's own transport")
    func directOrPlainHasNoInitiator() {
        let direct = DriverConnectionConfig(
            host: "db.example.com",
            port: 27_017,
            username: "u",
            password: "p",
            database: "app",
            ssl: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem"),
            additionalFields: ["preTunnelHost": "other.example.com"]
        )
        let plain = DriverConnectionConfig(
            host: "127.0.0.1",
            port: 50_123,
            username: "u",
            password: "p",
            database: "app",
            additionalFields: ["preTunnelHost": "db.example.com"]
        )

        #expect(connection(for: direct).tunnelTLS == nil)
        #expect(connection(for: plain).tunnelTLS == nil)
    }

    @Test("Each SSL mode keeps the checks it promises on the forward", arguments: [
        (SSLMode.preferred, true, true, false),
        (.required, true, true, false),
        (.verifyCa, true, false, true),
        (.verifyIdentity, false, false, true),
    ])
    func modesKeepTheirChecks(mode: SSLMode, allowsInvalidHostname: Bool, allowsInvalidCertificate: Bool, readsCA: Bool) throws {
        let ssl = SSLConfiguration(mode: mode, caCertificatePath: "/certs/ca.pem")

        let tls = try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com"))

        #expect(tls.serverName == "db.example.com")
        #expect(tls.allowsInvalidHostname == allowsInvalidHostname)
        #expect(tls.allowsInvalidCertificate == allowsInvalidCertificate)
        #expect(tls.caFile == (readsCA ? "/certs/ca.pem" : nil))
    }

    @Test("The client certificate, its joined key file and the passphrase under any spelling reach the initiator")
    func clientCertificateReachesTheInitiator() {
        let ssl = SSLConfiguration(
            mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem", clientCertificatePath: "/certs/client.pem"
        )
        let connection = MongoDBConnection(
            host: "127.0.0.1",
            port: 50_123,
            user: "u",
            password: "p",
            database: "app",
            configuredDatabase: "app",
            ssl: ssl,
            tunneledServerName: "db.example.com",
            extraUriParams: ["SSLClientCertificateKeyPassword": "hunter2"]
        )

        #expect(connection.tunnelTLS?.certificateKeyFile == "/certs/client.pem")
        #expect(connection.tunnelTLS?.certificateKeyPassword == "hunter2")
        #expect(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com", certificateKeyFile: "/tmp/joined.pem")?
            .certificateKeyFile == "/tmp/joined.pem")
    }

    @Test("The initiator hands libmongoc the plan's checks and CA file")
    func initiatorOptionsFollowThePlan() throws {
        let ssl = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem")
        let tls = try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com"))
        let initiator = MongoDBTunnelStreamInitiator(tls, connectTimeoutMS: 1_000)

        withExtendedLifetime(initiator) {
            let options = initiator.sslOptions
            #expect(!options.allow_invalid_hostname)
            #expect(!options.weak_cert_validation)
            #expect(options.ca_file.map { String(cString: $0) } == "/certs/ca.pem")
            #expect(options.pem_file == nil)
            #expect(options.pem_pwd == nil)
        }
    }

    // The certificate names localhost and 127.0.0.1, so checking the dialed loopback would pass it.
    @Test("Through the forward, Verify Identity refuses a certificate that names the loopback but not the server")
    func verifyIdentityChecksTheServerName() throws {
        let server = try LoopbackTLSServer()
        let ssl = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: server.authorityPath)

        let dial = try server.dial(try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com")))

        #expect(!dial.opened)
        #expect(dial.error.contains("hostname mismatch"))
    }

    @Test("Through the forward, Verify Identity accepts a certificate that names the server")
    func verifyIdentityAcceptsTheServerName() throws {
        let server = try LoopbackTLSServer()
        let ssl = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: server.authorityPath)

        let dial = try server.dial(try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "localhost")))

        #expect(dial.opened)
        #expect(dial.sentServerName == "localhost")
    }

    @Test("Through the forward, Verify CA checks the chain only and sends the server's name")
    func verifyCaSendsTheServerName() throws {
        let server = try LoopbackTLSServer()
        let ssl = SSLConfiguration(mode: .verifyCa, caCertificatePath: server.authorityPath)

        let dial = try server.dial(try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com")))

        #expect(dial.opened)
        #expect(dial.sentServerName == "db.example.com")
    }

    @Test("A tunneled connect goes through the initiator, so a dial around the forward is refused")
    func connectInstallsTheInitiator() async {
        let connection = MongoDBConnection(
            host: "db.example.com",
            port: 27_017,
            user: "u",
            password: "p",
            database: "app",
            configuredDatabase: "app",
            ssl: SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem"),
            tunneledServerName: "db.example.com"
        )

        await #expect {
            try await connection.connect()
        } throws: { error in
            (error as? MongoDBError)?.message.contains("Refusing to dial db.example.com:27017") == true
        }
    }

    @Test("The initiator never dials an address other than the forward")
    func refusesToDialAroundTheTunnel() throws {
        mongoc_init()
        let ssl = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem")
        let tls = try #require(MongoDBSSLMapping.tunnelTLS(for: ssl, serverName: "db.example.com"))
        let initiator = MongoDBTunnelStreamInitiator(tls, connectTimeoutMS: 1_000)
        let uri = try #require(mongoc_uri_new("mongodb://db.example.com:27017"))
        defer { mongoc_uri_destroy(uri) }
        let host = try #require(mongoc_uri_get_hosts(uri))
        var error = bson_error_t()

        let stream = initiator.openStream(uri: uri, host: host, error: &error)

        #expect(stream == nil)
        #expect(MongoBsonBuilder.errorMessage(&error).contains("db.example.com:27017"))
    }

    private func connection(for config: DriverConnectionConfig) -> MongoDBConnection {
        MongoDBConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            configuredDatabase: config.database,
            ssl: config.ssl,
            tunneledServerName: config.tunneledServerName
        )
    }
}

private final class LoopbackTLSServer {
    struct SetupFailure: Error {}

    struct Dial {
        let opened: Bool
        let error: String
        let sentServerName: String?
    }

    let authorityPath: String
    private let directory: URL
    private let certificatePath: String
    private let keyPath: String
    private let listener: Int32
    private let port: UInt16

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MongoDBTunnelTLSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        authorityPath = try writeFixture(TLSTestFixtures.caCertificate, named: "ca.pem", in: directory)
        certificatePath = try writeFixture(TLSTestFixtures.serverCertificate, named: "server.pem", in: directory)
        keyPath = try writeFixture(TLSTestFixtures.serverKey, named: "server.key", in: directory)

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SetupFailure() }
        boundTimeouts(of: socketFD)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard bound == 0, Darwin.listen(socketFD, 1) == 0, named == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }
        listener = socketFD
        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    func dial(_ tls: MongoDBTunnelTLS) throws -> Dial {
        mongoc_init()
        let sent = SentServerName()
        let served = DispatchSemaphore(value: 0)
        let listener = listener
        let certificatePath = certificatePath
        let keyPath = keyPath
        DispatchQueue.global().async {
            let connection = accept(listener, nil, nil)
            if connection >= 0 {
                boundTimeouts(of: connection)
                sent.name = acceptHandshake(on: connection, certificatePath: certificatePath, keyPath: keyPath)
                Darwin.close(connection)
            }
            served.signal()
        }

        let uri = try #require(mongoc_uri_new("mongodb://127.0.0.1:\(port)/?connectTimeoutMS=5000"))
        defer { mongoc_uri_destroy(uri) }
        let host = try #require(mongoc_uri_get_hosts(uri))
        let initiator = MongoDBTunnelStreamInitiator(tls, connectTimeoutMS: 5_000)
        var error = bson_error_t()
        let stream = initiator.openStream(uri: uri, host: host, error: &error)
        let opened = stream != nil
        if let stream { mongoc_stream_destroy(stream) }

        #expect(served.wait(timeout: .now() + 10) == .success)
        return Dial(opened: opened, error: MongoBsonBuilder.errorMessage(&error), sentServerName: sent.name)
    }
}

// Written by the server's thread before it signals, read by the test after the wait.
private final class SentServerName: @unchecked Sendable {
    var name: String?
}

private func acceptHandshake(on socket: Int32, certificatePath: String, keyPath: String) -> String? {
    guard let context = SSL_CTX_new(TLS_server_method()) else { return nil }
    defer { SSL_CTX_free(context) }
    guard SSL_CTX_use_certificate_file(context, certificatePath, SSL_FILETYPE_PEM) == 1,
          SSL_CTX_use_PrivateKey_file(context, keyPath, SSL_FILETYPE_PEM) == 1,
          let ssl = SSL_new(context) else { return nil }
    defer { SSL_free(ssl) }
    SSL_set_fd(ssl, socket)
    guard SSL_accept(ssl) == 1 else { return nil }
    return SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name).map { String(cString: $0) }
}

private func boundTimeouts(of socket: Int32) {
    var enabled: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func writeFixture(_ pem: String, named name: String, in directory: URL) throws -> String {
    let file = directory.appendingPathComponent(name)
    try TLSTestFixtures.data(pem).write(to: file)
    return file.path
}
