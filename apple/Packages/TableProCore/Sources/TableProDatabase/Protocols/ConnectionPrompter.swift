import Foundation
import TableProSSHTransport

/// A question a connect attempt must put to the user before it can go on.
///
/// The driver layer states the question; the wording and the buttons belong to whoever shows it.
public enum ConnectionQuestion: Sendable, Equatable {
    case unknownHostKey(host: String, port: Int, keyType: String, fingerprint: String)
    case changedHostKey(host: String, port: Int, previousFingerprint: String, currentFingerprint: String)
}

public protocol ConnectionPrompter: Sendable {
    @MainActor
    func confirm(_ question: ConnectionQuestion) async -> Bool

    // False where nobody can type an answer, so sign-in names the server's question instead.
    var answersChallenges: Bool { get }

    // One answer per prompt, in order, or nil when the user declined.
    @MainActor
    func answer(_ challenge: KeyboardInteractiveChallenge) async -> [String]?
}

public extension ConnectionPrompter {
    var answersChallenges: Bool { false }

    @MainActor
    func answer(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        nil
    }
}
