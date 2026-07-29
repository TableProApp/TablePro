//
//  CursorAI.swift
//  TablePro
//

import Foundation

enum CursorAI {
    static let baseURL = "https://api.cursor.com"

    static let curatedModels: [(id: String, name: String)] = [
        ("composer-2.5", "Composer 2.5"),
        ("auto", "Auto"),
        ("composer-2", "Composer 2"),
        ("claude-4.5-sonnet", "Claude 4.5 Sonnet"),
        ("claude-opus-4.8", "Claude Opus 4.8"),
        ("gpt-5.5", "GPT-5.5"),
        ("gpt-5.4", "GPT-5.4"),
        ("gemini-3-pro", "Gemini 3 Pro")
    ]

    static var curatedModelIDs: [String] {
        curatedModels.map { $0.id }
    }
}
