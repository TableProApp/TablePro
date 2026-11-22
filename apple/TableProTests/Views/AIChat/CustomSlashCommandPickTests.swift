import Foundation
@testable import TablePro
import Testing

struct CustomSlashCommandPickTests {
    private let summarize = CustomSlashCommand(name: "summarize", promptTemplate: "Summarize {{body}} using {{schema}}")

    @Test("A template without {{body}} runs at once")
    func runsWithoutBody() {
        let audit = CustomSlashCommand(name: "audit", promptTemplate: "Audit {{query}} on {{database}}")
        #expect(CustomSlashCommandPick.resolve(audit, draft: "") == .run)
        #expect(CustomSlashCommandPick.resolve(audit, draft: "some text") == .run)
    }

    @Test("A template with {{body}} waits in an empty composer")
    func composesIntoEmptyDraft() {
        #expect(CustomSlashCommandPick.resolve(summarize, draft: "") == .compose("/summarize "))
        #expect(CustomSlashCommandPick.resolve(summarize, draft: "  \n") == .compose("/summarize "))
    }

    @Test("Text already typed becomes the body")
    func keepsDraftAsBody() {
        #expect(
            CustomSlashCommandPick.resolve(summarize, draft: " orders by month\n")
                == .compose("/summarize orders by month")
        )
    }

    @Test("Picking the command already typed keeps its body once")
    func sameCommandKeepsBody() {
        #expect(
            CustomSlashCommandPick.resolve(summarize, draft: "/Summarize last week")
                == .compose("/summarize last week")
        )
        #expect(CustomSlashCommandPick.resolve(summarize, draft: "/summarize") == .compose("/summarize "))
    }

    @Test("A body typed after the composed command is what Send passes to the template")
    func composedTextParsesBack() throws {
        guard case .compose(let text) = CustomSlashCommandPick.resolve(summarize, draft: "") else {
            Issue.record("expected the command to wait in the composer")
            return
        }
        let invocation = try #require(SlashCommand.invocation(in: text + "orders by month"))
        #expect(invocation.name == "summarize")
        #expect(invocation.body == "orders by month")
    }
}
