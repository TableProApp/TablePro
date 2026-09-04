//
//  MongoDBRawFilterNormalizer.swift
//  MongoDBDriverPlugin
//

import Foundation
import JavaScriptCore

/// Turns a filter document the user typed in shell syntax into canonical Extended JSON.
///
/// A raw filter row reaches two consumers with two parsers: `find` evaluates it as JavaScript,
/// where `{status: "active", _id: ObjectId("…")}` is fine, and `countDocuments` hands the same
/// text to libmongoc's JSON parser, where it is not. Serializing through the shell's own `EJSON`
/// once, up front, gives both the document the user meant.
///
/// The prelude is the same one the shell runs, with the host stubbed: it answers the one call
/// the prelude makes while loading and refuses every other, so anything that would need the
/// server, such as `ObjectId()` with no argument, comes back as `nil` and the caller keeps the
/// text it had.
///
/// The text is JavaScript, so it can also loop forever, and JavaScriptCore's public API cannot
/// interrupt it. Like `MongoScriptRuntime`, each engine runs on a queue of its own: a document
/// that misses the deadline is answered `nil`, its engine is abandoned with the queue it wedged,
/// and the next call builds a fresh one.
final class MongoDBRawFilterNormalizer: @unchecked Sendable {
    private static let deadline: TimeInterval = 2

    private final class Engine: @unchecked Sendable {
        let queue: DispatchQueue
        let context: JSContext

        init(queue: DispatchQueue, context: JSContext) {
            self.queue = queue
            self.context = context
        }
    }

    private final class Outcome: @unchecked Sendable {
        var value: String?
    }

    private let lock = NSLock()
    private var engine: Engine?
    private var generation = 0

    func normalize(_ document: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let engine = preparedEngine() else { return nil }

        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        engine.queue.async {
            outcome.value = Self.serialize(document, in: engine.context)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + Self.deadline) == .success else {
            self.engine = nil
            return nil
        }
        return outcome.value
    }

    private static func serialize(_ document: String, in context: JSContext) -> String? {
        context.exception = nil
        let value = context.evaluateScript("__ejson((\(document)))")
        guard context.exception == nil, let value, value.isString else { return nil }
        return value.toString()
    }

    private func preparedEngine() -> Engine? {
        if let engine { return engine }
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        let host: @convention(block) (String) -> String = { request in Self.answer(request) }
        let swallowOutput: @convention(block) (String) -> Bool = { _ in true }
        context.setObject(host, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(swallowOutput, forKeyedSubscript: "__tp_print" as NSString)
        context.evaluateScript(MongoScriptPrelude.source)
        guard context.exception == nil else { return nil }

        generation += 1
        let queue = DispatchQueue(
            label: "com.TablePro.mongodb.rawfilter.\(generation)", qos: .userInitiated
        )
        let built = Engine(queue: queue, context: context)
        engine = built
        return built
    }

    private static func answer(_ request: String) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        guard parsed?["op"] as? String == "currentDatabase" else {
            return MongoScriptJson.failure(message: "The server is not reachable from a filter", code: 0)
        }
        return MongoScriptJson.success(MongoScriptJson.jsonString(""))
    }
}
