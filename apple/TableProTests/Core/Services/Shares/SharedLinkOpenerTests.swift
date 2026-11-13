//
//  SharedLinkOpenerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct SharedLinkOpenerTests {
    private static let token = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7cDe0fGh3"

    @MainActor
    private final class Recorder {
        var prompts: [SharedLinkOpener.PasswordPrompt] = []
        var answers: [String?] = []
        var opened: [SharedQueryOpen] = []
        var messages: [String] = []
        var events: [String] = []
        var cancel: (@MainActor () -> Void)?
    }

    private func makeOpener(_ service: FakeShareService, _ recorder: Recorder) -> SharedLinkOpener {
        SharedLinkOpener(
            service: { service },
            presentation: SharedLinkOpener.Presentation(
                askPassword: { prompt in
                    recorder.prompts.append(prompt)
                    return recorder.answers.isEmpty ? nil : recorder.answers.removeFirst()
                },
                openQuery: { recorder.opened.append($0); recorder.events.append("open") },
                tell: { recorder.messages.append($0); recorder.events.append("tell") },
                showProgress: { cancel in recorder.cancel = cancel; recorder.events.append("progress") },
                hideProgress: { recorder.events.append("hide") },
                fallBack: { recorder.events.append("welcome") }
            )
        )
    }

    @Test("A shared query opens its SQL in a new tab named after the share, after the progress closes")
    func opensSQL() async {
        let service = FakeShareService()
        service.fetchResults = [.success(SharedQuery(kind: .query, title: "Top users", sql: "SELECT 1"))]
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: Self.token)

        #expect(recorder.opened == [SharedQueryOpen(sql: "SELECT 1", title: "Top users")])
        #expect(recorder.events == ["progress", "hide", "open"])
        #expect(service.fetchedPasswords == [nil])
    }

    @Test("An untitled share opens under the editor's own tab name")
    func untitledShare() async {
        let service = FakeShareService()
        service.fetchResults = [.success(SharedQuery(kind: .query, title: "  ", sql: "SELECT 1"))]
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: Self.token)
        #expect(recorder.opened == [SharedQueryOpen(sql: "SELECT 1", title: nil)])
    }

    @Test("A password-protected share asks for the password and retries a wrong one")
    func passwordFlow() async {
        let service = FakeShareService()
        service.fetchResults = [
            .failure(.passwordRequired),
            .failure(.passwordWrong),
            .success(SharedQuery(kind: .result, title: "Report", sql: "SELECT 2"))
        ]
        let recorder = Recorder()
        recorder.answers = ["wrong", "right"]
        await makeOpener(service, recorder).open(token: Self.token)

        #expect(recorder.prompts == [.required, .wrong])
        #expect(service.fetchedPasswords == [nil, "wrong", "right"])
        #expect(recorder.opened.map(\.sql) == ["SELECT 2"])
    }

    @Test("Cancelling the password prompt opens nothing, says nothing and falls back to Welcome")
    func cancelledPassword() async {
        let service = FakeShareService()
        service.fetchResults = [.failure(.passwordRequired)]
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: Self.token)

        #expect(recorder.opened.isEmpty)
        #expect(recorder.messages.isEmpty)
        #expect(recorder.events == ["progress", "hide", "welcome"])
    }

    @Test("A result share with hidden or no SQL has nothing to open", arguments: [nil, "", " \n"] as [String?])
    func hiddenSQL(sql: String?) async {
        let service = FakeShareService()
        service.fetchResults = [.success(SharedQuery(kind: .result, title: "Report", sql: sql))]
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: Self.token)

        #expect(recorder.opened.isEmpty)
        #expect(recorder.messages == [String(localized: "This shared result hides its SQL, so there is nothing to open.")])
    }

    @Test("A link that no longer resolves says so, then falls back to Welcome")
    func gone() async {
        let service = FakeShareService()
        service.fetchResults = [.failure(.notFound)]
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: Self.token)
        #expect(recorder.messages == [String(localized: "This shared link is no longer available.")])
        #expect(recorder.events == ["progress", "hide", "tell", "welcome"])
    }

    @Test("Cancel in the progress window stops the read and falls back to Welcome without a message")
    func cancelProgress() async throws {
        let service = FakeShareService()
        let gate = AsyncGate()
        service.fetchGate = gate
        service.fetchResults = [.success(SharedQuery(kind: .query, title: "T", sql: "SELECT 1"))]
        let recorder = Recorder()
        let opener = makeOpener(service, recorder)

        let opening = Task { await opener.open(token: Self.token) }
        await gate.arrived(1)
        let cancel = try #require(recorder.cancel)
        cancel()
        await gate.open()
        await opening.value

        #expect(recorder.opened.isEmpty)
        #expect(recorder.messages.isEmpty)
        #expect(recorder.events.last == "welcome")
    }

    @Test("A malformed token never reaches the server")
    func malformedToken() async {
        let service = FakeShareService()
        let recorder = Recorder()
        await makeOpener(service, recorder).open(token: "nope")
        #expect(service.fetchedPasswords.isEmpty)
        #expect(recorder.events.isEmpty)
    }
}
