//
//  ComposerHighlightPreferenceTests.swift
//  TableProTests
//
//  The composer draws one focus affordance, never two and never none. The highlight is a wide
//  translucent colour wash, so the two system settings that mean "not this" withdraw it, and the
//  system focus ring has to take over whenever it does, otherwise switching the highlight off
//  leaves a field with nothing at all to say it holds the keyboard.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

struct ComposerHighlightPreferenceTests {
    @Test("The highlight paints when it is on and no system setting overrides it")
    func paintsWhenEnabled() {
        #expect(ComposerHighlightPreference.paintsHighlight(
            enabled: true,
            reduceTransparency: false,
            contrast: .standard
        ))
    }

    @Test("Switching it off withdraws the highlight")
    func disabledNeverPaints() {
        #expect(!ComposerHighlightPreference.paintsHighlight(
            enabled: false,
            reduceTransparency: false,
            contrast: .standard
        ))
    }

    @Test("Reduce Transparency and Increase Contrast each withdraw it while it is still on")
    func systemSettingsOverrideEnabled() {
        #expect(!ComposerHighlightPreference.paintsHighlight(
            enabled: true,
            reduceTransparency: true,
            contrast: .standard
        ))
        #expect(!ComposerHighlightPreference.paintsHighlight(
            enabled: true,
            reduceTransparency: false,
            contrast: .increased
        ))
    }

    @Test("Neither system setting turns the highlight back on")
    func systemSettingsNeverEnable() {
        for reduceTransparency in [true, false] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                #expect(!ComposerHighlightPreference.paintsHighlight(
                    enabled: false,
                    reduceTransparency: reduceTransparency,
                    contrast: contrast
                ))
            }
        }
    }

    @Test("The two affordances are exclusive, and one of them is always present")
    func exactlyOneAffordance() {
        #expect(ComposerHighlightPreference.focusRingType(paintsHighlight: true) == .none)
        #expect(ComposerHighlightPreference.focusRingType(paintsHighlight: false) == .exterior)
    }

    @Test("The preference and the ring agree for every combination")
    func ringFollowsThePreference() {
        for enabled in [true, false] {
            for reduceTransparency in [true, false] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let paints = ComposerHighlightPreference.paintsHighlight(
                        enabled: enabled,
                        reduceTransparency: reduceTransparency,
                        contrast: contrast
                    )
                    let ring = ComposerHighlightPreference.focusRingType(paintsHighlight: paints)
                    #expect((ring == .none) == paints)
                    #expect((ring == .exterior) == !paints)
                }
            }
        }
    }
}
