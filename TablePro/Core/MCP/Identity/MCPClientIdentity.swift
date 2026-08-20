import CryptoKit
import Foundation

public struct MCPClientIdentity: Sendable, Equatable, Hashable, Identifiable {
    public static let unknownClientName = String(localized: "Unknown client")

    public let clientName: String
    public let clientVersion: String?
    public let tokenId: UUID?
    public let tokenName: String?
    public let principalFingerprint: String
    public let address: MCPClientAddress

    public init(
        clientName: String,
        clientVersion: String?,
        tokenId: UUID?,
        tokenName: String?,
        principalFingerprint: String,
        address: MCPClientAddress
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.tokenId = tokenId
        self.tokenName = tokenName
        self.principalFingerprint = principalFingerprint
        self.address = address
    }

    public init(meta: MCPRequestMeta, principal: MCPPrincipal, address: MCPClientAddress) {
        let info = meta.clientInfo
        let resolvedName = info?.title?.nilIfBlank ?? info?.name.nilIfBlank ?? Self.unknownClientName
        let resolvedVersion = info?.version.nilIfBlank
        self.init(
            clientName: resolvedName,
            clientVersion: resolvedVersion,
            tokenId: principal.tokenId,
            tokenName: principal.metadata.label,
            principalFingerprint: principal.tokenFingerprint,
            address: address
        )
    }

    public var addressDisplayValue: String {
        address.displayValue
    }

    public var id: String {
        let fields = [
            clientName,
            clientVersion ?? "",
            tokenId?.uuidString ?? "",
            principalFingerprint,
            address.displayValue
        ]
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
