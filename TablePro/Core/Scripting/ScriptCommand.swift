//
//  ScriptCommand.swift
//  TablePro
//

import AppKit
import Foundation
import os

/// Carries a main-actor value across the isolation boundary Cocoa Scripting hands us.
///
/// Cocoa delivers every Apple event on the main thread and documents `resumeExecutionWithResult:`
/// as callable from any thread, but none of the scripting types are `Sendable`, so the compiler
/// cannot see either fact. This is the same shape `AppDelegate` uses for a UserNotifications
/// callback, and it is used here for the same reason.
internal struct ScriptingBox<Value>: @unchecked Sendable {
    internal let value: Value
    internal init(_ value: Value) { self.value = value }
}

/// The base every TablePro script command is built on.
///
/// Connecting and running a statement are asynchronous and can put a Safe Mode dialog in front of a
/// person, so a command cannot answer inside `performDefaultImplementation`. Cocoa's documented
/// answer is `suspendExecution()`, and the reply is delivered when `resumeExecution(withResult:)`
/// runs. Measured: the sending script waits, other Apple events are still answered meanwhile, and a
/// modal alert inside the suspended command works.
///
/// Subclasses override `run()` and nothing else. That keeps the suspend and resume plumbing in one
/// place, and it is what makes a command testable: `run()` is an ordinary async function that a test
/// calls directly, because suspend and resume do nothing outside real Apple event handling.
internal class ScriptCommand: NSScriptCommand {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "Scripting")

    /// The object the command was addressed to, when it was addressed to one.
    ///
    /// A command whose direct parameter is a specifier is dispatched to that object rather than to
    /// the application, measured: `connect connection "prod"` reaches `ScriptConnection`'s handler
    /// and never reaches `performDefaultImplementation`. Both routes end up here.
    private(set) var receiverObject: NSObject?

    /// The sending application's name, read while the event is still being dispatched.
    ///
    /// `NSAppleEventManager.currentAppleEvent` is only the event in flight during dispatch, and
    /// `run()` executes after `suspendExecution()` has handed control back, so reading it there
    /// returns nil or some other command's event. Captured once here instead, which is the only
    /// point that is still inside the dispatch.
    private(set) var sendingApplication: String?

    /// The command's work. Anything it throws is reported to the script as an error.
    @MainActor
    internal func run() async throws -> Any? {
        nil
    }

    override func performDefaultImplementation() -> Any? {
        begin(receiver: nil)
    }

    internal func begin(receiver: NSObject?) -> Any? {
        receiverObject = receiver
        sendingApplication = Self.sendingApplicationName()
        let box = ScriptingBox(self)
        suspendExecution()
        Task { @MainActor in
            let command = box.value
            do {
                let result = try await command.run()
                command.resumeExecution(withResult: result)
            } catch {
                let scripting = ScriptingError.from(error)
                Self.logger.error(
                    "\(type(of: command), privacy: .public) failed: \(scripting.errorDescription ?? "", privacy: .public)"
                )
                command.scriptErrorNumber = scripting.number
                command.scriptErrorString = scripting.errorDescription
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    // MARK: - Arguments

    @MainActor
    internal func requiredConnection() throws -> ScriptConnection {
        guard let connection = evaluatedArguments?[ScriptingKeys.Parameter.connection] as? ScriptConnection else {
            throw ScriptingError.noSuchObject(String(localized: "Name a connection to run this on."))
        }
        return connection
    }

    /// The object a `connect connection "prod"` style command was addressed to.
    @MainActor
    internal func requiredReceiver<Object: NSObject>(_ type: Object.Type) throws -> Object {
        guard let object = receiverObject as? Object else {
            throw ScriptingError.noSuchObject(String(localized: "That object does not exist."))
        }
        return object
    }

    @MainActor
    internal func requiredText() throws -> String {
        let text = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            throw ScriptingError.failed(String(localized: "This command needs some text."))
        }
        return text
    }

    @MainActor
    internal func optionalString(_ key: String) -> String? {
        guard let value = evaluatedArguments?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    internal func optionalInt(_ key: String) -> Int? {
        (evaluatedArguments?[key] as? NSNumber)?.intValue
    }

    /// The application that sent this Apple event, for the confirmation dialog and the audit log.
    ///
    /// Read from the sender pid the kernel stamps on the event, never from anything the script says
    /// about itself, so a script cannot claim to be some other app.
    private static func sendingApplicationName() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr)
        else {
            return nil
        }
        let pid = descriptor.int32Value
        guard pid != 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName ?? app.bundleIdentifier
    }
}

/// The bridge between Cocoa's receiver dispatch and `ScriptCommand`'s async plumbing.
///
/// A command addressed to an object is delivered by calling a method on that object, so each
/// scriptable class needs an `@objc` entry point per verb it answers. They all do the same thing,
/// which is hand the command back to itself with the receiver attached.
internal protocol ScriptCommandReceiving: NSObject {}

internal extension ScriptCommandReceiving {
    func beginScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let command = command as? ScriptCommand else { return nil }
        return command.begin(receiver: self)
    }
}
