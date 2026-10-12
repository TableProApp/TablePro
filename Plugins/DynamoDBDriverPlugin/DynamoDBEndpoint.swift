import Foundation
import TableProPluginKit

enum DynamoDBAuthMethod: String, Sendable {
    case accessKey = "credentials"
    case profile
    case singleSignOn = "sso"
    case local

    init(fieldValue: String?) {
        self = fieldValue.flatMap(DynamoDBAuthMethod.init(rawValue:)) ?? .accessKey
    }

    var credentialSource: String {
        switch self {
        case .profile: return "profile"
        case .singleSignOn: return "sso"
        case .accessKey, .local: return "accessKey"
        }
    }
}

/// Where requests go and how they are signed.
struct DynamoDBEndpoint: Sendable, Equatable {
    static let defaultRegion = "us-east-1"
    static let localDefaultURL = "http://localhost:8000"

    let url: URL
    let signingRegion: String
    let isLocal: Bool

    /// Resolves the endpoint from the connection's fields.
    ///
    /// The region is the one the form names, else the profile's own `region`, else us-east-1; the
    /// form used to save us-east-1 for every profile connection, which listed another region's
    /// tables with no error. The host follows the region's partition, so `cn-north-1` reaches
    /// `amazonaws.com.cn`. Plain HTTP is refused for any host but this Mac: a custom endpoint sees
    /// the signed request, including a session token.
    static func resolve(
        fields: [String: String],
        profileRegion: (String) -> String? = { AWSCredentialResolver.profileRegion(named: $0) }
    ) throws -> DynamoDBEndpoint {
        let method = DynamoDBAuthMethod(fieldValue: fields["awsAuthMethod"])
        let region = resolvedRegion(fields: fields, method: method, profileRegion: profileRegion)
        guard isValidRegion(region) else {
            throw DynamoDBError.configuration(
                String(format: String(localized: "\"%@\" is not an AWS region"), region)
            )
        }
        let custom = fields["awsEndpointUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !custom.isEmpty || method == .local else {
            let host = AWSPartition.host(service: "dynamodb", region: region)
            guard let url = URL(string: "https://\(host)/") else {
                throw DynamoDBError.configuration(
                    String(format: String(localized: "\"%@\" is not an AWS region"), region)
                )
            }
            return DynamoDBEndpoint(url: url, signingRegion: region, isLocal: false)
        }

        let text = custom.isEmpty ? localDefaultURL : custom
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw DynamoDBError.configuration(
                String(format: String(localized: "\"%@\" is not a URL. Enter an endpoint such as http://localhost:8000."), text)
            )
        }
        guard scheme == "https" || scheme == "http" else {
            throw DynamoDBError.configuration(String(localized: "The endpoint must start with https:// or http://"))
        }
        let isLoopback = isLoopbackHost(host)
        guard scheme == "https" || isLoopback else {
            throw DynamoDBError.configuration(String(
                localized: "Plain HTTP is only allowed for an endpoint on this Mac (localhost). Use https:// for any other host."
            ))
        }
        return DynamoDBEndpoint(url: url, signingRegion: region, isLocal: isLoopback)
    }

    static func resolvedRegion(
        fields: [String: String],
        method: DynamoDBAuthMethod,
        profileRegion: (String) -> String?
    ) -> String {
        let typed = AWSPartition.canonicalRegion(fields["awsRegion"] ?? "")
        if !typed.isEmpty { return typed }
        if method == .profile || method == .singleSignOn {
            let profile = fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
            if let region = profileRegion(profile).map(AWSPartition.canonicalRegion), !region.isEmpty {
                return region
            }
        }
        return defaultRegion
    }

    /// The region becomes part of the endpoint's host name and of the signature, so it may hold only
    /// what a region name holds. A region from an imported connection or a profile could otherwise
    /// carry `/`, `#` or `@` and move the signed request to another host.
    static func isValidRegion(_ region: String) -> Bool {
        guard !region.isEmpty, region.count <= 64, !region.hasPrefix("-"), !region.hasSuffix("-") else { return false }
        return region.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }

    /// Compares the literal host, with no DNS lookup, so a name cannot resolve its way onto the
    /// loopback allowance.
    static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lowered == "localhost" || lowered == "::1" { return true }
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        return octets.first == "127"
    }
}
