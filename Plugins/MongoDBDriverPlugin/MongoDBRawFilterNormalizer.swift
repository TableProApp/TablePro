//
//  MongoDBRawFilterNormalizer.swift
//  MongoDBDriverPlugin
//

import Foundation
import JavaScriptCore
import TableProPluginKit

/// Turns a filter document the user typed in shell syntax into canonical Extended JSON.
///
/// A raw filter row reaches two consumers with two parsers: `find` evaluates it as JavaScript,
/// where `{status: "active", _id: ObjectId("…")}` is fine, and `countDocuments` hands the same
/// text to libmongoc's JSON parser, where it is not. Serializing through the shell's own `EJSON`
/// once, up front, gives both the document the user meant.
///
/// The prelude is the same one the shell runs, with the host stubbed: it answers the call the
/// prelude makes while loading and the pure value ops behind `UUID(...)` and `HexData(...)`, and
/// refuses every other. Anything that needs the server or answers differently each time, such as
/// `ObjectId()` or `UUID()` with no argument, comes back as `nil` and the row is dropped.
///
/// Each call gets a context of its own. The row is JavaScript, so in a shared context it could
/// reassign `__ejson`, `JSON.stringify` or a prototype and decide what every later row becomes.
///
/// It can also loop forever, and JavaScriptCore's public API cannot interrupt it. Like
/// `MongoScriptRuntime`, the context runs on a queue of its own: a document that misses the
/// deadline is answered `nil` and the context is abandoned with the queue it wedged.
final class MongoDBRawFilterNormalizer: Sendable {
    private static let deadline: TimeInterval = 2

    private final class Engine: @unchecked Sendable {
        let context: JSContext

        init(context: JSContext) {
            self.context = context
        }
    }

    private final class Outcome: @unchecked Sendable {
        var value: String?
    }

    func normalize(_ document: String) -> String? {
        guard let engine = Self.makeEngine() else { return nil }
        let queue = DispatchQueue(label: "com.TablePro.mongodb.rawfilter", qos: .userInitiated)
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            outcome.value = Self.serialize(document, in: engine.context)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + Self.deadline) == .success else { return nil }
        return outcome.value
    }

    private static func serialize(_ document: String, in context: JSContext) -> String? {
        context.exception = nil
        let value = context.evaluateScript("__ejson((\(document)))")
        guard context.exception == nil, let value, value.isString else { return nil }
        return value.toString()
    }

    private static func makeEngine() -> Engine? {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        let host: @convention(block) (String) -> String = { request in Self.answer(request) }
        let swallowOutput: @convention(block) (String) -> Bool = { _ in true }
        context.setObject(host, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(swallowOutput, forKeyedSubscript: "__tp_print" as NSString)
        context.evaluateScript(MongoScriptPrelude.source)
        guard context.exception == nil else { return nil }
        return Engine(context: context)
    }

    private static func answer(_ request: String) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        guard let parsed, let reply = reply(to: parsed) else {
            return MongoScriptJson.failure(message: "The server is not reachable from a filter", code: 0)
        }
        return MongoScriptJson.success(reply)
    }

    /// `find` and `countDocuments` normalize the row separately, so a value op is answered only
    /// when it is deterministic: `UUID()` with no value would give each a different random UUID.
    private static func reply(to request: [String: Any]) -> String? {
        switch request["op"] as? String {
        case "currentDatabase":
            return MongoScriptJson.jsonString("")
        case "hexToBase64":
            return (request["hex"] as? String).flatMap(MongoScriptValueEncoding.base64(hex:))
        case "encodeUuid":
            guard let text = request["value"] as? String else { return nil }
            return MongoScriptValueEncoding.uuid(tag: (request["tag"] as? String) ?? "UUID", text: text)
        default:
            return nil
        }
    }
}

/// Replies to the prelude's value ops that need no server, as JSON text.
enum MongoScriptValueEncoding {
    static func base64(hex: String) -> String? {
        MongoScriptObjectId.data(fromHex: hex).map { MongoScriptJson.jsonString($0.base64EncodedString()) }
    }

    /// The constructor's own tag decides the subtype and the byte order, so it reaches the codec
    /// rather than being normalised to `UUID`.
    static func uuid(tag: String, text: String) -> String? {
        guard let binary = MongoDBUuidCodec.parseWrapper("\(tag)(\"\(text)\")") else { return nil }
        return """
            {"base64": \(MongoScriptJson.jsonString(binary.data.base64EncodedString())), \
            "subtype": \(binary.subtype), "text": \(MongoScriptJson.jsonString(text.lowercased()))}
            """
    }
}
