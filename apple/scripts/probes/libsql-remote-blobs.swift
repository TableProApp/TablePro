// Run against a local sqld with the registry plugin and framework from the same build.
// swiftc -F "$PRODUCTS" -framework TableProPluginKit -Xlinker -rpath -Xlinker "$PRODUCTS" libsql-remote-blobs.swift -o /tmp/libsql-blobs
// /tmp/libsql-blobs "$PRODUCTS/LibSQLDriverPlugin.tableplugin" http://127.0.0.1:8080

import Foundation
import TableProPluginKit

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

guard CommandLine.arguments.count == 3 else {
    throw ProbeFailure(description: "Expected the plugin bundle path and local sqld URL")
}
let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bundle = Bundle(url: bundleURL) else { throw ProbeFailure(description: "Missing plugin bundle") }
try bundle.loadAndReturnError()
guard let plugin = bundle.principalClass as? any DriverPlugin.Type else {
    throw ProbeFailure(description: "Missing driver plugin")
}
let config = DriverConnectionConfig(
    host: "", port: 0, username: "", password: "", database: "",
    additionalFields: ["libsqlMode": "remote", "databaseUrl": CommandLine.arguments[2]]
)
let driver = plugin.init().createDriver(config: config)
try await driver.connect()
defer { driver.disconnect() }

let query = "SELECT X'', X'FF', X'00FF', X'FBFFFF', NULL, '00ff'"
let expected: [PluginRow] = [[
    .bytes(Data()), .bytes(Data([0xff])), .bytes(Data([0, 0xff])),
    .bytes(Data([0xfb, 0xff, 0xff])), .null, .text("00ff")
]]
guard try await driver.execute(query: query).rows == expected else {
    throw ProbeFailure(description: "Buffered result changed the type or bytes of a cell")
}
var streamed: [PluginRow] = []
for try await element in driver.streamRows(query: query) {
    if case .rows(let rows) = element { streamed.append(contentsOf: rows) }
}
guard streamed == expected else { throw ProbeFailure(description: "Stream changed the type or bytes of a cell") }
let bound = try await driver.executeParameterized(query: "SELECT ?", parameters: [.bytes(Data([0xff]))])
guard bound.rows == [[.bytes(Data([0xff]))]] else { throw ProbeFailure(description: "Bound BLOB did not round-trip") }
print("PASS: buffered, streamed and bound remote libSQL BLOBs")
