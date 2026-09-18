import Foundation
@testable import TablePro

/// Stands in for the native alert so a test can state the user's answer.
///
/// Nothing in a test may reach the real presenter: `NSAlert.runModal()` blocks its thread until a
/// human dismisses it, which on CI means the job dies on the timeout rather than failing.
actor RecordingApprovalPresenter: MCPApprovalPresenting {
    private let answer: Bool
    private var requests: [MCPApprovalRequest] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func requestApproval(_ request: MCPApprovalRequest) async -> Bool {
        requests.append(request)
        return answer
    }

    var askedCount: Int {
        requests.count
    }

    var lastRequest: MCPApprovalRequest? {
        requests.last
    }
}
