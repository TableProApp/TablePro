//
//  ExportProgressProxy.swift
//  TablePro
//

import Foundation
import Observation

@MainActor @Observable
final class ExportProgressProxy {
    private(set) var fractionCompleted: Double = 0
    private(set) var localizedDescription: String = ""
    private(set) var localizedAdditionalDescription: String = ""
    private(set) var isCancelled: Bool = false
    private(set) var isIndeterminate: Bool = true

    private var fractionObservation: NSKeyValueObservation?
    private var descriptionObservation: NSKeyValueObservation?
    private var additionalDescriptionObservation: NSKeyValueObservation?
    private var cancelledObservation: NSKeyValueObservation?

    func observe(_ progress: Progress) {
        fractionObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? 0
            Task { @MainActor [weak self] in
                self?.fractionCompleted = value
                self?.isIndeterminate = progress.totalUnitCount <= 0
            }
        }
        descriptionObservation = progress.observe(\.localizedDescription, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? ""
            Task { @MainActor [weak self] in
                self?.localizedDescription = value
            }
        }
        additionalDescriptionObservation = progress.observe(\.localizedAdditionalDescription, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? ""
            Task { @MainActor [weak self] in
                self?.localizedAdditionalDescription = value
            }
        }
        cancelledObservation = progress.observe(\.isCancelled, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.isCancelled = value
            }
        }
    }

    func stop() {
        fractionObservation?.invalidate()
        descriptionObservation?.invalidate()
        additionalDescriptionObservation?.invalidate()
        cancelledObservation?.invalidate()
        fractionObservation = nil
        descriptionObservation = nil
        additionalDescriptionObservation = nil
        cancelledObservation = nil
    }

    nonisolated deinit {}
}
