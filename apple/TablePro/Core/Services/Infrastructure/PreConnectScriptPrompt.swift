//
//  PreConnectScriptPrompt.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
internal struct PreConnectScriptPrompt: PreConnectScriptAsking {
    internal func ask(connectionName: String, script: String, postDisconnectScript: String?) async -> ConsentAnswer {
        await AlertHelper.askConsent(
            title: String(localized: "Pre-Connect Script"),
            message: Self.message(
                connectionName: connectionName,
                script: script,
                postDisconnectScript: postDisconnectScript
            ),
            confirmButton: String(localized: "Run Script"),
            window: NSApp.keyWindow
        )
    }

    internal static func message(connectionName: String, script: String, postDisconnectScript: String?) -> String {
        let preConnect = String(
            format: String(localized: "Connection \"%@\" has a script that will run before connecting:\n\n%@"),
            connectionName, script
        )
        guard let postDisconnectScript else { return preConnect }
        let postDisconnect = String(
            format: String(localized: "And one that will run after this session ends:\n\n%@"),
            postDisconnectScript
        )
        return preConnect + "\n\n" + postDisconnect
    }
}
