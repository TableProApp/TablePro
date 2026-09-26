#!/usr/bin/env bash
#
# The Edit Document guard, built by the driver's own code and asked of a real server.
#
# MongoDocumentGuard writes an aggregation expression by hand, and it only works while it agrees
# with what the server's $eq, $type and $convert answer. The unit tests can pin its text but cannot
# ask a server. A guard that matches too much overwrites a change someone else made, and one that
# matches nothing or raises makes every save fail. So this compiles the guard's own sources with
# swiftc against the libbson and libmongoc the plugin links, inserts each document exactly as its
# canonical Extended JSON reads, and counts what the filter matches under the simple collation the
# save runs under: the unchanged document must match once, every mutation must match nothing, and
# neither order of the two $and operands may raise. A NaN and code with a scope are compared by
# value, so no filter can see a change to one, and the guard must refuse to be built for them.
#
# Usage:
#   scripts/check-mongodb-document-guard.sh [mongodb-uri]
#
# The default URI is mongodb://127.0.0.1:27017. Needs MongoDB 4.0 or later and the static libraries
# from scripts/download-libs.sh. Writes only to a database named tablepro_guard_check_<pid>, which
# it drops. Exits non-zero on a disagreement.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URI="${1:-mongodb://127.0.0.1:27017}"
PLUGIN="$ROOT/Plugins/MongoDBDriverPlugin"
LIBS="$ROOT/Libs"

for lib in "$LIBS/libmongoc.a" "$LIBS/libbson.a" "$LIBS/dylibs/libssl.3.dylib" "$LIBS/dylibs/libcrypto.3.dylib"; do
    [ -e "$lib" ] || {
        echo "missing $lib (run scripts/download-libs.sh)" >&2
        exit 3
    }
done

# A private directory, matching every sibling check script. /tmp is world-writable, so a fixed
# name is something another local user can pre-create and control.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import CLibMongoc
import Foundation

typealias Value = MongoDocumentText.Value

struct Case {
    let name: String
    let original: String
    var collation: String?
    let mutations: [(String, String)]
}

func document(_ fields: String) -> String {
    #"{"_id":{"$numberInt":"1"},\#(fields)}"#
}

func nested(_ depth: Int, innermost: String) -> String {
    var value = innermost
    for _ in 0 ..< depth - 1 {
        value = #"{"k":\#(value)}"#
    }
    return document(#""v":\#(value)"#)
}

func intArray(_ count: Int, replacingLastWith last: String? = nil) -> String {
    var elements = (0 ..< count).map { #"{"$numberInt":"\#($0)"}"# }
    if let last { elements[count - 1] = last }
    return document(#""a":[\#(elements.joined(separator: ","))]"#)
}

let numbers = #""a":{"$numberInt":"5"},"b":{"c":[{"$numberInt":"1"},{"$numberDouble":"0.0"},{"$numberDecimal":"1.0"}]},"s":"Hello""#
let zoo = #""oid":{"$oid":"65f0a1b2c3d4e5f607182930"},"sym":{"$symbol":"s"},"u":{"$undefined":true},"#
    + #""code":{"$code":"y"},"mn":{"$minKey":1},"#
    + #""mx":{"$maxKey":1},"ts":{"$timestamp":{"t":5,"i":1}},"bin":{"$binary":{"base64":"AQID","subType":"80"}},"#
    + #""re":{"$regularExpression":{"pattern":"a.b","options":"i"}},"d":{"$date":{"$numberLong":"-1000"}},"#
    + #""l":{"$numberLong":"9007199254740993"},"n":null,"t":true,"#
    + #""dinf":{"$numberDecimal":"Infinity"},"inf":{"$numberDouble":"-Infinity"}"#

/// Values the server compares by what they mean, which no filter can see past, so the guard has to
/// refuse to be built for them rather than build one that lets a change through.
let refused: [(String, MongoDocumentGuard.Refusal)] = [
    (document(#""n":{"$numberDouble":"NaN"}"#), .notANumber),
    (document(#""n":{"$numberDecimal":"NaN"}"#), .notANumber),
    (document(#""a":[{"o":{"$numberDouble":"NaN"}}]"#), .notANumber),
    (document(#""c":{"$code":"x","$scope":{"a":{"$numberInt":"1"}}}"#), .codeWithScope)
]

let cases = [
    Case(name: "numbers and strings", original: document(numbers), mutations: [
        ("int32 to int64", document(numbers.replacingOccurrences(of: #""a":{"$numberInt":"5"}"#, with: #""a":{"$numberLong":"5"}"#))),
        ("int32 to double", document(numbers.replacingOccurrences(of: #""a":{"$numberInt":"5"}"#, with: #""a":{"$numberDouble":"5.0"}"#))),
        ("nested int32 to int64", document(numbers.replacingOccurrences(of: #"[{"$numberInt":"1"}"#, with: #"[{"$numberLong":"1"}"#))),
        ("0.0 to -0.0", document(numbers.replacingOccurrences(of: #""0.0""#, with: #""-0.0""#))),
        ("decimal 1.0 to 1.00", document(numbers.replacingOccurrences(of: #""1.0"}]"#, with: #""1.00"}]"#))),
        ("decimal to double", document(numbers.replacingOccurrences(of: #"{"$numberDecimal":"1.0"}"#, with: #"{"$numberDouble":"1.0"}"#))),
        ("decimal to object", document(numbers.replacingOccurrences(of: #"{"$numberDecimal":"1.0"}"#, with: #"{"x":{"$numberInt":"1"}}"#))),
        ("zero to array", document(numbers.replacingOccurrences(of: #"{"$numberDouble":"0.0"}"#, with: "[]"))),
        ("case of a string", document(numbers.replacingOccurrences(of: "Hello", with: "hello"))),
        ("string to symbol", document(numbers.replacingOccurrences(of: #""Hello""#, with: #"{"$symbol":"Hello"}"#))),
        ("fields reordered", document(#""s":"Hello","a":{"$numberInt":"5"},"b":{"c":[{"$numberInt":"1"},{"$numberDouble":"0.0"},{"$numberDecimal":"1.0"}]}"#)),
        ("field removed", document(#""a":{"$numberInt":"5"},"s":"Hello""#)),
        ("null field added", document(numbers + #","z":null"#)),
        ("object to scalar", document(#""a":{"$numberInt":"5"},"b":{"$numberInt":"3"},"s":"Hello""#)),
        ("array to object", document(#""a":{"$numberInt":"5"},"b":{"c":{"0":{"$numberInt":"1"},"1":{"$numberDouble":"0.0"},"2":{"$numberDecimal":"1.0"}}},"s":"Hello""#))
    ]),
    Case(name: "field names", original: #"{"_id":{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}},"":"e","a.b":{"$numberInt":"2"},"x":{"$w":{"$numberInt":"1"},"n.m":[{"$numberDecimal":"0E+10"}]}}"#, mutations: [
        ("_id fields reordered", #"{"_id":{"b":{"$numberInt":"2"},"a":{"$numberInt":"1"}},"":"e","a.b":{"$numberInt":"2"},"x":{"$w":{"$numberInt":"1"},"n.m":[{"$numberDecimal":"0E+10"}]}}"#),
        ("$w int32 to int64", #"{"_id":{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}},"":"e","a.b":{"$numberInt":"2"},"x":{"$w":{"$numberLong":"1"},"n.m":[{"$numberDecimal":"0E+10"}]}}"#),
        ("decimal 0E+10 to 0", #"{"_id":{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}},"":"e","a.b":{"$numberInt":"2"},"x":{"$w":{"$numberInt":"1"},"n.m":[{"$numberDecimal":"0"}]}}"#),
        ("empty name's value", #"{"_id":{"a":{"$numberInt":"1"},"b":{"$numberInt":"2"}},"":"E","a.b":{"$numberInt":"2"},"x":{"$w":{"$numberInt":"1"},"n.m":[{"$numberDecimal":"0E+10"}]}}"#)
    ]),
    Case(name: "every type", original: document(zoo), mutations: [
        ("decimal Infinity to double", document(zoo.replacingOccurrences(of: #"{"$numberDecimal":"Infinity"}"#, with: #"{"$numberDouble":"Infinity"}"#))),
        ("undefined to null", document(zoo.replacingOccurrences(of: #"{"$undefined":true}"#, with: "null"))),
        ("symbol to string", document(zoo.replacingOccurrences(of: #"{"$symbol":"s"}"#, with: #""s""#))),
        ("code to code with scope", document(zoo.replacingOccurrences(of: #"{"$code":"y"}"#, with: #"{"$code":"y","$scope":{}}"#))),
        ("binary subtype", document(zoo.replacingOccurrences(of: #""subType":"80""#, with: #""subType":"00""#))),
        ("regex options", document(zoo.replacingOccurrences(of: #""options":"i""#, with: #""options":"m""#))),
        ("timestamp increment", document(zoo.replacingOccurrences(of: #""i":1"#, with: #""i":2"#)))
    ]),
    Case(name: "string under a case-insensitive default collation", original: document(#""s":"Hello""#),
         collation: #"{"locale":"en","strength":2}"#,
         mutations: [("case of a string", document(#""s":"hello""#))]),
    Case(name: "deepest document", original: nested(MongoDocumentGuard.maximumDepth, innermost: #"{"$numberInt":"1"}"#), mutations: [
        ("innermost int32 to int64", nested(MongoDocumentGuard.maximumDepth, innermost: #"{"$numberLong":"1"}"#))
    ]),
    Case(name: "10,000-element array", original: intArray(10_000), mutations: [
        ("last element int32 to int64", intArray(10_000, replacingLastWith: #"{"$numberLong":"9999"}"#))
    ])
]

func bson(_ json: String) -> OpaquePointer {
    var error = bson_error_t()
    guard let parsed = json.withCString({ bson_new_from_json($0, -1, &error) }) else {
        let message = withUnsafeBytes(of: &error.message) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        FileHandle.standardError.write(Data("libbson cannot read: \(message)\n\(json.prefix(300))\n".utf8))
        exit(2)
    }
    return parsed
}

func errorText(_ error: inout bson_error_t) -> String {
    withUnsafeBytes(of: &error.message) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// The same filter with its two `$and` operands swapped, since the server may evaluate either first.
func reversed(_ filter: String) throws -> String {
    let wrapper = try MongoDocumentText(parsing: #"{"f":\#(filter)}"#)
    guard case .object(let members) = try require(wrapper.value(of: "f")),
          let expression = members.first(where: { $0.key == "$expr" }),
          case .object(let conditions) = expression.value,
          let conjunction = conditions.first,
          case .array(let operands) = conjunction.value else {
        throw MongoDocumentGuard.Refusal.unreadableValue
    }
    let swapped = Value.object([MongoDocumentText.Member(key: "$and", value: .array(operands.reversed()))])
    let rebuilt = members.map { $0.key == "$expr" ? MongoDocumentText.Member(key: "$expr", value: swapped) : $0 }
    return Value.object(rebuilt).compactText
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw MongoDocumentGuard.Refusal.unreadableValue }
    return value
}

@main
enum GuardCheck {
    static func main() {
        mongoc_init()
        let uri = CommandLine.arguments[1]
        guard let client = mongoc_client_new(uri) else {
            FileHandle.standardError.write(Data("cannot read the URI \(uri)\n".utf8))
            exit(3)
        }
        let database = mongoc_client_get_database(client, "tablepro_guard_check_\(getpid())")
        var run = Run()
        for (index, check) in cases.enumerated() {
            run.check(check, in: database, named: "c\(index)")
        }
        for (original, refusal) in refused {
            run.expectRefusal(original, refusal)
        }
        _ = mongoc_database_drop(database, nil)
        guard run.failures == 0 else {
            print("\n\(run.failures) disagreement(s)")
            exit(1)
        }
        print("\nthe guard agrees with the server")
    }
}

struct Run {
    let simple = bson(#"{"collation":{"locale":"simple"}}"#)
    let unvalidated = bson(#"{"validate":false}"#)
    var failures = 0

    mutating func check(_ check: Case, in database: OpaquePointer?, named name: String) {
        var error = bson_error_t()
        let options = check.collation.map { bson(#"{"collation":\#($0)}"#) }
        guard let collection = mongoc_database_create_collection(database, name, options, &error) else {
            fail("\(check.name): could not create the collection: \(errorText(&error))")
            return
        }
        let filter: String
        let flipped: String
        do {
            filter = try MongoDocumentGuard.filter(for: MongoDocumentText(parsing: check.original))
            flipped = try reversed(filter)
        } catch {
            fail("\(check.name): the guard could not be built: \(error)")
            return
        }
        guard store(collection, check.original) else { return }
        expect("\(check.name): unchanged document matches", [count(collection, filter), count(collection, flipped)], "1")
        for (mutation, json) in check.mutations {
            guard store(collection, json) else { continue }
            expect("\(check.name): \(mutation) matches nothing", [count(collection, filter), count(collection, flipped)], "0")
        }
    }

    func count(_ collection: OpaquePointer, _ filter: String) -> String {
        let query = bson(filter)
        defer { bson_destroy(query) }
        var error = bson_error_t()
        let matched = mongoc_collection_count_documents(collection, query, simple, nil, nil, &error)
        return matched < 0 ? "error: \(errorText(&error))" : String(matched)
    }

    mutating func store(_ collection: OpaquePointer, _ json: String) -> Bool {
        var error = bson_error_t()
        let everything = bson("{}")
        defer { bson_destroy(everything) }
        _ = mongoc_collection_delete_many(collection, everything, nil, nil, &error)
        let stored = bson(json)
        defer { bson_destroy(stored) }
        guard mongoc_collection_insert_one(collection, stored, unvalidated, nil, &error) else {
            fail("could not insert: \(errorText(&error))")
            return false
        }
        return true
    }

    mutating func expect(_ label: String, _ answers: [String], _ expected: String) {
        guard answers.allSatisfy({ $0 == expected }) else {
            fail("\(label): expected \(expected) in both operand orders, got \(answers.joined(separator: " and "))")
            return
        }
        print("ok    \(label)")
    }

    mutating func expectRefusal(_ original: String, _ refusal: MongoDocumentGuard.Refusal) {
        do {
            let filter = try MongoDocumentGuard.filter(for: MongoDocumentText(parsing: original))
            fail("\(original): built a guard where \(refusal) was expected: \(filter.prefix(120))")
        } catch let error as MongoDocumentGuard.Refusal where error == refusal {
            print("ok    refused \(refusal): \(original)")
        } catch {
            fail("\(original): expected \(refusal), got \(error)")
        }
    }

    mutating func fail(_ message: String) {
        print("FAIL  \(message)")
        failures += 1
    }
}
SWIFT

echo "Building the guard checker from $PLUGIN"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" xcrun swiftc -swift-version 6 -parse-as-library -O \
    -module-name GuardCheck \
    -I "$PLUGIN/CLibMongoc" \
    -Xcc "-I$PLUGIN/CLibMongoc/include" \
    -Xcc "-I$PLUGIN/CLibMongoc/include/libbson-1.0" \
    -Xcc "-I$PLUGIN/CLibMongoc/include/libmongoc-1.0" \
    -L "$LIBS/dylibs" \
    -Xlinker -force_load -Xlinker "$LIBS/libmongoc.a" \
    -Xlinker -force_load -Xlinker "$LIBS/libbson.a" \
    -lssl.3 -lcrypto.3 -lresolv -lz \
    -Xlinker -rpath -Xlinker "$LIBS/dylibs" \
    "$PLUGIN/MongoDocumentText.swift" \
    "$PLUGIN/MongoExtendedJsonType.swift" \
    "$PLUGIN/MongoDocumentGuard.swift" \
    "$PLUGIN/MongoDocumentIdentity.swift" \
    "$PLUGIN/MongoDBDocumentEditingError.swift" \
    "$WORK/main.swift" \
    -o "$WORK/check" > "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 2
}

"$WORK/check" "$URI"
