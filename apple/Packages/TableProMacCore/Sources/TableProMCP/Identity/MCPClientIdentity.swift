import CryptoKit
import Foundation
import TableProUtilities

public enum MCPClientTransport: Sendable, Equatable, Hashable {
    // The credential every stdio client shares through the tablepro-mcp helper; it rotates on its own.
    case stdioBridge
    // A credential of its own: a token from Settings or pairing, over TCP or the app's socket.
    case http
}

public struct MCPClientIdentity: Sendable, Equatable, Hashable, Identifiable {
    public static let unknownClientName = String(localized: "Unknown client")

    public let clientName: String
    public let clientInfoName: String?
    public let clientVersion: String?
    public let tokenId: UUID?
    public let tokenName: String?
    public let principalFingerprint: String
    public let address: MCPClientAddress
    public let transport: MCPClientTransport

    public init(
        clientName: String,
        clientInfoName: String? = nil,
        clientVersion: String?,
        tokenId: UUID?,
        tokenName: String?,
        principalFingerprint: String,
        address: MCPClientAddress,
        transport: MCPClientTransport = .http
    ) {
        self.clientName = clientName
        self.clientInfoName = clientInfoName
        self.clientVersion = clientVersion
        self.tokenId = tokenId
        self.tokenName = tokenName
        self.principalFingerprint = principalFingerprint
        self.address = address
        self.transport = transport
    }

    public init(meta: MCPRequestMeta, principal: MCPPrincipal, address: MCPClientAddress) {
        let info = meta.clientInfo
        let resolvedName = info?.title?.nilIfBlank ?? info?.name.nilIfBlank ?? Self.unknownClientName
        let resolvedVersion = info?.version.nilIfBlank
        self.init(
            clientName: resolvedName,
            clientInfoName: info?.name.nilIfBlank,
            clientVersion: resolvedVersion,
            tokenId: principal.tokenId,
            tokenName: principal.metadata.label,
            principalFingerprint: principal.tokenFingerprint,
            address: address,
            transport: principal.metadata.isBridgeCredential ? .stdioBridge : .http
        )
    }

    public var addressDisplayValue: String {
        address.displayValue
    }

    public var id: String {
        let credential: [String]
        switch transport {
        case .stdioBridge:
            // The bridge credential rotates every 45 minutes, so a stdio client is the client it says it is.
            credential = ["stdio-bridge"]
        case .http:
            credential = [tokenId?.uuidString ?? "", principalFingerprint]
        }
        let fields = [clientName, clientInfoName ?? "", clientVersion ?? ""] + credential + [address.displayValue]
        let joined = fields.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return String(digest.hexEncoded.prefix(16))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
