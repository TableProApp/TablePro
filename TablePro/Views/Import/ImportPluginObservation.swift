//
//  ImportPluginObservation.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// Relays an import plugin's own changes to the import sheet.
///
/// The sheet shows the plugin's options view, which observes the plugin, but the sheet reaches the
/// plugin through `PluginManager`, and nothing `PluginManager` publishes changes when an option
/// does. Measured: a new option redrew the options view and not the sheet, so the sheet never read
/// the new `fieldDetectionSignature` and kept the fields read for the old options.
@MainActor
internal final class ImportPluginObservation: ObservableObject {
    private var subscription: AnyCancellable?

    internal init(plugin: (any ImportFormatPlugin)?) {
        guard let observable = plugin as? any ObservableObject else { return }
        subscription = Self.changes(of: observable)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    private static func changes(of object: some ObservableObject) -> AnyPublisher<Void, Never> {
        object.objectWillChange.map { _ in }.eraseToAnyPublisher()
    }
}
