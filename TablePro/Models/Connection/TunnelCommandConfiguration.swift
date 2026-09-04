//
//  TunnelCommandConfiguration.swift
//  TablePro
//

import Foundation

/// How the forwarding process is described.
///
/// A preset carries parameters rather than a command line, so the argument vector it produces is
/// fixed and nothing a field holds can become a flag. `.custom` is the only method that stores a
/// command the user wrote.
enum TunnelCommandMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case kubectl
    case awsSSM
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kubectl: return String(localized: "kubectl port-forward")
        case .awsSSM: return String(localized: "AWS SSM Session")
        case .custom: return String(localized: "Custom Command")
        }
    }

    var executableName: String {
        switch self {
        case .kubectl: return "kubectl"
        case .awsSSM: return "aws"
        case .custom: return ""
        }
    }
}

struct TunnelCommandConfiguration: Codable, Hashable, Sendable {
    var method: TunnelCommandMethod = .kubectl
    var command: String = ""
    var executablePath: String = ""
    var kubernetesNamespace: String = ""
    var kubernetesResource: String = ""
    var kubernetesContext: String = ""
    var awsTarget: String = ""
    var awsProfile: String = ""
    var awsRegion: String = ""

    var isValid: Bool {
        TunnelCommandBuilder.validationIssues(for: self).isEmpty
    }
}

extension TunnelCommandConfiguration {
    private enum CodingKeys: String, CodingKey {
        case method, command, executablePath
        case kubernetesNamespace, kubernetesResource, kubernetesContext
        case awsTarget, awsProfile, awsRegion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decodeIfPresent(TunnelCommandMethod.self, forKey: .method) ?? .kubectl
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        kubernetesNamespace = try container.decodeIfPresent(String.self, forKey: .kubernetesNamespace) ?? ""
        kubernetesResource = try container.decodeIfPresent(String.self, forKey: .kubernetesResource) ?? ""
        kubernetesContext = try container.decodeIfPresent(String.self, forKey: .kubernetesContext) ?? ""
        awsTarget = try container.decodeIfPresent(String.self, forKey: .awsTarget) ?? ""
        awsProfile = try container.decodeIfPresent(String.self, forKey: .awsProfile) ?? ""
        awsRegion = try container.decodeIfPresent(String.self, forKey: .awsRegion) ?? ""
    }
}
