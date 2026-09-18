//
//  MotionAccessibilityTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@Suite("Motion accessibility")
struct MotionAccessibilityTests {
    @Test("Reduce Motion drops the animation")
    func reduceMotionDropsAnimation() {
        #expect(MotionAccessibility.animation(.easeOut(duration: 0.2), reduceMotion: true) == nil)
    }

    @Test("Without Reduce Motion the animation is kept")
    func animationSurvives() {
        #expect(MotionAccessibility.animation(.easeOut(duration: 0.2), reduceMotion: false) != nil)
    }

    @Test("A nil animation stays nil either way")
    func nilStaysNil() {
        #expect(MotionAccessibility.animation(nil, reduceMotion: false) == nil)
        #expect(MotionAccessibility.animation(nil, reduceMotion: true) == nil)
    }

    @Test("The gate is not inverted")
    func gateIsNotInverted() {
        let reduced = MotionAccessibility.animation(.default, reduceMotion: true)
        let normal = MotionAccessibility.animation(.default, reduceMotion: false)
        #expect(reduced == nil)
        #expect(normal == .default)
    }
}
