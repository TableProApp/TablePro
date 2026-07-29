//
//  GroupingStrategy.swift
//  TableProPluginKit
//

@frozen
public enum GroupingStrategy: String, Codable, Sendable {
    case byDatabase
    case bySchema
    case flat
    case hierarchicalSchema
}
