//
//  PreConnectScriptPrompt.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
internal struct PreConnectScriptPrompt: PreConnectScriptAsking {
    internal func ask(connectionName: String, script: String) async -> ConsentAnswer {
        await AlertHelper.askConsent(
            title: String(localized: "Pre-Connect Script"),
            message: String(
                format: String(localized: "Connection \"%@\" has a script that will run before connecting:\n\n%@"),
                connectionName, script
            ),
            confirmButton: String(localized: "Run Script"),
            window: NSApp.keyWindow
        )
    }
}
