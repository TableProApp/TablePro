//
//  main.swift
//  TablePro
//

import AppKit

/// The app owns its own menu bar, so it runs the AppKit lifecycle rather than a SwiftUI `App`.
/// SwiftUI reconciles `NSApp.mainMenu` once after launch and discards anything it did not build,
/// which no supported hook can undo. `NSApplicationMain` takes no delegate argument on macOS, so
/// the delegate is assigned before it runs.
/// Top-level code is nonisolated but runs on the main thread, which is what the delegate needs.
///
/// Storage resolves first. Any store reached from a static initializer would otherwise have
/// computed a production path already, and a sandbox that arrives afterwards only covers whatever
/// had not been touched yet.
AppStorageEnvironment.bootstrap()
let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
