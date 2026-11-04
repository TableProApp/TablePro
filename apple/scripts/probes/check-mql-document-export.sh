#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$ROOT/.analysis/mql-document-export"
SCRATCH="$(mktemp -d "$ROOT/.analysis/mql-document-export/probe.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
cat > "$SCRATCH/main.swift" <<'SWIFT'
import Foundation
import JavaScriptCore

let context = JSContext()!
var failure: String?
context.exceptionHandler = { _, exception in failure = exception?.toString() }
context.evaluateScript("var __tp_exec = function() { return '{\"ok\":true,\"v\":\"app\"}'; }; var __tp_print = function() { return true; };")
context.evaluateScript(MongoScriptPrelude.source)
let cases: [(String, String)] = [
    (#"__ejson(new Map([["z",null],["10","a"],["2","b"],["__proto__",new Map([["10","x"],["2","y"]])]]))"#,
     #"{"z":null,"10":"a","2":"b","__proto__":{"10":"x","2":"y"}}"#),
    (#"__ejson(EJSON.parse('{"$numberDouble":"1.0"}', {relaxed:false}))"#,
     #"{"$numberDouble":"1"}"#),
    (#"__ejson(EJSON.parse('{"$numberLong":"9007199254740993"}', {relaxed:false}))"#,
     #"{"$numberLong":"9007199254740993"}"#),
    (#"__ejson(EJSON.parse('{"$symbol":"hello"}', {relaxed:false}))"#,
     #"{"$symbol":"hello"}"#),
    (#"__ejson(Code("return x", new Map([["10",NumberLong("5")],["2",null]])))"#,
     #"{"$code":"return x","$scope":{"10":{"$numberLong":"5"},"2":null}}"#)
]
for (script, expected) in cases {
    let actual = context.evaluateScript(script)?.toString()
    guard failure == nil, actual == expected else {
        fatalError("Expected \(expected), received \(actual ?? "nil"), error \(failure ?? "none")")
    }
}
print("PASS: ordered documents, nested keys, integral Double, Int64, BSONSymbol and Code scope")
SWIFT
xcrun swiftc -swift-version 6 \
    "$ROOT/apple/Plugins/MongoDBDriverPlugin/MongoScriptPrelude.swift" \
    "$SCRATCH/main.swift" -framework JavaScriptCore -o "$SCRATCH/probe"
"$SCRATCH/probe"
