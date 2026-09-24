//
//  AIQueryAction.swift
//  TablePro
//

import Foundation

enum AIQueryAction: String, CaseIterable, Codable, Sendable {
    case review
    case explain
    case optimize
    case fixError

    static let editorActions: [AIQueryAction] = [.review, .explain, .optimize]

    var menuTitle: String {
        switch self {
        case .review: return String(localized: "Review with AI")
        case .explain: return String(localized: "Explain with AI")
        case .optimize: return String(localized: "Optimize with AI")
        case .fixError: return String(localized: "Fix with AI")
        }
    }

    var systemImage: String {
        switch self {
        case .review: return "text.magnifyingglass"
        case .explain: return "questionmark.bubble"
        case .optimize: return "gauge.high"
        case .fixError: return "wrench.and.screwdriver"
        }
    }

    func instruction(typeName: String, withStructure: Bool = true) -> String {
        switch self {
        case .review:
            let structure = withStructure
                ? "The table structure attached, with its indexes and row counts, decides what is fast. "
                : ""
            return "Review this \(typeName) for correctness, performance and safety. " + structure
                + "List each finding with its severity and the exact fix. If it is fine as written, say so."
        case .explain:
            return withStructure
                ? "Explain what this \(typeName) does, step by step, using the table structure attached."
                : "Explain what this \(typeName) does, step by step."
        case .optimize:
            return withStructure
                ? "Optimize this \(typeName). Use the indexes and row counts attached to decide what is slow, "
                    + "and give the rewrite or the index to add, with the reason for each."
                : "Optimize this \(typeName), and give the rewrite or the index to add, with the reason for each."
        case .fixError:
            return withStructure
                ? "This \(typeName) failed with the error below. Find the cause using the table structure attached and fix it."
                : "This \(typeName) failed with the error below. Find the cause and fix it."
        }
    }
}
