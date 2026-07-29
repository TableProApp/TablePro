//
//  SurrealFieldKind.swift
//  SurrealDBDriverPlugin
//

import Foundation

public struct SurrealFieldKind: Equatable, Sendable {
    public enum Base: String, Equatable, Sendable {
        case any
        case bool
        case bytes
        case datetime
        case decimal
        case duration
        case float
        case geometry
        case int
        case number
        case object
        case record
        case string
        case uuid
        case array
        case set
    }

    public let base: Base
    public let isOptional: Bool
    public let recordTable: String?
    public let raw: String

    public init(base: Base, isOptional: Bool, recordTable: String? = nil, raw: String) {
        self.base = base
        self.isOptional = isOptional
        self.recordTable = recordTable
        self.raw = raw
    }

    public var isRecordLink: Bool {
        base == .record
    }

    public var isStructured: Bool {
        base == .object || base == .array || base == .set
    }

    public static func infer(from value: SurrealValue) -> SurrealFieldKind? {
        let base: Base
        switch value {
        case .bool:
            base = .bool
        case .int:
            base = .int
        case .double:
            base = .float
        case .decimal:
            base = .decimal
        case .string:
            base = .string
        case .bytes:
            base = .bytes
        case .uuid:
            base = .uuid
        case .datetime:
            base = .datetime
        case .duration:
            base = .duration
        case .recordId:
            base = .record
        case .array:
            base = .array
        case .object:
            base = .object
        case .tagged, .range:
            base = .any
        case .null, .none, .table:
            return nil
        }
        return SurrealFieldKind(base: base, isOptional: false, raw: value.typeName)
    }

    public static func parse(_ raw: String) -> SurrealFieldKind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return SurrealFieldKind(base: .any, isOptional: true, raw: raw)
        }

        var body = trimmed
        var isOptional = false

        if let inner = unwrapGeneric(body, prefix: "option") {
            body = inner
            isOptional = true
        }

        let alternatives = splitUnion(body)
        let concrete = alternatives.filter { $0.lowercased() != "none" && $0.lowercased() != "null" }
        if concrete.count != alternatives.count {
            isOptional = true
        }
        body = concrete.first ?? "any"

        return SurrealFieldKind(
            base: baseKind(of: body),
            isOptional: isOptional,
            recordTable: recordTable(of: body),
            raw: raw
        )
    }

    // MARK: - Parsing helpers

    private static func baseKind(of body: String) -> Base {
        let head = genericHead(body).lowercased()
        if let base = Base(rawValue: head) {
            return base
        }
        if head.hasPrefix("geometry") {
            return .geometry
        }
        return .any
    }

    private static func recordTable(of body: String) -> String? {
        guard let inner = unwrapGeneric(body, prefix: "record") else { return nil }
        let table = inner.split(separator: "|").first.map { String($0) } ?? inner
        let trimmed = table.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func genericHead(_ body: String) -> String {
        guard let angle = body.firstIndex(of: "<") else { return body }
        return String(body[body.startIndex..<angle]).trimmingCharacters(in: .whitespaces)
    }

    private static func unwrapGeneric(_ body: String, prefix: String) -> String? {
        let lowered = body.lowercased()
        guard lowered.hasPrefix(prefix.lowercased() + "<"), body.hasSuffix(">") else { return nil }
        let start = body.index(body.startIndex, offsetBy: prefix.count + 1)
        let end = body.index(before: body.endIndex)
        guard start < end else { return nil }
        return String(body[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func splitUnion(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in body {
            switch character {
            case "<":
                depth += 1
                current.append(character)
            case ">":
                depth -= 1
                current.append(character)
            case "|" where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }
}
