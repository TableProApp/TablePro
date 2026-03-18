//
//  GroupingStrategy.swift
//  TableProPluginKit
//

public enum GroupingStrategy: String, Codable, Sendable {
    case byDatabase
    case bySchema
    case flat
}
