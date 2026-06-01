//
//  ConnectionMode.swift
//  TableProPluginKit
//

@frozen
public enum ConnectionMode: String, Codable, Sendable {
    case network
    case fileBased
    case apiOnly
}
