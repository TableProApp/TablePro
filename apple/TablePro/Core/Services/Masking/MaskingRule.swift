//
//  MaskingRule.swift
//  TablePro
//

import Foundation

enum MaskingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case lastFour
    case email
    case hash
    case null

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return String(localized: "Full")
        case .lastFour: return String(localized: "Last 4 Characters")
        case .email: return String(localized: "Email")
        case .hash: return String(localized: "Stable Hash")
        case .null: return "NULL"
        }
    }
}

enum MaskingTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case column
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .column: return String(localized: "Column")
        case .type: return String(localized: "Type")
        }
    }
}

struct MaskingRule: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var pattern: String
    var target: MaskingTarget
    var style: MaskingStyle

    init(id: UUID = UUID(), pattern: String, target: MaskingTarget = .column, style: MaskingStyle = .full) {
        self.id = id
        self.pattern = pattern
        self.target = target
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, target, style
    }

    /// What a rule this release cannot read in full becomes, so a style, target or field a newer release added
    /// never shows a value it meant to hide.
    static let maskEverything = MaskingRule(pattern: "*")

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        let target = try container.decodeIfPresent(String.self, forKey: .target).map { MaskingTarget(rawValue: $0) }
        let style = try container.decodeIfPresent(String.self, forKey: .style).map { MaskingStyle(rawValue: $0) }
        guard let pattern, target != .some(nil) else {
            self.pattern = Self.maskEverything.pattern
            self.target = .column
            self.style = .full
            return
        }
        self.pattern = pattern
        self.target = target.flatMap { $0 } ?? .column
        self.style = style.flatMap { $0 } ?? .full
    }

    var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
