//
//  MemoryPressureMonitor.swift
//  TableProMobile
//

import Foundation
import os

@MainActor
@Observable
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    private(set) var currentLevel: Level = .normal

    private static let logger = Logger(subsystem: "com.TablePro", category: "MemoryPressureMonitor")
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        guard source == nil else { return }

        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )

        newSource.setEventHandler { [weak self] in
            let event = newSource.data
            let level: Level = event.contains(.critical) ? .critical : .warning
            Self.logger.warning("Memory pressure event: \(String(describing: level), privacy: .public)")
            Task { @MainActor in
                self?.currentLevel = level
            }
        }

        newSource.activate()
        source = newSource
    }

    func reset() {
        currentLevel = .normal
    }

    nonisolated func availableMemoryBytes() -> Int {
        Int(os_proc_available_memory())
    }

    nonisolated func hasHeadroom(forBytes requiredBytes: Int) -> Bool {
        let available = availableMemoryBytes()
        guard available > 0 else { return true }
        return available > requiredBytes
    }
}
