//
//  ImportDetectionSignatureObserver.swift
//  TablePro
//

import Combine
import SwiftUI
import TableProPluginKit

/// The options are edited in the plugin's own view, and the sheet around it observes only the plugin
/// manager, which publishes nothing when a plugin's settings change.
struct ImportDetectionSignatureObserver<Plugin: ImportFormatPlugin & ObservableObject>: View {
    @ObservedObject var plugin: Plugin
    let onChange: (String) -> Void

    var body: some View {
        Color.clear
            .onAppear { onChange(plugin.fieldDetectionSignature) }
            .onChange(of: plugin.fieldDetectionSignature) { signature in
                onChange(signature)
            }
    }
}

enum ImportDetectionSignatureObservation {
    @MainActor
    static func observer(
        for plugin: (any ImportFormatPlugin)?,
        onChange: @escaping (String) -> Void
    ) -> AnyView? {
        guard let observable = plugin as? any ImportFormatPlugin & ObservableObject else { return nil }
        return makeObserver(for: observable, onChange: onChange)
    }

    @MainActor
    private static func makeObserver<Plugin: ImportFormatPlugin & ObservableObject>(
        for plugin: Plugin,
        onChange: @escaping (String) -> Void
    ) -> AnyView {
        AnyView(ImportDetectionSignatureObserver(plugin: plugin, onChange: onChange))
    }
}
