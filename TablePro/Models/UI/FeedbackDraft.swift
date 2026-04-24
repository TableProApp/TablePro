//
//  FeedbackDraft.swift
//  TablePro
//

import Foundation

struct FeedbackDraft: Codable {
    var feedbackType: String
    var title: String
    var description: String
    var stepsToReproduce: String
    var expectedBehavior: String
    var includeDiagnostics: Bool
}
