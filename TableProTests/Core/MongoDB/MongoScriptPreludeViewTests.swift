//
//  MongoScriptPreludeViewTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import Testing

/// Drives the real prelude, where `db.createView` used to resolve to a collection named
/// `createView` and throw "db.createView is not a function".
struct MongoScriptPreludeViewTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    private func makeContext(_ host: RecordingHost) throws -> JSContext {
        try MongoScriptContext.make(
            execute: { host.handle($0) },
            emit: { host.record(printed: $0) }
        )
    }

    private func command(sentBy statement: String) throws -> String {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript(statement)
        #expect(context.exception == nil)

        let commands = host.requests(op: "command")
        #expect(commands.count == 1)
        return try #require(commands.first?["command"] as? String)
    }

    @Test("createView sends create with viewOn, the pipeline and the options, in that order")
    func createViewSendsCreateWithViewOn() throws {
        let command = try command(
            sentBy: "db.createView(\"adults\", \"people\", [{$match: {}}], {collation: {locale: \"en\"}})"
        )

        #expect(command == """
            {"create":"adults","viewOn":"people","pipeline":[{"$match":{}}],"collation":{"locale":"en"}}
            """)
    }

    @Test("createView without a pipeline sends an empty one")
    func createViewDefaultsToEmptyPipeline() throws {
        #expect(try command(sentBy: "db.createView(\"v\", \"s\")") == "{\"create\":\"v\",\"viewOn\":\"s\",\"pipeline\":[]}")
    }
}
