//
//  MongoShellValueTests.swift
//  TableProTests
//
//  Expected values were measured against mongosh 2.10.0 on MongoDB 7.0.43. Where the shell refuses
//  what mongosh wraps, clamps or zeroes, the test says so.
//

import Foundation
import JavaScriptCore
import Testing

/// Drives the real prelude's number rules and value constructors.
///
/// A whole number past int64 went out as `$numberLong` in its shortest spelling, such as
/// `"9223372036854776000"`, which libbson refuses, so `insertOne({n: 1e20})` failed as a document
/// MongoDB could not read. `Int32`, `Long`, `Decimal128` and `BSONRegExp` were offered by
/// autocomplete and undefined, and a stored `NaN` decimal or an `x` regular expression stopped
/// `forEach` partway through.
struct MongoShellValueTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    private func makeContext(_ host: RecordingHost = RecordingHost()) throws -> JSContext {
        try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })
    }

    private func extendedJson(of expression: String, in context: JSContext) -> String? {
        context.exception = nil
        let value = context.evaluateScript("EJSON.stringify(\(expression))")
        return context.exception == nil ? value?.toString() : nil
    }

    private func refusal(of statement: String, in context: JSContext) -> String? {
        context.exception = nil
        context.evaluateScript(statement)
        let message = context.exception?.objectForKeyedSubscript("message")?.toString()
        context.exception = nil
        return message
    }

    @Test("A whole number past 2^53 is sent as the double it is, never as a different int64")
    func wholeNumbersPastTheExactRangeAreDoubles() throws {
        let host = RecordingHost()
        host.replies = [#"{"insertedIds": [1], "insertedCount": 1}"#]
        let context = try makeContext(host)

        context.evaluateScript("""
            db.n.insertOne({a: 1e20, b: 9223372036854775807, c: -9223372036854775808, d: 1e21, e: -0, \
            f: 2147483648, g: 9007199254740993, h: 9007199254740991, i: -2147483648, j: 5})
            """)
        #expect(context.exception == nil)

        let document = try #require(host.requests(op: "insertOne").first?["document"] as? String)
        #expect(document == """
            {"a":{"$numberDouble":"100000000000000000000"},"b":{"$numberDouble":"9223372036854776000"},\
            "c":{"$numberDouble":"-9223372036854776000"},"d":{"$numberDouble":"1e+21"},\
            "e":{"$numberDouble":"-0.0"},"f":{"$numberLong":"2147483648"},\
            "g":{"$numberDouble":"9007199254740992"},"h":{"$numberLong":"9007199254740991"},\
            "i":{"$numberInt":"-2147483648"},"j":{"$numberInt":"5"}}
            """)
        #expect(Double("9223372036854776000") == 0x1p63)
        #expect(Double("-9223372036854776000") == -0x1p63)
        #expect(Double("9007199254740992") == 0x1p53)
    }

    @Test("A Long holds exactly the integer it was given")
    func longKeepsTheExactInteger() throws {
        let context = try makeContext()
        let expected: [(statement: String, digits: String)] = [
            ("NumberLong(2 ** 62)", "4611686018427387904"),
            ("Long(2 ** 62)", "4611686018427387904"),
            ("NumberLong(9007199254740993)", "9007199254740992"),
            ("NumberLong(-(2 ** 63))", "-9223372036854775808"),
            (#"Long("9223372036854775807")"#, "9223372036854775807"),
            (#"NumberLong(" 5")"#, "5"),
            (#"Long("+007")"#, "7"),
            ("NumberLong(5.9)", "5"),
            ("Long(-5.9)", "-5"),
            ("Long(5, 1)", "4294967301"),
            ("Long(-1, -1)", "-1"),
            ("NumberLong(NumberInt(3))", "3"),
            (#"Long(NumberLong("9007199254740993"))"#, "9007199254740993"),
            ("NumberLong()", "0")
        ]
        for (statement, digits) in expected {
            #expect(
                extendedJson(of: statement, in: context) == #"{"$numberLong":"\#(digits)"}"#,
                "\(statement)"
            )
        }
    }

    @Test("Int32, Decimal128, Timestamp, BSONRegExp and MinKey build the values mongosh builds")
    func constructorsMatchMongosh() throws {
        let context = try makeContext()
        let expected: [(statement: String, json: String)] = [
            ("Int32(5)", #"{"$numberInt":"5"}"#),
            (#"new Int32("7")"#, #"{"$numberInt":"7"}"#),
            ("NumberInt(5.9)", #"{"$numberInt":"5"}"#),
            ("NumberInt(0.0000005)", #"{"$numberInt":"0"}"#),
            (#"NumberInt(" 5 ")"#, #"{"$numberInt":"5"}"#),
            (#"Decimal128("1.50")"#, #"{"$numberDecimal":"1.50"}"#),
            (#"NumberDecimal("NaN")"#, #"{"$numberDecimal":"NaN"}"#),
            (#"Decimal128("-inf")"#, #"{"$numberDecimal":"-Infinity"}"#),
            ("NumberDecimal(1.5)", #"{"$numberDecimal":"1.5"}"#),
            ("Timestamp(1, 2)", #"{"$timestamp":{"t":1,"i":2}}"#),
            ("Timestamp({t: 3, i: 4})", #"{"$timestamp":{"t":3,"i":4}}"#),
            (#"Timestamp(NumberLong("8589934593"))"#, #"{"$timestamp":{"t":2,"i":1}}"#),
            ("Timestamp(1.5, 2.7)", #"{"$timestamp":{"t":1,"i":2}}"#),
            ("Timestamp(1)", #"{"$timestamp":{"t":1,"i":0}}"#),
            ("Timestamp()", #"{"$timestamp":{"t":0,"i":0}}"#),
            (#"BSONRegExp("a", "mi")"#, #"{"$regularExpression":{"pattern":"a","options":"im"}}"#),
            ("MinKey()", #"{"$minKey":1}"#),
            ("new MinKey()", #"{"$minKey":1}"#)
        ]
        for (statement, json) in expected {
            #expect(extendedJson(of: statement, in: context) == json, "\(statement)")
        }
    }

    @Test("A constructor refuses a value it cannot hold instead of wrapping, clamping or zeroing it")
    func constructorsRefuseWhatTheyCannotHold() throws {
        let context = try makeContext()
        let int32Range = "takes a whole number from -2147483648 to 2147483647"
        let int64Range = "takes a whole number from -9223372036854775808 to 9223372036854775807"
        let notTimestamp = "Timestamp takes (t, i), { t, i }, a Long or a bigint"
        let expected: [(statement: String, message: String)] = [
            ("Int32(2147483648)", "Int32 \(int32Range)"),
            (#"NumberInt("12abc")"#, "NumberInt takes a number"),
            ("NumberInt(NaN)", "NumberInt takes a number"),
            (#"Long("9223372036854775808")"#, "Long \(int64Range)"),
            ("NumberLong(1e20)", "NumberLong \(int64Range)"),
            ("NumberLong(9223372036854775807)", "NumberLong \(int64Range)"),
            (#"NumberLong("1e3")"#, "NumberLong takes a whole number"),
            ("Long(5.5, 1)", "Long takes its low and high halves as whole numbers from -2147483648 to 4294967295"),
            (#"Decimal128("abc")"#, "Decimal128 takes a number"),
            ("Timestamp(4294967296, 0)", "Timestamp takes t from 0 to 4294967295"),
            ("Timestamp(-1, 0)", "Timestamp takes t from 0 to 4294967295"),
            (#"Timestamp("5", "6")"#, "Timestamp takes t as a number"),
            ("Timestamp(NumberInt(5), NumberInt(6))", "Timestamp takes t as a number"),
            ("Timestamp(Double(5), 1)", "Timestamp takes t as a number"),
            ("Timestamp(new Date(1700000000000), 1)", "Timestamp takes t as a number"),
            ("Timestamp({})", "Timestamp takes t as a number"),
            ("Timestamp({t: 1})", "Timestamp takes i as a number"),
            ("Timestamp([1, 2])", notTimestamp),
            ("Timestamp(null)", notTimestamp),
            (#"BSONRegExp("a", "g")"#, "BSONRegExp takes options from i, l, m, s, u and x"),
            ("BSONRegExp(/a/)", "BSONRegExp takes its pattern as a string"),
            (#"BSONRegExp("a\u0000")"#, "A BSONRegExp pattern cannot hold a null character")
        ]
        for (statement, message) in expected {
            #expect(refusal(of: statement, in: context) == message, "\(statement)")
        }
    }

    @Test("A legacy name and its type are one type, whichever built the value")
    func aliasesShareOneType() throws {
        let context = try makeContext()

        let shared = context.evaluateScript("""
            [NumberInt(5) instanceof Int32, Int32(5) instanceof NumberInt,
             NumberLong(5) instanceof Long, Long(5) instanceof NumberLong,
             NumberDecimal("1") instanceof Decimal128, Decimal128("1") instanceof NumberDecimal,
             NumberLong(5).constructor === Long, NumberInt(5).constructor === Int32].join()
            """)
        #expect(context.exception == nil)
        #expect(shared?.toString() == "true,true,true,true,true,true,true,true")
    }

    @Test("A document read and written back keeps what JavaScript can hold, and reads through the rest")
    func readBackRoundTrip() throws {
        let host = RecordingHost()
        host.replies = [
            "1",
            """
            {"docs": [{"_id": {"$numberInt": "1"}, "d": {"$numberDouble": "5.0"}, \
            "wide": {"$numberDouble": "3000000000.0"}, "neg": {"$numberDouble": "-0.0"}, \
            "big": {"$numberDouble": "1e+20"}, "nan": {"$numberDouble": "NaN"}, \
            "l": {"$numberLong": "9007199254740993"}, "dec": {"$numberDecimal": "NaN"}, \
            "x": {"$regularExpression": {"pattern": "a b", "options": "x"}}, \
            "pcre": {"$regularExpression": {"pattern": "(?i)a", "options": ""}}, \
            "slash": {"$regularExpression": {"pattern": "a/b", "options": "i"}}, \
            "empty": {"$regularExpression": {"pattern": "", "options": ""}}, \
            "ts": {"$timestamp": {"t": 4294967295, "i": 1}}}], "done": true}
            """,
            #"{"n": 1, "nModified": 1}"#
        ]
        let context = try makeContext(host)

        context.evaluateScript("db.t.find().forEach(function (doc) { db.t.replaceOne({_id: doc._id}, doc); })")
        #expect(context.exception == nil)

        let replacement = try #require(host.requests(op: "replace").first?["update"] as? String)
        #expect(replacement == """
            {"_id":{"$numberInt":"1"},"d":{"$numberInt":"5"},"wide":{"$numberLong":"3000000000"},\
            "neg":{"$numberDouble":"-0.0"},"big":{"$numberDouble":"100000000000000000000"},\
            "nan":{"$numberDouble":"NaN"},"l":{"$numberLong":"9007199254740993"},\
            "dec":{"$numberDecimal":"NaN"},\
            "x":{"$regularExpression":{"pattern":"a b","options":"x"}},\
            "pcre":{"$regularExpression":{"pattern":"(?i)a","options":""}},\
            "slash":{"$regularExpression":{"pattern":"a/b","options":"i"}},\
            "empty":{"$regularExpression":{"pattern":"","options":""}},\
            "ts":{"$timestamp":{"t":4294967295,"i":1}}}
            """)
    }

    @Test("A value read back compares the way it does in mongosh")
    func readBackComparisons() throws {
        let host = RecordingHost()
        host.replies = [
            "1",
            """
            {"docs": [{"d": {"$numberDouble": "5.0"}, "neg": {"$numberDouble": "-0.0"}, \
            "i": {"$numberInt": "7"}, "l": {"$numberLong": "5"}, "dec": {"$numberDecimal": "1.50"}, \
            "slash": {"$regularExpression": {"pattern": "a/b", "options": "i"}}, \
            "x": {"$regularExpression": {"pattern": "a b", "options": "x"}}}], "done": true}
            """
        ]
        let context = try makeContext(host)

        let seen = context.evaluateScript("""
            var doc = db.t.findOne();
            [doc.d === 5, typeof doc.d, Object.is(doc.neg, -0), doc.i === 7,
             doc.l === 5, doc.l == 5, doc.l instanceof Long, String(doc.dec),
             doc.slash instanceof RegExp, doc.slash.test("A/B"), doc.x instanceof BSONRegExp, doc.x.options].join()
            """)
        #expect(context.exception == nil)
        #expect(seen?.toString() == "true,number,true,true,false,true,true,1.50,true,true,true,x")
    }
}
