//
//  MongoScriptPreludeMemberTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import Testing

@testable import TablePro

/// What the shell sends for members and values that JavaScript itself treats specially: a member
/// named `__proto__`, which an assignment turns into the object's prototype, and the BSON types a
/// canonical wrapper used to stand in for.
struct MongoScriptPreludeMemberTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    private func run(_ script: String, replies: [String] = []) throws -> (RecordingHost, JSContext) {
        let host = RecordingHost()
        host.replies = replies
        let context = try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })
        context.evaluateScript(script)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return (host, context)
    }

    private func commands(_ host: RecordingHost) -> [String] {
        host.requests(op: "command").compactMap { $0["command"] as? String }
    }

    @Test("A member named __proto__ is sent as a member, at any depth")
    func protoMembersAreSent() throws {
        let (host, _) = try run("""
            db.runCommand({ insert: "c", documents: [{ ["__proto__"]: 1, a: { ["__proto__"]: { b: 2 } } }] })
            """)

        #expect(commands(host) == [
            #"{"insert":"c","documents":[{"__proto__":{"$numberInt":"1"},"a":{"__proto__":{"b":{"$numberInt":"2"}}}}]}"#
        ])
    }

    @Test("A member named __proto__ read from the server stays a member, and is sent back as one")
    func protoMembersSurviveAReadAndAWrite() throws {
        let reply = #"{"cursor":{"firstBatch":[{"__proto__":{"$numberInt":"7"},"k":"v"}]}}"#
        let (host, context) = try run("""
            var found = db.runCommand({ find: "c" }).cursor.firstBatch[0];
            db.runCommand({ insert: "c", documents: [found] });
            """, replies: [reply, "{}"])

        #expect(context.evaluateScript("Object.keys(found).join()")?.toString() == "__proto__,k")
        #expect(context.evaluateScript("found.__proto__ === 7")?.toBool() == true)
        #expect(commands(host).last == #"{"insert":"c","documents":[{"__proto__":{"$numberInt":"7"},"k":"v"}]}"#)
    }

    @Test("createCollection and createView pass an option named __proto__ on as a member")
    func protoOptionsAreSent() throws {
        let (host, _) = try run("""
            db.createCollection("c", { ["__proto__"]: 1 });
            db.createView("v", "c", [], { ["__proto__"]: 2 });
            """, replies: ["{}", "{}"])

        #expect(commands(host) == [
            #"{"create":"c","__proto__":{"$numberInt":"1"}}"#,
            #"{"create":"v","viewOn":"c","pipeline":[],"__proto__":{"$numberInt":"2"}}"#
        ])
    }

    @Test("BSONRegExp, BSONSymbol and a NaN or infinite NumberDecimal send the BSON types they name")
    func constructorsSendTheirTypes() throws {
        let (host, _) = try run("""
            db.runCommand({ r: BSONRegExp("(?i)a\\\\/b", "xi"), s: BSONSymbol("q"), n: NumberDecimal("NaN"),
                p: NumberDecimal("Infinity"), m: NumberDecimal("-Infinity"), d: new Date(-62198755200000) })
            """)

        #expect(commands(host) == [
            #"{"r":{"$regularExpression":{"pattern":"(?i)a\\/b","options":"ix"}},"s":{"$symbol":"q"},"#
                + #""n":{"$numberDecimal":"NaN"},"p":{"$numberDecimal":"Infinity"},"#
                + #""m":{"$numberDecimal":"-Infinity"},"d":{"$date":{"$numberLong":"-62198755200000"}}}"#
        ])
    }

    @Test("BSONRegExp refuses options BSON has no flag for, and NumberDecimal still refuses a word")
    func constructorsRefuseWhatBsonCannotHold() throws {
        let host = RecordingHost()
        let context = try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })

        context.evaluateScript("BSONRegExp(\"a\", \"g\")")
        #expect(context.exception?.toString() == "Error: BSONRegExp takes options from i, l, m, s, u and x")
        context.exception = nil
        context.evaluateScript("NumberDecimal(\"abc\")")
        #expect(context.exception?.toString() == "Error: NumberDecimal takes a number")
    }
}
