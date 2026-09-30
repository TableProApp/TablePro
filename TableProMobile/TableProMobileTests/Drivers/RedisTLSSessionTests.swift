import CRedis
import Darwin
import Foundation
@testable import TableProMobile
import TableProTLSTestFixtures
import Testing

struct RedisTLSSessionTests {
    @Test("Verify Identity refuses a trusted certificate issued for another host name")
    func verifyIdentityRefusesAnotherHostName() throws {
        let handshake = try LoopbackTLSHandshake()
        let failure = try handshake.run(handshake.options(host: "redis.other.example", verifiesHostname: true))
        #expect(nameMismatchMessage(of: failure)?.hasSuffix("hostname mismatch") == true)
    }

    @Test("Verify Identity refuses a trusted certificate issued for another IP address")
    func verifyIdentityRefusesAnotherAddress() throws {
        let handshake = try LoopbackTLSHandshake()
        let failure = try handshake.run(handshake.options(host: "10.0.0.5", verifiesHostname: true))
        #expect(nameMismatchMessage(of: failure)?.hasSuffix("IP address mismatch") == true)
    }

    @Test("Verify Identity accepts a certificate that names the host", arguments: ["localhost", "127.0.0.1"])
    func verifyIdentityAcceptsTheNamedHost(host: String) throws {
        let handshake = try LoopbackTLSHandshake()
        let failure = try handshake.run(handshake.options(host: host, verifiesHostname: true))
        #expect(failure == nil)
    }

    @Test("Verify CA accepts a trusted certificate issued for another host")
    func verifyCaIgnoresTheHostName() throws {
        let handshake = try LoopbackTLSHandshake()
        let failure = try handshake.run(handshake.options(host: "redis.other.example", verifiesHostname: false))
        #expect(failure == nil)
    }

    @Test("Verify Identity refuses a certificate that names the host but no trusted authority signed")
    func verifyIdentityStillChecksTheChain() throws {
        let handshake = try LoopbackTLSHandshake()
        let options = handshake.options(host: "localhost", verifiesHostname: true, trustsAuthority: false)
        let failure = try handshake.run(options)
        guard case .handshakeFailed(let message) = failure else {
            Issue.record("Expected an untrusted chain to fail the handshake, got \(String(describing: failure))")
            return
        }
        #expect(message.contains("certificate verify failed"))
    }

    private func nameMismatchMessage(of failure: RedisTLSFailure?) -> String? {
        guard case .certificateNameMismatch(let message) = failure else { return nil }
        return message
    }
}

private final class LoopbackTLSHandshake {
    private let directory: URL
    private let authorityPath: String
    private let certificatePath: String
    private let keyPath: String

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedisTLSSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        authorityPath = try writeFixture(TLSTestFixtures.caCertificate, named: "ca.pem", in: directory)
        certificatePath = try writeFixture(TLSTestFixtures.serverCertificate, named: "server.pem", in: directory)
        keyPath = try writeFixture(TLSTestFixtures.serverKey, named: "server.key", in: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func options(host: String, verifiesHostname: Bool, trustsAuthority: Bool = true) -> RedisTLSOptions {
        RedisTLSOptions(
            host: host,
            verifiesCertificate: true,
            verifiesHostname: verifiesHostname,
            caCertificatePath: trustsAuthority ? authorityPath : nil,
            clientCertificatePath: nil,
            clientKeyPath: nil
        )
    }

    func run(_ options: RedisTLSOptions) throws -> RedisTLSFailure? {
        var sockets: [Int32] = [-1, -1]
        let paired = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
        try #require(paired == 0)
        sockets.forEach(limitBlocking(of:))
        let serverSocket = sockets[1]
        let certificatePath = certificatePath
        let keyPath = keyPath
        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            acceptHandshake(on: serverSocket, certificatePath: certificatePath, keyPath: keyPath)
            close(serverSocket)
            served.signal()
        }
        let context = try #require(redisConnectFd(sockets[0]))
        let failure = initiateSession(on: context, options: options)
        redisFree(context)
        #expect(served.wait(timeout: .now() + 10) == .success)
        return failure
    }
}

private func initiateSession(
    on context: UnsafeMutablePointer<redisContext>,
    options: RedisTLSOptions
) -> RedisTLSFailure? {
    do throws(RedisTLSFailure) {
        try RedisTLSSession.initiate(on: context, options: options)
        return nil
    } catch {
        return error
    }
}

private func acceptHandshake(on socket: Int32, certificatePath: String, keyPath: String) {
    guard let context = SSL_CTX_new(TLS_server_method()) else { return }
    defer { SSL_CTX_free(context) }
    guard SSL_CTX_use_certificate_file(context, certificatePath, SSL_FILETYPE_PEM) == 1,
          SSL_CTX_use_PrivateKey_file(context, keyPath, SSL_FILETYPE_PEM) == 1,
          let ssl = SSL_new(context) else { return }
    defer { SSL_free(ssl) }
    SSL_set_fd(ssl, socket)
    SSL_accept(ssl)
}

private func limitBlocking(of socket: Int32) {
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
