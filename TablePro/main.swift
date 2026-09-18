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
///
/// The activation policy resolves next, before `NSApplicationMain`. A process the MCP bridge
/// started opens no window, and this is the only point early enough to keep LaunchServices from
/// registering it as a foreground app and putting it in the Dock first.
MainActor.assumeIsolated { LaunchTracer.shared.mark(.main) }
AppStorageEnvironment.bootstrap()
MainActor.assumeIsolated { LaunchTracer.shared.mark(.storageResolved) }
let application = NSApplication.shared
MainActor.assumeIsolated {
    LaunchTracer.shared.mark(.applicationCreated)
    AppActivationPolicyController.shared.applyLaunchRole()
    LaunchTracer.shared.mark(.activationRoleApplied)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
