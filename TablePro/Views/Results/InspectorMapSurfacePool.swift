//
//  InspectorMapSurfacePool.swift
//  TablePro
//

import AppKit
import MapKit

/// What the pool asks of a view as it changes hands. A protocol so the pool is testable on a plain
/// `NSView`, with no map.
@MainActor
internal protocol InspectorMapSurfacePooling: NSView {
    func prepareForInspectorField()
    func detachFromInspectorField()
}

/// A free list of map views for the row inspector.
///
/// The inspector reissues every field's identity when the selection changes, so each arrow key
/// builds a new map per geometry field, and MapKit frees a removed one only seconds later.
/// Measured over 42 selection changes: 1962 MB without this, 343 MB with it.
@MainActor
internal final class InspectorMapSurfacePool<Surface: InspectorMapSurfacePooling> {
    typealias Cancellation = @MainActor () -> Void
    /// Runs an action after a delay and returns how to call it off. Injected so a test fires it.
    typealias IdleTimer = @MainActor (Duration, @escaping @MainActor () -> Void) -> Cancellation

    private let idleLimit: Int
    private let idleLifetime: Duration
    private let startIdleTimer: IdleTimer
    private let makeSurface: @MainActor () -> Surface
    private var idle: [Surface] = []
    private var cancelIdleRelease: Cancellation?

    /// SwiftUI makes a field's new view before or after it dismantles the old one, measured both
    /// ways, so stepping rows needs one idle surface per geometry field on screen. A kept one
    /// holds about 45 MB, which is why the idle ones go once the stepping stops.
    init(
        idleLimit: Int = 4,
        idleLifetime: Duration = .seconds(10),
        startIdleTimer: @escaping IdleTimer = InspectorMapSurfacePool.sleepingTimer,
        makeSurface: @escaping @MainActor () -> Surface
    ) {
        self.idleLimit = idleLimit
        self.idleLifetime = idleLifetime
        self.startIdleTimer = startIdleTimer
        self.makeSurface = makeSurface
    }

    var idleCount: Int { idle.count }

    func take() -> Surface {
        let surface = idle.popLast() ?? makeSurface()
        surface.prepareForInspectorField()
        restartIdleTimer()
        return surface
    }

    func give(_ surface: Surface) {
        surface.detachFromInspectorField()
        /// Taken out here rather than left to the old host, whose own teardown can come after the
        /// surface has been handed to the next one.
        surface.removeFromSuperview()
        if idle.count < idleLimit, !idle.contains(where: { $0 === surface }) {
            idle.append(surface)
        }
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        cancelIdleRelease?()
        cancelIdleRelease = nil
        guard !idle.isEmpty else { return }
        cancelIdleRelease = startIdleTimer(idleLifetime) { [weak self] in
            self?.releaseIdle()
        }
    }

    private func releaseIdle() {
        cancelIdleRelease = nil
        idle.removeAll()
    }

    static func sleepingTimer(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Cancellation {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

extension ResultMapSurface: InspectorMapSurfacePooling {
    /// Every property is set again, not only the ones a field changes, so a surface that was last
    /// in another kind of host shows nothing of it.
    func prepareForInspectorField() {
        /// A fit made while the view still has its last frame keeps that frame's scale when the
        /// next host resizes it, measured. From an empty frame MapKit applies the fit at the new size.
        frame = .zero
        showsUserLocation = false
        showsZoomControls = true
        /// At a field's size MapKit draws no compass, so a rotated map could not be turned back.
        showsCompass = false
        isRotateEnabled = false
        isPitchEnabled = false
        isZoomEnabled = true
        isScrollEnabled = true
        yieldsScrollToEnclosingScrollView = true
        /// Gated as the result Map gates it, so both draw the same basemap on macOS 13.
        if #available(macOS 14.0, *), !showsMutedBasemap {
            preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        }
        setVisibleMapRect(.world, animated: false)
    }

    func detachFromInspectorField() {
        delegate = nil
        onClick = nil
        removeOverlays(overlays)
        removeAnnotations(annotations)
    }

    @available(macOS 14.0, *)
    private var showsMutedBasemap: Bool {
        (preferredConfiguration as? MKStandardMapConfiguration)?.emphasisStyle == .muted
    }
}

internal extension ResultMapSurface {
    static let inspectorPool = InspectorMapSurfacePool<ResultMapSurface>(makeSurface: { ResultMapSurface() })
}
