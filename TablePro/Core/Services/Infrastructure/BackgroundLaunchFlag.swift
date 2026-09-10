//
//  BackgroundLaunchFlag.swift
//  TablePro
//

import Foundation

/// The one spelling of the flag the `tablepro-mcp` bridge sets when it starts the app to answer a
/// client, and the app reads before `NSApplicationMain`. Two processes have to agree on it, so it is
/// compiled into both targets rather than written out twice.
///
/// Measured on macOS 26: `/usr/bin/open` passes its own environment through to the app it launches,
/// for `open -g "scheme://…"` as well as `open -a`. A macOS that stopped doing that would cost the
/// app nothing but the brief Dock icon this exists to avoid, because the launch intents reach the
/// same conclusion a moment later.
internal enum BackgroundLaunchFlag {
    internal static let variable = "TABLEPRO_BACKGROUND_LAUNCH"
    internal static let value = "1"

    internal static func isSet(in environment: [String: String]) -> Bool {
        environment[variable] == value
    }
}
