//
//  MongoScriptPreludeTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import Testing

/// Drives the real prelude in a real `JSContext` against a recording host.
///
/// This is where the reported bug is pinned: `db.dt_DispatchRule.find()` worked and
/// `db.dt_DispatchRule.find({status: 1})` did not, because the condition was a JavaScript object
/// literal and the old path handed its text straight to libbson's strict JSON parser.
@Suite("MongoScriptPrelude")
struct MongoScriptPreludeTests {
    /// A stand-in for the driver: records every request and answers from a script of replies.
    final class RecordingHost {
        private(set) var requests: [[String: Any]] = []
        private(set) var printed: [String] = []
        var replies: [String] = []
        var database = "shop"

        func handle(_ requestJson: String) -> String {
            guard let data = requestJson.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "{\"ok\":false,\"e\":{\"m\":\"bad request\",\"c\":0}}"
            }
            requests.append(request)

            switch request["op"] as? String {
            case "currentDatabase":
                return "{\"ok\":true,\"v\":\"\(database)\"}"
            case "newObjectId":
                return "{\"ok\":true,\"v\":\"507f1f77bcf86cd799439011\"}"
            // Bookkeeping calls answer without drawing on the scripted replies, so a `.limit(1)`
            // between opening a cursor and reading it does not shift what the read gets back.
            case "cursorConfigure", "cursorClose", "useDatabase", "sleep":
                return "{\"ok\":true,\"v\":null}"
            default:
                let reply = replies.isEmpty ? "null" : replies.removeFirst()
                return "{\"ok\":true,\"v\":\(reply)}"
            }
        }

        func record(printed line: String) {
            printed.append(line)
        }

        func requests(op: String) -> [[String: Any]] {
            requests.filter { ($0["op"] as? String) == op }
        }
    }

    private func makeContext(_ host: RecordingHost) throws -> JSContext {
        let context = try #require(JSContext())
        let execute: @convention(block) (String) -> String = { host.handle($0) }
        let emit: @convention(block) (String) -> Void = { host.record(printed: $0) }
        context.setObject(execute, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(emit, forKeyedSubscript: "__tp_print" as NSString)
        context.evaluateScript(MongoScriptPrelude.source)
        let failure = context.exception?.toString()
        #expect(failure == nil)
        return context
    }

    @Test("The prelude loads without a syntax error")
    func preludeLoads() throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        #expect(context.objectForKeyedSubscript("db")?.isUndefined == false)
    }

    @Test("A find with an unquoted condition reaches the driver as valid Extended JSON")
    func findWithCondition() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("db.dt_DispatchRule.find({status: 1})")
        #expect(context.exception == nil)

        let opened = try #require(host.requests(op: "openCursor").first)
        #expect(opened["collection"] as? String == "dt_DispatchRule")
        let filter = try #require(opened["filter"] as? String)
        #expect(filter == "{\"status\":{\"$numberInt\":\"1\"}}")

        let parsed = try JSONSerialization.jsonObject(with: #require(filter.data(using: .utf8)))
        #expect(parsed is [String: Any])
    }

    @Test("Operators, regular expressions and nested documents survive the crossing")
    func richFilter() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("""
            db.orders.find({ total: {$gt: 10.5}, name: /ab.c/i, tags: ["a", "b"], meta: {seen: true} })
            """)
        #expect(context.exception == nil)

        let filter = try #require(host.requests(op: "openCursor").first?["filter"] as? String)
        #expect(filter.contains("\"$gt\":{\"$numberDouble\":\"10.5\"}"))
        #expect(filter.contains("\"$regularExpression\":{\"pattern\":\"ab.c\",\"options\":\"i\"}"))
        #expect(filter.contains("\"tags\":[\"a\",\"b\"]"))
        #expect(filter.contains("\"meta\":{\"seen\":true}"))
    }

    @Test("Single quotes, which libbson rejects outright, are accepted")
    func singleQuotedValues() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("db.orders.find({status: 'new'})")
        #expect(context.exception == nil)

        let filter = try #require(host.requests(op: "openCursor").first?["filter"] as? String)
        #expect(filter == "{\"status\":\"new\"}")
    }

    @Test("Value constructors serialise to their Extended JSON wrappers")
    func valueConstructors() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("""
            db.orders.find({
                _id: ObjectId("507f1f77bcf86cd799439011"),
                at: ISODate("2020-01-02T03:04:05Z"),
                big: NumberLong("9007199254740993"),
                small: NumberInt(7),
                exact: NumberDecimal("1.25"),
                low: MinKey,
                high: MaxKey
            })
            """)
        #expect(context.exception == nil)

        let filter = try #require(host.requests(op: "openCursor").first?["filter"] as? String)
        #expect(filter.contains("\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"}"))
        #expect(filter.contains("\"at\":{\"$date\":{\"$numberLong\":\"1577934245000\"}}"))
        #expect(filter.contains("\"big\":{\"$numberLong\":\"9007199254740993\"}"))
        #expect(filter.contains("\"small\":{\"$numberInt\":\"7\"}"))
        #expect(filter.contains("\"exact\":{\"$numberDecimal\":\"1.25\"}"))
        #expect(filter.contains("\"low\":{\"$minKey\":1}"))
        #expect(filter.contains("\"high\":{\"$maxKey\":1}"))
    }

    @Test("A bare Date(value) is the date it names, not today as a string")
    func bareDateKeepsWorking() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("db.orders.find({at: Date(\"2020-01-02T03:04:05Z\")})")
        #expect(context.exception == nil)

        let filter = try #require(host.requests(op: "openCursor").first?["filter"] as? String)
        #expect(filter == "{\"at\":{\"$date\":{\"$numberLong\":\"1577934245000\"}}}")
    }

    @Test("new Date and instanceof still reach the native Date")
    func nativeDateIsIntact() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        let value = context.evaluateScript(
            "(new Date(0) instanceof Date) + \",\" + (Date(0) instanceof Date) + \",\" + new Date(0).getTime()"
        )
        #expect(context.exception == nil)
        #expect(value?.toString() == "true,true,0")
    }

    @Test("A number constructor refuses what it cannot represent")
    func numberConstructorsValidate() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        for statement in ["NumberLong(\"abc\")", "NumberInt(\"abc\")", "NumberDecimal(\"abc\")"] {
            context.exception = nil
            context.evaluateScript(statement)
            #expect(context.exception != nil, "\(statement) should have thrown")
        }
    }

    @Test("Chained cursor modifiers reach the driver instead of being dropped")
    func chainedModifiers() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("db.orders.find({}).sort({createdAt: -1}).skip(20).limit(10)")
        #expect(context.exception == nil)

        var applied: [String: String] = [:]
        for request in host.requests(op: "cursorConfigure") {
            guard let key = request["key"] as? String, let value = request["value"] as? String else { continue }
            applied[key] = value
        }
        #expect(applied["sort"] == "{\"createdAt\":{\"$numberInt\":\"-1\"}}")
        #expect(applied["skip"] == "{\"$numberInt\":\"20\"}")
        #expect(applied["limit"] == "{\"$numberInt\":\"10\"}")
    }

    @Test("forEach walks the cursor and print collects the lines")
    func cursorIterationAndPrinting() throws {
        let host = RecordingHost()
        host.replies = [
            "1",
            """
            {"docs": [{"_id": {"$oid": "507f1f77bcf86cd799439011"}, "name": "first"}, \
            {"_id": {"$oid": "507f1f77bcf86cd799439012"}, "name": "second"}], "done": true}
            """
        ]
        let context = try makeContext(host)

        context.evaluateScript("db.orders.find({}).forEach(function (order) { print(order.name); })")
        #expect(context.exception == nil)
        #expect(host.printed == ["first", "second"])
    }

    @Test("A document read back carries an ObjectId, not a wrapper object")
    func documentsRevive() throws {
        let host = RecordingHost()
        host.replies = [
            "1",
            "{\"docs\": [{\"_id\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}], \"done\": true}"
        ]
        let context = try makeContext(host)

        let value = context.evaluateScript("db.orders.findOne({})._id.toString()")
        #expect(context.exception == nil)
        #expect(value?.toString() == "507f1f77bcf86cd799439011")
    }

    @Test("Variables and functions survive from one evaluated statement to the next")
    func shellStateSurvives() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("var total = 0; function add(n) { total += n; }")
        context.evaluateScript("add(4); add(6);")
        let value = context.evaluateScript("total")
        #expect(context.exception == nil)
        #expect(value?.toInt32() == 10)
    }

    @Test("An update reports the counts mongosh reports")
    func updateResultShape() throws {
        let host = RecordingHost()
        host.replies = ["{\"n\": 3, \"nModified\": 2}"]
        let context = try makeContext(host)

        let value = context.evaluateScript(
            "var r = db.orders.updateMany({a: 1}, {$set: {b: 2}}); r.matchedCount + \"/\" + r.modifiedCount"
        )
        #expect(context.exception == nil)
        #expect(value?.toString() == "3/2")

        let request = try #require(host.requests(op: "update").first)
        #expect(request["multi"] as? Bool == true)
        #expect(request["update"] as? String == "{\"$set\":{\"b\":{\"$numberInt\":\"2\"}}}")
    }

    @Test("An insert keeps the document's field order")
    func insertPreservesFieldOrder() throws {
        let host = RecordingHost()
        host.replies = ["{\"insertedIds\": [{\"$oid\": \"507f1f77bcf86cd799439011\"}], \"insertedCount\": 1}"]
        let context = try makeContext(host)

        context.evaluateScript("db.orders.insertOne({zeta: 1, alpha: 2, middle: 3})")
        #expect(context.exception == nil)

        let document = try #require(host.requests(op: "insertOne").first?["document"] as? String)
        #expect(document == "{\"zeta\":{\"$numberInt\":\"1\"},\"alpha\":{\"$numberInt\":\"2\"},\"middle\":{\"$numberInt\":\"3\"}}")
    }

    @Test("A cursor cannot be re-sorted once it has started")
    func modifiersLockAfterStart() throws {
        let host = RecordingHost()
        host.replies = ["1", "{\"docs\": [], \"done\": true}"]
        let context = try makeContext(host)

        context.evaluateScript("var c = db.orders.find({}); c.hasNext(); c.sort({a: 1});")
        #expect(context.exception != nil)
    }

    @Test("A driver error surfaces as a JavaScript error carrying its code")
    func driverErrorsPropagate() throws {
        final class FailingHost {
            func handle(_ requestJson: String) -> String {
                requestJson.contains("currentDatabase")
                    ? "{\"ok\":true,\"v\":\"shop\"}"
                    : "{\"ok\":false,\"e\":{\"m\":\"ns not found\",\"c\":26}}"
            }
        }
        let failing = FailingHost()
        let context = try #require(JSContext())
        let execute: @convention(block) (String) -> String = { failing.handle($0) }
        let emit: @convention(block) (String) -> Void = { _ in }
        context.setObject(execute, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(emit, forKeyedSubscript: "__tp_print" as NSString)
        context.evaluateScript(MongoScriptPrelude.source)

        let value = context.evaluateScript("""
            (function () {
                try { db.missing.find({}).hasNext(); } catch (e) { return e.message + "/" + e.code; }
                return "no error";
            })()
            """)
        #expect(value?.toString() == "ns not found/26")
    }

    @Test("use switches the database the shell writes to")
    func useSwitchesDatabase() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("use(\"reporting\"); db.orders.find({});")
        #expect(context.exception == nil)

        let switched = try #require(host.requests(op: "useDatabase").first)
        #expect(switched["db"] as? String == "reporting")
        #expect(host.requests(op: "openCursor").first?["db"] as? String == "reporting")
    }

    @Test("EJSON.parse reads a string, the way mongosh's does")
    func ejsonParseTakesText() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        let value = context.evaluateScript(
            "EJSON.parse('{\"_id\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}')._id.toString()"
        )
        #expect(context.exception == nil)
        #expect(value?.toString() == "507f1f77bcf86cd799439011")
    }

    @Test("A write with no document is refused rather than sent as null")
    func writesNeedADocument() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        for statement in [
            "db.orders.updateOne({a: 1})",
            "db.orders.replaceOne({a: 1})",
            "db.orders.findOneAndUpdate({a: 1})",
            "db.orders.insertOne()"
        ] {
            context.exception = nil
            context.evaluateScript(statement)
            #expect(context.exception != nil, "\(statement) should have thrown")
        }
        #expect(host.requests(op: "update").isEmpty)
        #expect(host.requests(op: "insertOne").isEmpty)
    }

    @Test("An aggregation pipeline crosses as an array of stages")
    func aggregatePipeline() throws {
        let host = RecordingHost()
        let context = try makeContext(host)

        context.evaluateScript("db.orders.aggregate([{$match: {status: 'new'}}, {$count: 'n'}])")
        #expect(context.exception == nil)

        let request = try #require(host.requests(op: "openCursor").first)
        #expect(request["kind"] as? String == "aggregate")
        #expect(request["pipeline"] as? String == "[{\"$match\":{\"status\":\"new\"}},{\"$count\":\"n\"}]")
    }
}
