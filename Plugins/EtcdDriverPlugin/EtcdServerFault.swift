//
//  EtcdServerFault.swift
//  EtcdDriverPlugin
//
//  Classifies an etcd v3 gateway failure by the gRPC status code in its body.
//

import Foundation

internal struct EtcdServerFault: Equatable, Sendable {
    internal let grpcCode: Int?
    internal let message: String
}

internal extension EtcdServerFault {
    enum Kind: Equatable, Sendable {
        case credentialsRequired
        case credentialsRejected
        case tokenRejected
        case authRevisionStale
        case authNotEnabled
        case permissionDenied
        case unclassified
    }

    static func decode(httpStatus: Int, body: Data) -> EtcdServerFault {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
           let message = envelope.message ?? envelope.error,
           !message.isEmpty {
            return EtcdServerFault(grpcCode: envelope.code, message: message)
        }
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return EtcdServerFault(
                grpcCode: nil,
                message: String(format: String(localized: "etcd returned HTTP %d"), httpStatus)
            )
        }
        return EtcdServerFault(grpcCode: nil, message: String(text.prefix(maximumMessageLength)))
    }

    var kind: Kind {
        switch grpcCode {
        case Self.unauthenticatedCode:
            return .tokenRejected
        case Self.permissionDeniedCode:
            return .permissionDenied
        case Self.failedPreconditionCode:
            return message.contains(Self.authNotEnabledMarker) ? .authNotEnabled : .unclassified
        case Self.invalidArgumentCode:
            return invalidArgumentKind
        default:
            return .unclassified
        }
    }

    var localizedDescription: String {
        switch kind {
        case .credentialsRequired:
            return String(localized: """
            This etcd server has authentication enabled. Add a username and password to the \
            connection, then connect again.
            """)
        case .credentialsRejected, .tokenRejected:
            return String(format: String(localized: "Authentication failed: %@"), message)
        default:
            return message
        }
    }
}

private extension EtcdServerFault {
    struct Envelope: Decodable {
        let error: String?
        let message: String?
        let code: Int?
    }

    static let maximumMessageLength = 512

    static let invalidArgumentCode = 3
    static let permissionDeniedCode = 7
    static let failedPreconditionCode = 9
    static let unauthenticatedCode = 16

    static let userEmptyMarker = "user name is empty"
    static let authFailedMarker = "authentication failed"
    static let authRevisionMarker = "revision of auth store is old"
    static let authNotEnabledMarker = "authentication is not enabled"

    var invalidArgumentKind: Kind {
        if message.contains(Self.userEmptyMarker) { return .credentialsRequired }
        if message.contains(Self.authFailedMarker) { return .credentialsRejected }
        if message.contains(Self.authRevisionMarker) { return .authRevisionStale }
        return .unclassified
    }
}
