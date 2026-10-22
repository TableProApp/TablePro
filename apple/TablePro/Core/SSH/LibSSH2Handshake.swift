// Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
// MainActor isolation, so every top-level declaration states its own.

import Foundation

import CLibSSH2
import TableProSSHTransport

nonisolated enum LibSSH2Handshake {
    enum Failure: Equatable, Sendable {
        case negotiation(SSHNegotiationFailure)
        case timedOut
        case failed(String)
    }

    // Reads what the failure needs before the caller frees the session, which drops what the
    // negotiation agreed.
    static func perform(_ session: OpaquePointer, socket: Int32) -> Failure? {
        let watch = TransportWatch(session)
        let rc = withExtendedLifetime(watch) { libssh2_session_handshake(session, socket) }
        let end = watch.stop()
        guard rc != 0 else { return nil }

        // libssh2_session_methods overwrites the last error when a method is missing, so it is read first.
        let detail = lastError(session)
        switch (rc, end) {
        // libssh2 gives the same code when the connection ends before the server's KEXINIT.
        case (LIBSSH2_ERROR_KEX_FAILURE, .disconnected(let message)?):
            return .failed(String(
                format: String(localized: "The SSH server ended the connection during the handshake: %@"),
                message
            ))
        case (LIBSSH2_ERROR_KEX_FAILURE, .closed?):
            return .failed(String(localized: "The SSH server closed the connection during the handshake."))
        case (LIBSSH2_ERROR_KEX_FAILURE, nil):
            return .negotiation(negotiation(session))
        case (LIBSSH2_ERROR_TIMEOUT, _):
            return .timedOut
        default:
            return .failed(detail ?? "libssh2 error \(rc)")
        }
    }

    private static func negotiation(_ session: OpaquePointer) -> SSHNegotiationFailure {
        let stage = SSHNegotiationFailure.stage(
            kex: method(session, LIBSSH2_METHOD_KEX),
            cipher: agreed(session, LIBSSH2_METHOD_CRYPT_CS, LIBSSH2_METHOD_CRYPT_SC),
            mac: agreed(session, LIBSSH2_METHOD_MAC_CS, LIBSSH2_METHOD_MAC_SC)
        )

        var supported: [String] = []
        var supportedHostKeys: [String] = []
        switch stage {
        case .keyExchangeOrHostKey:
            supported = SSHNegotiationFailure.clientMethods(algorithms(session, LIBSSH2_METHOD_KEX))
            supportedHostKeys = algorithms(session, LIBSSH2_METHOD_HOSTKEY)
        case .cipher:
            supported = algorithms(session, LIBSSH2_METHOD_CRYPT_CS)
        case .mac:
            supported = algorithms(session, LIBSSH2_METHOD_MAC_CS)
        case .undetermined:
            break
        }

        return SSHNegotiationFailure(
            stage: stage,
            serverSoftware: SSHNegotiationFailure.serverSoftware(banner: banner(session)),
            supported: supported,
            supportedHostKeys: supportedHostKeys
        )
    }

    // libssh2 agrees each direction on its own, so one side alone is not an agreement.
    private static func agreed(_ session: OpaquePointer, _ clientToServer: Int32, _ serverToClient: Int32) -> String? {
        guard let outgoing = method(session, clientToServer), method(session, serverToClient) != nil else {
            return nil
        }
        return outgoing
    }

    private static func method(_ session: OpaquePointer, _ type: Int32) -> String? {
        guard let name = libssh2_session_methods(session, type) else { return nil }
        return String(cString: name)
    }

    private static func algorithms(_ session: OpaquePointer, _ type: Int32) -> [String] {
        var names: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, type, &names)
        guard count > 0, let names else { return [] }
        defer { libssh2_free(session, names) }
        return (0 ..< Int(count)).compactMap { index in names[index].map { String(cString: $0) } }
    }

    private static func banner(_ session: OpaquePointer) -> String? {
        guard let banner = libssh2_session_banner_get(session) else { return nil }
        return String(cString: banner)
    }

    private static func lastError(_ session: OpaquePointer) -> String? {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        guard let message, length > 0 else { return nil }
        return String(cString: message)
    }
}

private typealias LibSSH2Callback = @convention(c) () -> Void
private typealias LibSSH2Recv = @convention(c) (
    libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int
private typealias LibSSH2Send = @convention(c) (
    libssh2_socket_t, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int
private typealias LibSSH2Disconnect = @convention(c) (
    OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void

nonisolated private enum TransportEnd {
    case closed
    case disconnected(String)
}

// Passes the handshake's socket reads and writes through to libssh2's own and notes an end of
// stream, a failed call or the server's DISCONNECT. The session's abstract pointer carries it, as
// keyboard-interactive does.
nonisolated private final class TransportWatch {
    private let session: OpaquePointer
    private let savedAbstract: UnsafeMutableRawPointer?
    private let previousRecv: LibSSH2Callback?
    private let previousSend: LibSSH2Callback?
    private let previousDisconnect: LibSSH2Callback?
    fileprivate let recv: LibSSH2Recv?
    fileprivate let send: LibSSH2Send?
    fileprivate var end: TransportEnd?

    init(_ session: OpaquePointer) {
        self.session = session
        let recvHook: LibSSH2Recv = watchedRecv
        let sendHook: LibSSH2Send = watchedSend
        let disconnectHook: LibSSH2Disconnect = watchedDisconnect
        previousRecv = libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_RECV, unsafeBitCast(recvHook, to: LibSSH2Callback.self)
        )
        previousSend = libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_SEND, unsafeBitCast(sendHook, to: LibSSH2Callback.self)
        )
        previousDisconnect = libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_DISCONNECT, unsafeBitCast(disconnectHook, to: LibSSH2Callback.self)
        )
        recv = previousRecv.map { unsafeBitCast($0, to: LibSSH2Recv.self) }
        send = previousSend.map { unsafeBitCast($0, to: LibSSH2Send.self) }
        let abstract = libssh2_session_abstract(session)
        savedAbstract = abstract?.pointee
        abstract?.pointee = Unmanaged.passUnretained(self).toOpaque()
    }

    func stop() -> TransportEnd? {
        libssh2_session_abstract(session)?.pointee = savedAbstract
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, previousRecv)
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, previousSend)
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_DISCONNECT, previousDisconnect)
        return end
    }

    fileprivate func noteClosed() {
        if end == nil { end = .closed }
    }

    fileprivate static func of(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> TransportWatch? {
        guard let pointer = abstract?.pointee else { return nil }
        return Unmanaged<TransportWatch>.fromOpaque(pointer).takeUnretainedValue()
    }
}

nonisolated private func watchedRecv(
    _ socket: libssh2_socket_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ length: Int,
    _ flags: Int32,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int {
    guard let watch = TransportWatch.of(abstract), let recv = watch.recv else { return -Int(EINVAL) }
    let received = recv(socket, buffer, length, flags, abstract)
    if received == 0 || (received < 0 && received != -Int(EAGAIN)) {
        watch.noteClosed()
    }
    return received
}

nonisolated private func watchedSend(
    _ socket: libssh2_socket_t,
    _ buffer: UnsafeRawPointer?,
    _ length: Int,
    _ flags: Int32,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int {
    guard let watch = TransportWatch.of(abstract), let send = watch.send else { return -Int(EINVAL) }
    let sent = send(socket, buffer, length, flags, abstract)
    if sent < 0 && sent != -Int(EAGAIN) {
        watch.noteClosed()
    }
    return sent
}

// The message is the server's own text, so it is cut to one line of printable characters.
nonisolated private func watchedDisconnect(
    _ session: OpaquePointer?,
    _ reason: Int32,
    _ message: UnsafePointer<CChar>?,
    _ messageLength: Int32,
    _ language: UnsafePointer<CChar>?,
    _ languageLength: Int32,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    guard let watch = TransportWatch.of(abstract) else { return }
    var text = ""
    if let message, messageLength > 0,
       let decoded = String(bytes: UnsafeRawBufferPointer(start: message, count: Int(messageLength)), encoding: .utf8) {
        text = decoded.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
    watch.end = .disconnected(text.isEmpty ? "reason \(reason)" : String(text.prefix(300)))
}
