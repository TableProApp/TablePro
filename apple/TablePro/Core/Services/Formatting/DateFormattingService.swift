//
//  DateFormattingService.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class DateFormattingService {
    static let shared = DateFormattingService()

    // Replaced on a format change rather than reconfigured, so no text cached under the old format survives.
    private(set) var renderer: DateDisplayRenderer

    private var systemTimeZoneObserver: NSObjectProtocol?

    // Rises each time the Mac's zone moves, so a display cache built in the old one compares unequal and
    // is replaced rather than repaired.
    private(set) var systemTimeZoneGeneration = 0

    var currentFormat: DateFormatOption { renderer.format }

    // AppSettingsManager sets the user's format once it has loaded.
    private init() {
        renderer = DateDisplayRenderer(format: .iso8601)
        observeSystemTimeZone()
    }

    // `NSSystemTimeZoneDidChange` documents no posting thread, and this app has already shipped a crash
    // from assuming one, so the observer names the main queue and hops explicitly.
    private func observeSystemTimeZone() {
        systemTimeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DateFormattingService.shared.systemTimeZoneGeneration += 1
                AppEvents.shared.systemTimeZoneChanged.send(())
            }
        }
    }

    func updateFormat(_ format: DateFormatOption) {
        guard format != currentFormat else { return }
        renderer = DateDisplayRenderer(format: format)
    }

    func format(_ date: Date) -> String {
        renderer.format(date)
    }

    func format(dateString: String, columnType: ColumnType? = nil) -> String? {
        renderer.format(dateString: dateString, columnType: columnType)
    }
}
