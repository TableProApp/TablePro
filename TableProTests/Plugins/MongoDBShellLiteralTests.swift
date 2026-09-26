//
//  MongoDBShellLiteralTests.swift
//  TableProTests
//
//  Inputs are canonical Extended JSON as libmongoc 1.28 renders it, read from MongoDB 7.0.43.
//

import Foundation
import Testing

struct MongoDBShellLiteralTests {
    private func render(_ canonical: String) -> String {
        MongoDBShellLiteral.render(canonical)
    }

    @Test("An Int32 stays a bare number, and an Int64 and a whole Double name their type")
    func numbersKeepTheirType() {
        #expect(render("""
            { "a" : { "$numberInt" : "7" }, "b" : { "$numberLong" : "9007199254740993" }, \
            "c" : { "$numberLong" : "1" }, "d" : { "$numberDouble" : "1.0" }, "e" : { "$numberDouble" : "-0.0" }, \
            "f" : { "$numberDouble" : "1e+20" }, "g" : { "$numberInt" : "-2147483648" } }
            """) == """
            { "a" : 7, "b" : NumberLong("9007199254740993"), "c" : NumberLong("1"), "d" : Double(1.0), \
            "e" : Double(-0.0), "f" : Double(1e+20), "g" : -2147483648 }
            """)
    }

    @Test("A fraction is written in the fewest digits that read back as the same Double")
    func fractionsUseTheShortestSpelling() {
        #expect(render("{ \"$numberDouble\" : \"0.10000000000000000555\" }") == "0.1")
        #expect(render("{ \"$numberDouble\" : \"2.5\" }") == "2.5")
        #expect(render("{ \"$numberDouble\" : \"-9.9999999999999995475e-08\" }") == "-1e-07")
    }

    @Test("Infinity and NaN are the shell's own names for them")
    func nonFiniteDoubles() {
        #expect(render("{ \"$numberDouble\" : \"Infinity\" }") == "Infinity")
        #expect(render("{ \"$numberDouble\" : \"-Infinity\" }") == "-Infinity")
        #expect(render("{ \"$numberDouble\" : \"NaN\" }") == "NaN")
    }

    @Test("Every Decimal128 goes through NumberDecimal, NaN and the infinities included")
    func decimals() {
        #expect(render("{ \"$numberDecimal\" : \"1.50\" }") == "NumberDecimal(\"1.50\")")
        #expect(render("{ \"$numberDecimal\" : \"-1.23E-7\" }") == "NumberDecimal(\"-1.23E-7\")")
        #expect(render("{ \"$numberDecimal\" : \"NaN\" }") == "NumberDecimal(\"NaN\")")
        #expect(render("{ \"$numberDecimal\" : \"Infinity\" }") == "NumberDecimal(\"Infinity\")")
        #expect(render("{ \"$numberDecimal\" : \"-Infinity\" }") == "NumberDecimal(\"-Infinity\")")
    }

    @Test("A date is an ISODate in the proleptic Gregorian calendar JavaScript counts in")
    func datesAreISODates() {
        let cases: [(millis: String, text: String)] = [
            ("1577934245678", "2020-01-02T03:04:05.678Z"),
            ("0", "1970-01-01T00:00:00.000Z"),
            ("-1", "1969-12-31T23:59:59.999Z"),
            ("951782400000", "2000-02-29T00:00:00.000Z"),
            ("-12219292800001", "1582-10-14T23:59:59.999Z"),
            ("-62135596800000", "0001-01-01T00:00:00.000Z"),
            ("253402300799999", "9999-12-31T23:59:59.999Z")
        ]
        for testCase in cases {
            #expect(
                render("{ \"$date\" : { \"$numberLong\" : \"\(testCase.millis)\" } }") == "ISODate(\"\(testCase.text)\")",
                "\(testCase.millis)"
            )
        }
    }

    @Test("A date outside the years ISODate can spell is a Date of its instant, as far as a Date reaches")
    func farDatesAreDates() {
        for millis in ["-62135596800001", "253402300800000", "8640000000000000", "-8640000000000000"] {
            #expect(render("{ \"$date\" : { \"$numberLong\" : \"\(millis)\" } }") == "new Date(\(millis))", "\(millis)")
        }
    }

    @Test("A date past what a JavaScript Date holds keeps its wrapper, since no shell can write it otherwise")
    func datesPastJavaScriptKeepTheirWrapper() {
        for millis in ["8640000000000001", "-8640000000000001", "-9223372036854775808", "9223372036854775807"] {
            let wrapper = "{ \"$date\" : { \"$numberLong\" : \"\(millis)\" } }"
            #expect(render(wrapper) == wrapper, "\(millis)")
        }
    }

    @Test("Every other type with a shell constructor is written through it")
    func otherConstructors() {
        #expect(render("{ \"$oid\" : \"5f1d7a3b2c4e5a6b7c8d9e0f\" }") == "ObjectId(\"5f1d7a3b2c4e5a6b7c8d9e0f\")")
        #expect(render("{ \"$binary\" : { \"base64\" : \"AAEC\", \"subType\" : \"04\" } }") == "BinData(4, \"AAEC\")")
        #expect(render("{ \"$binary\" : { \"base64\" : \"AAEC\", \"subType\" : \"80\" } }") == "BinData(128, \"AAEC\")")
        #expect(render("{ \"$timestamp\" : { \"t\" : 5, \"i\" : 6 } }") == "Timestamp(5, 6)")
        #expect(render("{ \"$minKey\" : 1 }") == "MinKey()")
        #expect(render("{ \"$maxKey\" : 1 }") == "MaxKey()")
        #expect(render("{ \"$code\" : \"function () { return 1; }\" }") == "Code(\"function () { return 1; }\")")
        #expect(render("{ \"$code\" : \"x\", \"$scope\" : { \"y\" : { \"$numberLong\" : \"2\" } } }")
            == "Code(\"x\", { \"y\" : NumberLong(\"2\") })")
    }

    @Test("A regular expression and a symbol go through the constructors mongosh names them with")
    func regularExpressionsAndSymbols() {
        #expect(render("{ \"$regularExpression\" : { \"pattern\" : \"a\\\\/b\", \"options\" : \"i\" } }")
            == #"BSONRegExp("a\\/b", "i")"#)
        #expect(render("{ \"$regularExpression\" : { \"pattern\" : \"(?x) a # b\\n\", \"options\" : \"lx\" } }")
            == #"BSONRegExp("(?x) a # b\n", "lx")"#)
        #expect(render("{ \"$symbol\" : \"q\\u2028r\" }") == #"BSONSymbol("q\u2028r")"#)
    }

    @Test("A DBPointer and undefined, which mongosh cannot write, keep their wrapper")
    func typesNoShellWritesKeepTheirWrapper() {
        #expect(render("{ \"$undefined\" : true }") == "{ \"$undefined\" : true }")
        #expect(render("""
            { "$dbPointer" : { "$ref" : "c", "$id" : { "$oid" : "5f1d7a3b2c4e5a6b7c8d9e0f" } } }
            """) == """
            { "$dbPointer" : { "$ref" : "c", "$id" : ObjectId("5f1d7a3b2c4e5a6b7c8d9e0f") } }
            """)
    }

    @Test("A member named __proto__ is a computed key, which adds it as a member rather than a prototype")
    func protoMembersAreComputedKeys() {
        #expect(render("""
            { "__proto__" : { "$numberInt" : "1" }, "a" : { "__proto__" : { "b" : "c" } }, "proto" : "__proto__" }
            """) == """
            { ["__proto__"] : 1, "a" : { ["__proto__"] : { "b" : "c" } }, "proto" : "__proto__" }
            """)
    }

    @Test("Query operators are documents, so what they hold is written and they are not")
    func operatorsAreRecursedInto() {
        #expect(render("""
            [ { "$match" : { "a" : { "$gte" : { "$numberLong" : "1" } }, "b" : { "$in" : [ { "$numberInt" : "1" }, "s", null, true ] } } }, \
            { "$sort" : { "a" : { "$numberInt" : "1" }, "w" : { "$numberInt" : "-1" } } } ]
            """) == """
            [ { "$match" : { "a" : { "$gte" : NumberLong("1") }, "b" : { "$in" : [ 1, "s", null, true ] } } }, \
            { "$sort" : { "a" : 1, "w" : -1 } } ]
            """)
    }

    @Test("A string or a member name holding a line separator libbson left raw is written with it escaped")
    func rawLineSeparatorsAreEscaped() {
        let canonical = "{ \"k\u{2028}\" : \"v\u{2029}w\u{85}\", \"n\" : [ \"x\\ny\" ] }"

        #expect(render(canonical) == #"{ "k\u2028" : "v\u2029w\u0085", "n" : [ "x\ny" ] }"#)
    }

    @Test("A value that is neither a literal nor a number is written as the string it spells")
    func unknownScalarsBecomeStrings() {
        #expect(render("{ \"a\" : 1.5e3, \"b\" : -0, \"c\" : undefined, \"d\" : x\u{2028}y }")
            == #"{ "a" : 1.5e3, "b" : -0, "c" : "undefined", "d" : "x\u2028y" }"#)
    }

    @Test("Strings, including ones that look like a wrapper, and empty containers are left alone")
    func scalarsAndEmptyContainers() {
        #expect(render("{ \"k\" : \"{ \\\"$numberLong\\\" : \\\"1\\\" }\" }") == "{ \"k\" : \"{ \\\"$numberLong\\\" : \\\"1\\\" }\" }")
        #expect(render("[ ]") == "[ ]")
        #expect(render("{  }") == "{ }")
        #expect(render("\"text\"") == "\"text\"")
    }
}
