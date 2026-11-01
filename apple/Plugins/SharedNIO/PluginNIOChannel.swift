//
//  PluginNIOChannel.swift
//  TablePro
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import TableProPluginKit

enum PluginNIOChannel {
    // Cancelling a task cannot interrupt a connect in flight, so the connect and the cancellation race: whichever
    // lands first resumes the caller, and a channel that arrives after the caller left is closed.
    static func connect(_ bootstrap: ClientBootstrap, host: String, port: Int) async throws -> Channel {
        let gate = ConnectGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.arm(continuation)
                bootstrap.connect(host: host, port: port).whenComplete { result in
                    switch result {
                    case .success(let channel):
                        if !gate.deliver(channel) { channel.close(promise: nil) }
                    case .failure(let error):
                        gate.fail(error)
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    static func tlsContext(for ssl: SSLConfiguration) throws -> NIOSSLContext? {
        guard ssl.isEnabled else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch ssl.mode {
        case .verifyIdentity: configuration.certificateVerification = .fullVerification
        case .verifyCa: configuration.certificateVerification = .noHostnameVerification
        default: configuration.certificateVerification = .none
        }
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(ssl.caCertificatePath))
        }
        if !ssl.clientCertificatePath.isEmpty {
            let chain = try NIOSSLCertificate.fromPEMFile(ssl.clientCertificatePath)
            configuration.certificateChain = chain.map { .certificate($0) }
        }
        if !ssl.clientKeyPath.isEmpty {
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: ssl.clientKeyPath, format: .pem))
        }
        return try NIOSSLContext(configuration: configuration)
    }

    static func describe(_ error: Error) -> String {
        if let tlsError = error as? NIOSSLError {
            switch tlsError {
            case .handshakeFailed: return String(localized: "the TLS handshake failed")
            case .failedToLoadCertificate: return String(localized: "the certificate file could not be read")
            case .failedToLoadPrivateKey: return String(localized: "the private key file could not be read")
            default: return String(describing: tlsError)
            }
        }
        if let tlsError = error as? NIOSSLExtraError, tlsError == .failedToValidateHostname {
            return String(localized: "the server's certificate does not cover the hostname you connected to")
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return String(localized: "the connection timed out")
        }
        if let connectError = error as? NIOConnectionError, let first = connectError.connectionErrors.first {
            return describe(first.error)
        }
        if let ioError = error as? IOError {
            if ioError.errnoCode == ECONNREFUSED { return String(localized: "the connection was refused") }
            return String(cString: strerror(ioError.errnoCode))
        }
        return error.localizedDescription
    }
}

private final class ConnectGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Channel, Error>?
    private var settled = false
    private let lock = NIOLock()

    func arm(_ continuation: CheckedContinuation<Channel, Error>) {
        let alreadySettled: Bool = lock.withLock {
            if settled { return true }
            self.continuation = continuation
            return false
        }
        // A cancellation can land before the continuation is armed.
        if alreadySettled { continuation.resume(throwing: CancellationError()) }
    }

    func deliver(_ channel: Channel) -> Bool {
        guard let waiting = take() else { return false }
        waiting.resume(returning: channel)
        return true
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    func cancel() {
        take()?.resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Channel, Error>? {
        lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { continuation = nil }
            return continuation
        }
    }
}
