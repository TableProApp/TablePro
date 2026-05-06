//
//  MemoryPressureMonitor.swift
//  TableProMobile
//

import Foundation
import os

@MainActor
@Observable
public final class MemoryPressureMonitor {
    public static let shared = MemoryPressureMonitor()

    public enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    public private(set) var currentLevel: Level = .normal

    private static let logger = Logger(subsystem: "com.TablePro", category: "MemoryPressureMonitor")
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    public func start() {
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

    public func reset() {
        currentLevel = .normal
    }

    nonisolated public func availableMemoryBytes() -> Int {
        Int(os_proc_available_memory())
    }

    nonisolated public func hasHeadroom(forBytes requiredBytes: Int) -> Bool {
        let available = availableMemoryBytes()
        guard available > 0 else { return true }
        return available > requiredBytes
    }
}
