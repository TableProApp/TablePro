//
//  AppActivationPolicy.swift
//  TablePro
//

import Foundation

/// Who asked for this process to exist. TablePro is a normal app that is also a background server:
/// the bundled `tablepro-mcp` bridge launches it to answer MCP requests, and that launch opens no
/// window at all. A machine-launched process that occupies the Dock and the app switcher is
/// claiming to be something the person never started.
///
/// A user session is never downgraded. Only a machine session can end up back in the background,
/// so an app the person launched can never disappear from the Dock while they are looking at it.
internal enum AppSessionOrigin: Equatable, Sendable {
    case user
    case machine
}

/// What the process should look like to the rest of the system right now. `background` is
/// `NSApplicationActivationPolicy.accessory`: no Dock icon, no app-switcher entry, and no menu bar.
internal enum AppActivationRole: Equatable, Sendable {
    case background
    case foreground
}

/// The decisions, separated from acting on them so they can be tested without a running
/// `NSApplication`. `AppActivationPolicyController` is the only place that applies them.
internal enum AppActivationPolicyDecision {
    /// `BackgroundLaunchFlag` is set by `MCPHandshakeAcquirer.launchHostApp` on the `open` process it
    /// spawns, and read here before `NSApplicationMain` runs. That timing is the whole point:
    /// deciding any later, even in `application(_:open:)`, still leaves the app registered with
    /// LaunchServices as a foreground app for ~160ms, which is a Dock icon the person can see.
    internal static func launchOrigin(for environment: [String: String]) -> AppSessionOrigin {
        BackgroundLaunchFlag.isSet(in: environment) ? .machine : .user
    }

    /// A launcher that cannot set the environment variable still reaches the same end state through
    /// the intents it delivers: the Raycast extension and anyone typing
    /// `open tablepro://integrations/start-mcp` open the URL directly, and a launch whose only
    /// reason to exist is starting the server is a machine's launch whoever spelled it. Those pay
    /// the brief Dock icon the variable exists to avoid, and then go quiet.
    ///
    /// Only a launch can decide this. The same URL arriving at a running app says nothing about who
    /// started it, so it leaves the origin alone; asking a window-less app already serving somebody
    /// to go back to the background is a decision that was made when it launched.
    internal static func origin(
        adopting intents: [LaunchIntent],
        current: AppSessionOrigin,
        isLaunching: Bool
    ) -> AppSessionOrigin {
        if intents.contains(where: \.impliesUserInterface) { return .user }
        guard isLaunching, !intents.isEmpty else { return current }
        return .machine
    }

    internal static func role(origin: AppSessionOrigin, hasUserFacingWindow: Bool) -> AppActivationRole {
        switch origin {
        case .user:
            return .foreground
        case .machine:
            return hasUserFacingWindow ? .foreground : .background
        }
    }
}

internal extension LaunchIntent {
    /// Every intent puts something on screen except the one that exists to start a server. An
    /// exhaustive switch with no `default:` is what forces a new intent to answer this question
    /// instead of inheriting an answer that happens to be wrong for it.
    var impliesUserInterface: Bool {
        switch self {
        case .startMCPServer:
            return false
        case .openConnection,
             .openTable,
             .openQuery,
             .importConnection,
             .openSQLFile,
             .openDatabaseFile,
             .openInspectorFile,
             .openConnectionShare,
             .pairIntegration,
             .openDatabaseURL,
             .installPlugin,
             .reopenClosedTab:
            return true
        }
    }
}
