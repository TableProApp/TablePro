//
//  Reasoning.swift
//  TablePro
//

import Foundation

// `off` is stored only where a model takes an explicit off; nil sends nothing and leaves the server's default.
enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:     return String(localized: "Off")
        case .minimal: return String(localized: "Minimal")
        case .low:     return String(localized: "Low")
        case .medium:  return String(localized: "Medium")
        case .high:    return String(localized: "High")
        case .xhigh:   return String(localized: "Extra High")
        case .max:     return String(localized: "Maximum")
        }
    }

    // `none` is how OpenAI-style APIs spell off. A spelling of no level here, such as Requesty's `min`, is left out.
    init?(wireValue: String) {
        let value = wireValue.lowercased()
        self.init(rawValue: value == "none" ? "off" : value)
    }

    var wireValue: String {
        self == .off ? "none" : rawValue
    }

    // A level list in wire order, without `off`, with unknown and repeated values dropped.
    static func levels(fromWire values: [String]) -> [ReasoningEffort] {
        var seen: Set<ReasoningEffort> = []
        return values.compactMap(ReasoningEffort.init(wireValue:))
            .filter { $0 != .off && seen.insert($0).inserted }
            .sorted { $0.rank < $1.rank }
    }

    var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    var anthropicBudgetTokens: Int {
        switch self {
        case .off, .minimal: return 1_024
        case .low:           return 2_048
        case .medium:        return 8_192
        case .high:          return 16_384
        case .xhigh:         return 32_768
        case .max:           return 65_536
        }
    }

    var autoScaledMaxOutputTokens: Int? {
        switch self {
        case .off:     return nil
        case .minimal: return 4_096
        case .low:     return 8_192
        case .medium:  return 16_384
        case .high:    return 32_768
        case .xhigh:   return 65_536
        case .max:     return 128_000
        }
    }
}

struct ReasoningOpaque: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case anthropicSignature
        case openAIEncrypted
    }

    let kind: Kind
    let itemID: String
    let value: String
    let blockType: String

    init(kind: Kind, itemID: String, value: String, blockType: String) {
        self.kind = kind
        self.itemID = itemID
        self.value = value
        self.blockType = blockType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID) ?? ""
        value = try container.decode(String.self, forKey: .value)
        blockType = try container.decode(String.self, forKey: .blockType)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, itemID, value, blockType
    }
}

struct ReasoningBlock: Codable, Equatable, Sendable {
    var text: String?
    var opaque: ReasoningOpaque?

    init(text: String? = nil, opaque: ReasoningOpaque? = nil) {
        self.text = text
        self.opaque = opaque
    }
}
