import Foundation
@testable import TablePro
import Testing

@MainActor
struct PasswordSourceTestModelTests {
    private let context = ConnectionScriptContext(
        connectionId: UUID(), connectionName: "c", host: "h", port: 1, user: "u", database: "d"
    )

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    @Test("A refused test reports why and never runs the source")
    func refusalSkipsTheRun() async {
        let runs = RunCounter()
        let model = PasswordSourceTestModel { _, _ in
            runs.increment()
            return "secret"
        }
        let source = PasswordSource.command(shell: "echo secret")

        await model.run(source, context: context, refusal: PasswordSourceResolver.ResolutionError.storeNotTrusted)

        #expect(runs.value == 0)
        #expect(model.outcome(for: source, context: context) == .failed(
            PasswordSourceResolver.ResolutionError.storeNotTrusted.localizedDescription
        ))
    }

    @Test("A command that prints a password returns it")
    func commandOutputIsReturned() async {
        let model = PasswordSourceTestModel()
        let source = PasswordSource.command(shell: "echo hunter2")

        await model.run(source, context: context, refusal: nil)

        #expect(model.outcome(for: source, context: context) == .returned("hunter2"))
        #expect(!model.isRunning)
    }

    @Test("A command that fails shows its exit code and stderr")
    func failingCommandShowsStderr() async {
        let model = PasswordSourceTestModel()
        let source = PasswordSource.command(shell: "echo 'op: not signed in' >&2; exit 3")

        await model.run(source, context: context, refusal: nil)

        guard case .failed(let message) = model.outcome(for: source, context: context) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("op: not signed in"))
        #expect(message.contains("3"))
    }

    @Test("A result is shown only for the source that produced it")
    func outcomeBelongsToItsSource() async {
        let model = PasswordSourceTestModel { _, _ in "secret" }
        let tested = PasswordSource.env(variable: "A")

        await model.run(tested, context: context, refusal: nil)

        #expect(model.outcome(for: tested, context: context) == .returned("secret"))
        #expect(model.outcome(for: .env(variable: "B"), context: context) == nil)
    }

    @Test("Editing the connection's details hides a result that used the old ones")
    func outcomeBelongsToItsConnectionDetails() async {
        let model = PasswordSourceTestModel { _, context in context.host }
        let source = PasswordSource.command(shell: "echo {host}")
        let moved = ConnectionScriptContext(
            connectionId: context.connectionId, connectionName: "c", host: "other", port: 1, user: "u", database: "d"
        )

        await model.run(source, context: context, refusal: nil)

        #expect(model.outcome(for: source, context: context) == .returned("h"))
        #expect(model.outcome(for: source, context: moved) == nil)
    }

    @Test("A new connection's details match from one render to the next")
    func outcomeIgnoresTheThrowawayId() async {
        let model = PasswordSourceTestModel { _, _ in "secret" }
        let source = PasswordSource.env(variable: "A")
        let rerendered = ConnectionScriptContext(
            connectionId: UUID(), connectionName: "c", host: "h", port: 1, user: "u", database: "d"
        )

        await model.run(source, context: context, refusal: nil)

        #expect(model.outcome(for: source, context: rerendered) == .returned("secret"))
    }

    @Test("The profile editor runs a source the user typed, even from an untrusted profiles file")
    func editorRunsTypedSource() {
        let stored = PasswordSource.command(shell: "echo stored")

        #expect(CredentialProfileEditorSheet.testRefusal(
            for: .command(shell: "echo typed"), storedSource: stored, storeIsTrusted: false
        ) == nil)
        #expect(CredentialProfileEditorSheet.testRefusal(
            for: .command(shell: "echo new"), storedSource: nil, storeIsTrusted: false
        ) == nil)
    }

    @Test("The profile editor refuses a source read back from an untrusted profiles file")
    func editorRefusesUntrustedStoredSource() {
        let stored = PasswordSource.command(shell: "echo stored")

        #expect(CredentialProfileEditorSheet.testRefusal(
            for: stored, storedSource: stored, storeIsTrusted: false
        ) == .profileStoreNotTrusted)
        #expect(CredentialProfileEditorSheet.testRefusal(
            for: stored, storedSource: stored, storeIsTrusted: true
        ) == nil)
    }

    @Test("Whitespace the fields trim away does not count as an edit")
    func editorRefusesAPaddedStoredSource() {
        #expect(CredentialProfileEditorSheet.testRefusal(
            for: .file(path: "/tmp/secret"),
            storedSource: .file(path: " /tmp/secret "),
            storeIsTrusted: false
        ) == .profileStoreNotTrusted)
        #expect(CredentialProfileEditorSheet.testRefusal(
            for: .command(shell: "echo stored"),
            storedSource: .command(shell: "echo stored", reuseSeconds: 300),
            storeIsTrusted: false
        ) == .profileStoreNotTrusted)
    }
}
