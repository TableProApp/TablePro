import Foundation
import TableProPluginKit

struct AWSRegion: Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let partitionId: String
}

enum AWSRegionCatalog {
    static let all: [AWSRegion] = [
        AWSRegion(id: "us-east-1", displayName: "US East (N. Virginia)", partitionId: "aws"),
        AWSRegion(id: "us-east-2", displayName: "US East (Ohio)", partitionId: "aws"),
        AWSRegion(id: "us-west-1", displayName: "US West (N. California)", partitionId: "aws"),
        AWSRegion(id: "us-west-2", displayName: "US West (Oregon)", partitionId: "aws"),
        AWSRegion(id: "af-south-1", displayName: "Africa (Cape Town)", partitionId: "aws"),
        AWSRegion(id: "ap-east-1", displayName: "Asia Pacific (Hong Kong)", partitionId: "aws"),
        AWSRegion(id: "ap-east-2", displayName: "Asia Pacific (Taipei)", partitionId: "aws"),
        AWSRegion(id: "ap-northeast-1", displayName: "Asia Pacific (Tokyo)", partitionId: "aws"),
        AWSRegion(id: "ap-northeast-2", displayName: "Asia Pacific (Seoul)", partitionId: "aws"),
        AWSRegion(id: "ap-northeast-3", displayName: "Asia Pacific (Osaka)", partitionId: "aws"),
        AWSRegion(id: "ap-south-1", displayName: "Asia Pacific (Mumbai)", partitionId: "aws"),
        AWSRegion(id: "ap-south-2", displayName: "Asia Pacific (Hyderabad)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-1", displayName: "Asia Pacific (Singapore)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-2", displayName: "Asia Pacific (Sydney)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-3", displayName: "Asia Pacific (Jakarta)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-4", displayName: "Asia Pacific (Melbourne)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-5", displayName: "Asia Pacific (Malaysia)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-6", displayName: "Asia Pacific (New Zealand)", partitionId: "aws"),
        AWSRegion(id: "ap-southeast-7", displayName: "Asia Pacific (Thailand)", partitionId: "aws"),
        AWSRegion(id: "ca-central-1", displayName: "Canada (Central)", partitionId: "aws"),
        AWSRegion(id: "ca-west-1", displayName: "Canada West (Calgary)", partitionId: "aws"),
        AWSRegion(id: "eu-central-1", displayName: "Europe (Frankfurt)", partitionId: "aws"),
        AWSRegion(id: "eu-central-2", displayName: "Europe (Zurich)", partitionId: "aws"),
        AWSRegion(id: "eu-north-1", displayName: "Europe (Stockholm)", partitionId: "aws"),
        AWSRegion(id: "eu-south-1", displayName: "Europe (Milan)", partitionId: "aws"),
        AWSRegion(id: "eu-south-2", displayName: "Europe (Spain)", partitionId: "aws"),
        AWSRegion(id: "eu-west-1", displayName: "Europe (Ireland)", partitionId: "aws"),
        AWSRegion(id: "eu-west-2", displayName: "Europe (London)", partitionId: "aws"),
        AWSRegion(id: "eu-west-3", displayName: "Europe (Paris)", partitionId: "aws"),
        AWSRegion(id: "il-central-1", displayName: "Israel (Tel Aviv)", partitionId: "aws"),
        AWSRegion(id: "me-central-1", displayName: "Middle East (UAE)", partitionId: "aws"),
        AWSRegion(id: "me-south-1", displayName: "Middle East (Bahrain)", partitionId: "aws"),
        AWSRegion(id: "mx-central-1", displayName: "Mexico (Central)", partitionId: "aws"),
        AWSRegion(id: "sa-east-1", displayName: "South America (Sao Paulo)", partitionId: "aws"),
        AWSRegion(id: "cn-north-1", displayName: "China (Beijing)", partitionId: "aws-cn"),
        AWSRegion(id: "cn-northwest-1", displayName: "China (Ningxia)", partitionId: "aws-cn"),
        AWSRegion(id: "us-gov-east-1", displayName: "AWS GovCloud (US-East)", partitionId: "aws-us-gov"),
        AWSRegion(id: "us-gov-west-1", displayName: "AWS GovCloud (US-West)", partitionId: "aws-us-gov"),
        AWSRegion(id: "eusc-de-east-1", displayName: "European Sovereign Cloud (Germany)", partitionId: "aws-eusc")
    ]

    /// A region the catalog has not caught up with, named by a profile, still has to be
    /// selectable: `AWSPartition` resolves its endpoint from the identifier alone.
    static func regionOrCustom(id: String) -> AWSRegion? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = region(id: normalized) { return known }
        guard isWellFormed(normalized) else { return nil }
        return AWSRegion(
            id: normalized,
            displayName: normalized,
            partitionId: AWSPartition.resolve(region: normalized).id
        )
    }

    static func region(id: String) -> AWSRegion? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == normalized }
    }

    static func displayName(for id: String) -> String {
        region(id: id)?.displayName ?? id
    }

    static func isWellFormed(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 5, normalized.count <= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return normalized.contains("-") && !normalized.hasPrefix("-") && !normalized.hasSuffix("-")
    }
}
