import Foundation
import JavaScriptCore
import os

/// A `JSContext` with the shell's bridge and prelude installed.
///
/// The runtime and the prelude tests both build their context here. JavaScriptCore's default
/// `exceptionHandler` is what stores an uncaught exception in `exception`, and a handler that
/// replaces it has to do the same or every exception is lost. The runtime's own handler only logged,
/// so `exception` stayed nil after every failed statement and each failure, a server's refusal
/// included, came back as a statement that returned nothing. The tests built a context of their own
/// with the default handler, which is why none of them saw it.
enum MongoScriptContext {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoScriptRuntime")

    static func make(
        execute: @escaping @convention(block) (String) -> String,
        emit: @escaping @convention(block) (String) -> Bool
    ) throws -> JSContext {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            throw MongoScriptError(MongoScriptText.scriptEngineUnavailable)
        }
        context.setObject(execute, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(emit, forKeyedSubscript: "__tp_print" as NSString)
        context.exceptionHandler = { context, exception in
            logger.debug("Script exception: \(exception?.toString() ?? "unknown", privacy: .private)")
            context?.exception = exception
        }

        context.evaluateScript(MongoScriptPrelude.source)
        if let failure = context.exception {
            throw MongoScriptError(failure.toString() ?? MongoScriptText.scriptEngineUnavailable)
        }
        return context
    }

    /// The failed write an exception stands for, or nil when it is not a write's failure.
    ///
    /// Read from the exception that actually escaped rather than from the last write that failed:
    /// a script can catch a write's timeout and then time out on a read, and both carry the same
    /// code and message.
    static func writeFailure(in exception: JSValue) -> MongoWriteFailure? {
        guard exception.objectForKeyedSubscript("isMongoError")?.toBool() == true,
              let stageName = exception.objectForKeyedSubscript("__writeStage"), stageName.isString,
              let stage = MongoWriteFailure.Stage(rawValue: stageName.toString()) else {
            return nil
        }
        return MongoWriteFailure(
            code: UInt32(max(0, exception.objectForKeyedSubscript("code")?.toInt32() ?? 0)),
            message: exception.objectForKeyedSubscript("message")?.toString() ?? "",
            stage: stage
        )
    }
}
