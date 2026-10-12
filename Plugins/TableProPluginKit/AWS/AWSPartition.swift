import Foundation

public struct AWSPartition: Sendable, Equatable {
    public let id: String
    public let dnsSuffix: String
    public let defaultRegion: String

    public init(id: String, dnsSuffix: String, defaultRegion: String) {
        self.id = id
        self.dnsSuffix = dnsSuffix
        self.defaultRegion = defaultRegion
    }

    public static let standard = AWSPartition(
        id: "aws", dnsSuffix: "amazonaws.com", defaultRegion: "us-east-1"
    )
    public static let china = AWSPartition(
        id: "aws-cn", dnsSuffix: "amazonaws.com.cn", defaultRegion: "cn-north-1"
    )
    public static let govCloud = AWSPartition(
        id: "aws-us-gov", dnsSuffix: "amazonaws.com", defaultRegion: "us-gov-west-1"
    )
    public static let europeanSovereign = AWSPartition(
        id: "aws-eusc", dnsSuffix: "amazonaws.eu", defaultRegion: "eusc-de-east-1"
    )
    public static let iso = AWSPartition(
        id: "aws-iso", dnsSuffix: "c2s.ic.gov", defaultRegion: "us-iso-east-1"
    )
    public static let isoB = AWSPartition(
        id: "aws-iso-b", dnsSuffix: "sc2s.sgov.gov", defaultRegion: "us-isob-east-1"
    )
    public static let isoE = AWSPartition(
        id: "aws-iso-e", dnsSuffix: "cloud.adc-e.uk", defaultRegion: "eu-isoe-west-1"
    )
    public static let isoF = AWSPartition(
        id: "aws-iso-f", dnsSuffix: "csp.hci.ic.gov", defaultRegion: "us-isof-east-1"
    )

    private static let byRegionPrefix: [(prefix: String, partition: AWSPartition)] = [
        ("cn-", china),
        ("us-gov-", govCloud),
        ("us-iso-", iso),
        ("us-isob-", isoB),
        ("us-isof-", isoF),
        ("eu-isoe-", isoE),
        ("eusc-", europeanSovereign)
    ]

    private static let byARNPartition: [String: AWSPartition] = [
        "aws": standard,
        "aws-cn": china,
        "aws-us-gov": govCloud,
        "aws-eusc": europeanSovereign,
        "aws-iso": iso,
        "aws-iso-b": isoB,
        "aws-iso-e": isoE,
        "aws-iso-f": isoF
    ]

    public static func canonicalRegion(_ region: String) -> String {
        region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func resolve(region: String) -> AWSPartition {
        let normalized = canonicalRegion(region)
        for entry in byRegionPrefix where normalized.hasPrefix(entry.prefix) {
            return entry.partition
        }
        return standard
    }

    public static func resolve(arn: String) -> AWSPartition? {
        let parts = arn.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "arn" else { return nil }
        return byARNPartition[String(parts[1]).lowercased()]
    }

    public static func host(service: String, region: String) -> String {
        let normalized = canonicalRegion(region)
        return "\(service).\(normalized).\(resolve(region: normalized).dnsSuffix)"
    }
}
