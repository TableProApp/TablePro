//
//  SqlWalkthroughModels.swift
//  TablePro
//

import Foundation

enum SqlWalkthroughImportance: String, Codable, Sendable {
    case critical
    case normal
    case context
}

enum SqlWalkthroughChangeType: String, Codable, Sendable {
    case addition
    case removal
    case modification
    case explanation
}

enum SqlWalkthroughDiffStyle: String, Codable, Sendable {
    case unified
    case split
}

struct SqlWalkthroughAnchor: Codable, Equatable, Sendable {
    enum Side: String, Codable, Sendable {
        case before
        case after
        case both
    }

    let side: Side
    let startLine: Int
    let endLine: Int

    func isValid(beforeLineCount: Int, afterLineCount: Int) -> Bool {
        guard startLine >= 1, endLine >= startLine else { return false }
        switch side {
        case .before:
            return endLine <= beforeLineCount
        case .after:
            return endLine <= afterLineCount
        case .both:
            return endLine <= beforeLineCount && endLine <= afterLineCount
        }
    }
}

struct SqlWalkthroughStep: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let why: String
    let importance: SqlWalkthroughImportance
    let changeType: SqlWalkthroughChangeType
    let anchor: SqlWalkthroughAnchor?

    init(
        id: UUID = UUID(),
        title: String,
        why: String,
        importance: SqlWalkthroughImportance,
        changeType: SqlWalkthroughChangeType,
        anchor: SqlWalkthroughAnchor?
    ) {
        self.id = id
        self.title = title
        self.why = why
        self.importance = importance
        self.changeType = changeType
        self.anchor = anchor
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case why
        case importance
        case changeType
        case anchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try container.decode(String.self, forKey: .title)
        why = (try container.decodeIfPresent(String.self, forKey: .why)) ?? ""
        importance = (try container.decodeIfPresent(SqlWalkthroughImportance.self, forKey: .importance)) ?? .normal
        changeType = (try container.decodeIfPresent(SqlWalkthroughChangeType.self, forKey: .changeType)) ?? .explanation
        anchor = try container.decodeIfPresent(SqlWalkthroughAnchor.self, forKey: .anchor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(why, forKey: .why)
        try container.encode(importance, forKey: .importance)
        try container.encode(changeType, forKey: .changeType)
        try container.encodeIfPresent(anchor, forKey: .anchor)
    }
}

extension SqlWalkthroughStep: Equatable {
    static func == (lhs: SqlWalkthroughStep, rhs: SqlWalkthroughStep) -> Bool {
        lhs.title == rhs.title
            && lhs.why == rhs.why
            && lhs.importance == rhs.importance
            && lhs.changeType == rhs.changeType
            && lhs.anchor == rhs.anchor
    }
}

struct SqlWalkthroughEnvelope: Codable, Equatable, Sendable {
    var afterSQL: String?
    var steps: [SqlWalkthroughStep]

    init(afterSQL: String?, steps: [SqlWalkthroughStep]) {
        self.afterSQL = afterSQL
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case afterSQL
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        afterSQL = try container.decodeIfPresent(String.self, forKey: .afterSQL)
        steps = (try container.decodeIfPresent([SqlWalkthroughStep].self, forKey: .steps)) ?? []
    }
}

struct SqlWalkthroughBlock: Codable, Equatable, Sendable {
    let beforeSQL: String
    var envelope: SqlWalkthroughEnvelope
    var diffStyle: SqlWalkthroughDiffStyle

    init(beforeSQL: String, envelope: SqlWalkthroughEnvelope, diffStyle: SqlWalkthroughDiffStyle = .unified) {
        self.beforeSQL = beforeSQL
        self.envelope = envelope
        self.diffStyle = diffStyle
    }

    private enum CodingKeys: String, CodingKey {
        case beforeSQL
        case envelope
        case diffStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beforeSQL = try container.decode(String.self, forKey: .beforeSQL)
        envelope = try container.decode(SqlWalkthroughEnvelope.self, forKey: .envelope)
        diffStyle = (try container.decodeIfPresent(SqlWalkthroughDiffStyle.self, forKey: .diffStyle)) ?? .unified
    }

    var hasDiff: Bool {
        envelope.afterSQL != nil
    }

    var transcriptText: String {
        guard let afterSQL = envelope.afterSQL, !afterSQL.isEmpty else { return "" }
        return "Proposed SQL:\n\(afterSQL)"
    }
}
