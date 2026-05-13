//
//  Reasoning.swift
//  TablePro
//

import Foundation

enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return String(localized: "Minimal")
        case .low:     return String(localized: "Low")
        case .medium:  return String(localized: "Medium")
        case .high:    return String(localized: "High")
        case .xhigh:   return String(localized: "Extra High")
        }
    }

    var openAIWireValue: String { rawValue }

    var anthropicAdaptiveEffort: String? {
        switch self {
        case .minimal: return nil
        case .low:     return "low"
        case .medium:  return "medium"
        case .high:    return "high"
        case .xhigh:   return "maximum"
        }
    }

    var anthropicBudgetTokens: Int? {
        switch self {
        case .minimal: return nil
        case .low:     return 2_048
        case .medium:  return 8_192
        case .high:    return 16_384
        case .xhigh:   return 32_768
        }
    }

    var autoScaledMaxOutputTokens: Int {
        switch self {
        case .minimal: return 4_096
        case .low:     return 8_192
        case .medium:  return 16_384
        case .high:    return 32_768
        case .xhigh:   return 65_536
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
