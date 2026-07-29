//
//  SurrealValue.swift
//  SurrealDBDriverPlugin
//

import Foundation

public struct SurrealRecordID: Equatable, Sendable {
    public let table: String
    public let id: SurrealValue

    public init(table: String, id: SurrealValue) {
        self.table = table
        self.id = id
    }
}

public struct SurrealBound: Equatable, Sendable {
    public let value: SurrealValue
    public let isInclusive: Bool

    public init(value: SurrealValue, isInclusive: Bool) {
        self.value = value
        self.isInclusive = isInclusive
    }
}

public indirect enum SurrealValue: Equatable, Sendable {
    case null
    case none
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)
    case array([SurrealValue])
    case object([(key: String, value: SurrealValue)])
    case recordId(SurrealRecordID)
    case table(String)
    case uuid(UUID)
    case decimal(String)
    case datetime(seconds: Int64, nanoseconds: UInt32)
    case duration(seconds: Int64, nanoseconds: UInt32)
    case tagged(tag: UInt64, value: SurrealValue)
    case range(from: SurrealBound?, to: SurrealBound?)

    public static func == (lhs: SurrealValue, rhs: SurrealValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null), (.none, .none):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.int(a), .int(b)):
            return a == b
        case let (.double(a), .double(b)):
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.bytes(a), .bytes(b)):
            return a == b
        case let (.array(a), .array(b)):
            return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.recordId(a), .recordId(b)):
            return a == b
        case let (.table(a), .table(b)):
            return a == b
        case let (.uuid(a), .uuid(b)):
            return a == b
        case let (.decimal(a), .decimal(b)):
            return a == b
        case let (.datetime(sa, na), .datetime(sb, nb)):
            return sa == sb && na == nb
        case let (.duration(sa, na), .duration(sb, nb)):
            return sa == sb && na == nb
        case let (.tagged(ta, va), .tagged(tb, vb)):
            return ta == tb && va == vb
        case let (.range(fa, ta), .range(fb, tb)):
            return fa == fb && ta == tb
        default:
            return false
        }
    }
}

public extension SurrealValue {
    subscript(key: String) -> SurrealValue? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var objectPairs: [(key: String, value: SurrealValue)]? {
        guard case let .object(pairs) = self else { return nil }
        return pairs
    }

    var arrayValues: [SurrealValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .table(name):
            return name
        default:
            return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            return Int64(exactly: value.rounded())
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var isAbsent: Bool {
        switch self {
        case .null, .none:
            return true
        default:
            return false
        }
    }
}
