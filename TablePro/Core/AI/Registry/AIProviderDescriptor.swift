//
//  AIProviderDescriptor.swift
//  TablePro
//
//  Descriptor for an AI provider type, including capabilities and factory closure.
//

import Foundation

/// Capabilities supported by an AI provider
struct AIProviderCapabilities: OptionSet, Sendable {
    let rawValue: UInt8

    static let chat = AIProviderCapabilities(rawValue: 1 << 0)
    static let inline = AIProviderCapabilities(rawValue: 1 << 1)
    static let models = AIProviderCapabilities(rawValue: 1 << 2)
}

/// Describes an AI provider type for the registry
struct AIProviderDescriptor: Sendable {
    let typeID: String
    let displayName: String
    let defaultEndpoint: String
    let requiresAPIKey: Bool
    let capabilities: AIProviderCapabilities
    let symbolName: String
    let makeProvider: @Sendable (AIProviderConfig, String?) -> AIProvider
}
