//
//  DiagramScrollZoom.swift
//  TablePro
//
//  Decides whether a scroll over a diagram zooms it, and by how much.
//

import AppKit

struct DiagramScrollZoom {
    struct Input: Equatable {
        var modifierFlags: NSEvent.ModifierFlags
        var phase: NSEvent.Phase
        var momentumPhase: NSEvent.Phase
        var scrollingDeltaY: CGFloat
        var hasPreciseScrollingDeltas: Bool
        var isDirectionInvertedFromDevice: Bool
    }

    enum Intent: Equatable {
        case zoom(factor: CGFloat)
        case scroll
        case ignore
    }

    /// A wheel reports whole lines and a trackpad reports points. Ten points is `NSScrollView`'s own
    /// line scroll, so one notch zooms as far as the same travel on a trackpad.
    static let pointsPerLine: CGFloat = 10

    /// macOS accelerates a fast wheel spin into events of ten lines or more, and a zoom that
    /// compounds every one of them jumps from a table to the whole schema in a flick.
    static let maximumPointsPerEvent: CGFloat = 30

    static let exponentPerPoint: CGFloat = 0.01

    /// Caps Lock, Fn and the keypad flag sit in `deviceIndependentFlagsMask` too, and none of them
    /// is a chord, so an equality test against that mask would stop zooming whenever Caps Lock is on.
    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// A trackpad scroll is one gesture of many events, and the Command key is read once, when it
    /// begins, so pressing or releasing Command halfway neither starts nor stops a zoom mid-swipe.
    private(set) var isZoomGesture = false

    mutating func intent(for input: Input) -> Intent {
        if !input.momentumPhase.isEmpty {
            return isZoomGesture ? .ignore : .scroll
        }

        if input.phase.isEmpty {
            return Self.isZoomChord(input.modifierFlags) ? .zoom(factor: Self.factor(for: input)) : .scroll
        }

        if !input.phase.isDisjoint(with: [.began, .mayBegin]) {
            isZoomGesture = Self.isZoomChord(input.modifierFlags)
        }
        return isZoomGesture ? .zoom(factor: Self.factor(for: input)) : .scroll
    }

    static func isZoomChord(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(chordModifiers) == .command
    }

    /// Exponential, so a notch in and a notch out land back on the same magnification, and the
    /// physical direction decides it: moving the wheel or the fingers away from you zooms in
    /// whichever way natural scrolling is set.
    static func factor(for input: Input) -> CGFloat {
        let points = input.hasPreciseScrollingDeltas ? input.scrollingDeltaY : input.scrollingDeltaY * pointsPerLine
        guard points.isFinite else { return 1 }
        let physical = input.isDirectionInvertedFromDevice ? -points : points
        let bounded = min(maximumPointsPerEvent, max(-maximumPointsPerEvent, physical))
        return exp(bounded * exponentPerPoint)
    }
}

extension DiagramScrollZoom.Input {
    init(_ event: NSEvent) {
        self.init(
            modifierFlags: event.modifierFlags,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
    }
}
