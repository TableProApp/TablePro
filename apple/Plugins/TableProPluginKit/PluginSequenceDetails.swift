//
//  PluginSequenceDetails.swift
//  TableProPluginKit
//

import Foundation

public struct PluginSequenceDetails: Codable, Sendable, Equatable {
    public let name: String
    public let schema: String?
    public let dataType: String?
    public let startValue: Int64?
    public let increment: Int64?
    public let minValue: Int64?
    public let maxValue: Int64?
    public let cacheSize: Int64?
    public let cycles: Bool
    // Nil before the first nextval, or where the user cannot read it.
    public let lastValue: Int64?
    // What the next nextval returns; nil where the sequence cannot be read or is exhausted.
    public let nextValue: Int64?
    // OWNED BY or an identity column; always in the sequence's own schema.
    public let ownedByTable: String?
    public let ownedByColumn: String?

    public init(
        name: String,
        schema: String?,
        dataType: String?,
        startValue: Int64?,
        increment: Int64?,
        minValue: Int64?,
        maxValue: Int64?,
        cacheSize: Int64?,
        cycles: Bool,
        lastValue: Int64?,
        nextValue: Int64?,
        ownedByTable: String?,
        ownedByColumn: String?
    ) {
        self.name = name
        self.schema = schema
        self.dataType = dataType
        self.startValue = startValue
        self.increment = increment
        self.minValue = minValue
        self.maxValue = maxValue
        self.cacheSize = cacheSize
        self.cycles = cycles
        self.lastValue = lastValue
        self.nextValue = nextValue
        self.ownedByTable = ownedByTable
        self.ownedByColumn = ownedByColumn
    }

    public var settings: PluginSequenceSettings? {
        guard let increment, let minValue, let maxValue, let cacheSize else { return nil }
        return PluginSequenceSettings(
            increment: increment,
            minValue: minValue,
            maxValue: maxValue,
            cacheSize: cacheSize,
            cycles: cycles
        )
    }
}

// Numbers only, so a statement built from them cannot carry anything but a number.
public struct PluginSequenceSettings: Codable, Sendable, Equatable {
    public var increment: Int64
    public var minValue: Int64
    public var maxValue: Int64
    public var cacheSize: Int64
    public var cycles: Bool

    public init(increment: Int64, minValue: Int64, maxValue: Int64, cacheSize: Int64, cycles: Bool) {
        self.increment = increment
        self.minValue = minValue
        self.maxValue = maxValue
        self.cacheSize = cacheSize
        self.cycles = cycles
    }
}

public enum PluginSequenceNextValue: Sendable, Equatable {
    case value(Int64)
    // The server reads the owning column when the statement runs, so no row lands in between.
    case afterOwnedColumn
}
