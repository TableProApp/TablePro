//
//  AppActivationPolicyController.swift
//  TablePro
//

import AppKit
import os

/// The only place in the app that reads or writes `NSApplication.activationPolicy`, and the only
/// place that calls `NSApplication.activate`. `AppActivationPolicySourceTests` enforces that, because
/// the two are the same decision: bringing the app forward for a person is what makes it an app the
/// person can see, and a background process that activates without a Dock icon or a menu bar leaves
/// them a window with no Cmd+W, no Cmd+Q and no Edit menu.
///
/// Three measured behaviours shape this (macOS 26, probe app observed through `lsappinfo`):
/// the launch role has to be applied before `NSApplicationMain` or LaunchServices registers a
/// foreground app first and the Dock icon appears; LaunchServices promotes a running accessory app
/// on *any* `open` request, including the `open -g <url>` the MCP bridge uses, so the role is
/// re-applied whenever a URL arrives; and `NSApp.activate()` alone will not bring a
/// just-promoted app forward, while `activate(ignoringOtherApps:)` will.
@MainActor
internal final class AppActivationPolicyController {
    internal static let shared = AppActivationPolicyController()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AppActivationPolicy")

    internal private(set) var origin: AppSessionOrigin = .user

    private init() {}

    /// Called from `main.swift` before `NSApplicationMain`.
    internal func applyLaunchRole(environment: [String: String] = ProcessInfo.processInfo.environment) {
        origin = AppActivationPolicyDecision.launchOrigin(for: environment)
        Self.logger.info("Launch origin resolved as \(String(describing: self.origin), privacy: .public)")
        applyCurrentRole()
    }

    /// A URL launch is the only way a machine session can be started by something that cannot set
    /// the environment variable, and it is also the moment LaunchServices puts a running accessory
    /// app back in the Dock.
    internal func adoptIntents(_ intents: [LaunchIntent], isLaunching: Bool) {
        origin = AppActivationPolicyDecision.origin(
            adopting: intents,
            current: origin,
            isLaunching: isLaunching
        )
        applyCurrentRole()
    }

    /// The person reached for the app itself, so it is theirs from now on however it started.
    internal func adoptUserSession() {
        origin = .user
        applyCurrentRole()
    }

    /// The replacement for every `NSApp.activate` call in the app. It mirrors AppKit's own two
    /// spellings so each call site keeps the behaviour it had, and adds the one thing none of them
    /// could do for themselves: the policy has to change before the activation, not after, because
    /// an accessory app cannot reliably take focus.
    /// Measured: a process that has just left the background will not come forward for
    /// `NSApp.activate()`, only for `activate(ignoringOtherApps:)`. So a call that promoted the app
    /// takes the forcing spelling whatever the caller asked for, or the window it is about to show
    /// opens behind whatever the person was looking at.
    internal func activate(ignoringOtherApps: Bool = false) {
        let promoted = enterForeground()
        if ignoringOtherApps || promoted {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
    }

    /// For a path that puts a window on screen without asking to come forward. The window does not
    /// exist yet at this point, so this promotes outright rather than counting windows.
    @discardableResult
    internal func enterForeground() -> Bool {
        apply(.foreground)
    }

    /// A closing window is still visible and still in `NSApp.windows` while `willCloseNotification`
    /// runs, so the window that prompted the recount is excluded from it.
    internal func reevaluate(excluding closingWindow: NSWindow? = nil) {
        applyCurrentRole(excluding: closingWindow)
    }

    private func applyCurrentRole(excluding closingWindow: NSWindow? = nil) {
        _ = apply(
            AppActivationPolicyDecision.role(
                origin: origin,
                hasUserFacingWindow: hasUserFacingWindow(excluding: closingWindow)
            )
        )
    }

    /// Any window the person can put focus into counts, which covers alerts and the document
    /// inspector without a list of window identifiers to keep in step with the windows that exist.
    ///
    /// `isVisible` alone is not that question. A miniaturized window is one the person put in the
    /// Dock to come back to, and a hidden app reports every window it owns as invisible, so either
    /// would read as "nothing on screen" and drop a live window's menu bar out from under it.
    private func hasUserFacingWindow(excluding closingWindow: NSWindow?) -> Bool {
        NSApp.windows.contains { window in
            guard window !== closingWindow, window.canBecomeKey else { return false }
            return window.isVisible || window.isMiniaturized || NSApp.isHidden
        }
    }

    /// Returns whether this changed the policy. `setActivationPolicy` answers that question too, but
    /// only when it is asked to change something: it returns `false` for a policy the app already
    /// holds, so reading its result as success would report a failure on every no-op.
    @discardableResult
    private func apply(_ role: AppActivationRole) -> Bool {
        let policy: NSApplication.ActivationPolicy = role == .background ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return false }
        NSApp.setActivationPolicy(policy)
        Self.logger.info("Activation policy now \(String(describing: role), privacy: .public)")
        return true
    }
}
