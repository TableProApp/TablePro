import Foundation
import Observation
import os
import TableProDatabase
import TableProSSHTransport

/// What the user is being asked, as the screen shows it.
struct ConnectionPrompt: Identifiable, Equatable {
    enum Style: Equatable {
        case standard
        case destructive
        case notice
    }

    struct Field: Equatable {
        let label: String
        let isSecure: Bool
        let isCode: Bool
    }

    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var style: Style = .standard
    // Text the user types in, one per field, for a question the SSH server asks during sign-in.
    var fields: [Field] = []
}

/// The questions one connect attempt has to ask, shown by the screen that owns the attempt.
///
/// The queue belongs to the attempt rather than to the app, and it answers every waiter: an attempt
/// that is cancelled, or whose screen goes away, resolves its question instead of leaving the tunnel
/// suspended on a prompt nobody can see.
@MainActor
@Observable
final class ConnectionPromptQueue: ConnectionPrompter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionPrompt")

    private(set) var pending: [ConnectionPrompt] = []

    /// Bumped whenever the attempt is abandoned, so work already in flight cannot post a notice onto
    /// the queue the next attempt will use.
    private(set) var generation = 0

    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var typedValues: [UUID: [String]] = [:]

    var current: ConnectionPrompt? { pending.first }

    nonisolated init() {}

    func confirm(_ question: ConnectionQuestion) async -> Bool {
        await ask(Self.prompt(for: question))
    }

    nonisolated var answersChallenges: Bool { true }

    func answer(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        let prompt = Self.prompt(for: challenge)
        guard await ask(prompt) else { return nil }
        return typedValues.removeValue(forKey: prompt.id) ?? Array(repeating: "", count: prompt.fields.count)
    }

    func ask(_ prompt: ConnectionPrompt) async -> Bool {
        guard prompt.style != .notice else {
            Self.logger.error("A notice cannot be asked as a question")
            return false
        }
        guard !Task.isCancelled else { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pending.append(prompt)
                waiters[prompt.id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answer(prompt.id, accepted: false)
            }
        }
    }

    /// A statement rather than a question: nothing waits on it, and it is dropped when the attempt
    /// that produced it has already been abandoned.
    func notify(_ prompt: ConnectionPrompt, generation: Int) {
        guard generation == self.generation else {
            Self.logger.info("Dropped a notice from an attempt that was abandoned")
            return
        }
        pending.append(prompt)
    }

    func answer(_ id: UUID, accepted: Bool, typed values: [String] = []) {
        if accepted, !values.isEmpty { typedValues[id] = values }
        pending.removeAll { $0.id == id }
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        Self.logger.info("Connection prompt answered: \(accepted, privacy: .public)")
        waiter.resume(returning: accepted)
    }

    func cancelAll() {
        generation += 1
        pending.removeAll()
        typedValues.removeAll()
        let abandoned = waiters
        waiters.removeAll()
        for (_, waiter) in abandoned { waiter.resume(returning: false) }
    }

    private static func prompt(for question: ConnectionQuestion) -> ConnectionPrompt {
        switch question {
        case let .unknownHostKey(host, port, keyType, fingerprint):
            ConnectionPrompt(
                title: String(localized: "Unknown SSH Server"),
                message: String(
                    format: String(localized: """
                        TablePro has not connected to %@ before.

                        %@ key fingerprint:
                        %@

                        Trust this server only if the fingerprint matches the one you expect.
                        """),
                    hostDisplay(host, port),
                    keyType,
                    fingerprint
                ),
                confirmTitle: String(localized: "Trust")
            )
        case let .changedHostKey(host, port, previous, current):
            ConnectionPrompt(
                title: String(localized: "SSH Host Key Changed"),
                message: String(
                    format: String(localized: """
                        The host key for %@ has changed.

                        This can mean the server was rebuilt, or that someone is intercepting \
                        the connection.

                        Previous fingerprint:
                        %@

                        Current fingerprint:
                        %@
                        """),
                    hostDisplay(host, port),
                    previous,
                    current
                ),
                confirmTitle: String(localized: "Connect Anyway"),
                style: .destructive
            )
        }
    }

    private static func prompt(for challenge: KeyboardInteractiveChallenge) -> ConnectionPrompt {
        let name = challenge.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = challenge.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionPrompt(
            title: name.isEmpty ? String(localized: "SSH Sign-In") : name,
            message: instruction.isEmpty ? String(localized: "The SSH server asks for more to finish signing in.") : instruction,
            confirmTitle: String(localized: "Sign In"),
            fields: challenge.prompts.map { prompt in
                ConnectionPrompt.Field(
                    label: prompt.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isSecure: prompt.isSecure,
                    isCode: KeyboardInteractivePromptKind(promptText: prompt.text) == .totp
                )
            }
        )
    }

    private static func hostDisplay(_ host: String, _ port: Int) -> String {
        "[\(host)]:\(port)"
    }
}
