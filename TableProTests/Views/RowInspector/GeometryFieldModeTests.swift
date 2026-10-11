//
//  GeometryFieldModeTests.swift
//  TableProTests
//
//  Which segment a geometry field opens on, and what may move it afterwards. The mode is decided
//  once per field and then belongs to the picker: a mode that followed the text would take the
//  editor away from the caret the moment a typed value became drawable.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct GeometryFieldModeTests {
    private typealias Mode = GeometryFieldView.Mode
    private typealias ModeLatch = GeometryFieldView.ModeLatch

    private func preview(of text: String) -> GeometryFieldPreview {
        GeometryFieldPreview.make(text: text, source: .spatialColumn, state: .value(text))
    }

    private var drawable: GeometryFieldPreview {
        preview(of: "SRID=4326;POINT(-122.4194 37.7749)")
    }

    @Test("The fixture point is drawable")
    func fixtureIsDrawable() {
        guard case .drawable = drawable else {
            Issue.record("The fixture must draw, got \(drawable)")
            return
        }
    }

    // MARK: - The opening mode

    @Test("A drawable value opens on Map")
    func drawableOpensOnMap() {
        #expect(Mode.opening(preferred: .map, preview: drawable) == .map)
    }

    @Test("A value the map cannot draw opens on Text")
    func undrawableOpensOnText() {
        #expect(Mode.opening(preferred: .map, preview: .unavailable(.null)) == .text)
        #expect(Mode.opening(preferred: .map, preview: .unavailable(.multipleValues)) == .text)
        #expect(Mode.opening(preferred: .map, preview: preview(of: "POINT(1")) == .text)
        #expect(Mode.opening(preferred: .map, preview: preview(of: "SRID=27700;POINT(530000 180000)")) == .text)
    }

    @Test("The Text preference opens every field on Text")
    func textPreferenceWins() {
        #expect(Mode.opening(preferred: .text, preview: drawable) == .text)
        #expect(Mode.opening(preferred: .text, preview: nil) == .text)
    }

    @Test("A value still being read decides nothing")
    func unreadValueDecidesNothing() {
        #expect(Mode.opening(preferred: .map, preview: nil) == nil)
    }

    /// The preference is stored under these spellings, so renaming a case would reset it.
    @Test("The stored preference keeps its spelling")
    func storedSpelling() {
        #expect(Mode.text.rawValue == "text")
        #expect(Mode.map.rawValue == "map")
    }

    // MARK: - The latch

    @Test("Typing a drawable value into a NULL field leaves it on Text")
    func typingNeverMovesAFieldToMap() {
        var latch = ModeLatch()
        latch.offer(preferred: .map, preview: .unavailable(.null))
        #expect(latch.mode == .text)

        latch.offer(preferred: .map, preview: drawable)
        #expect(latch.mode == .text)
        #expect(latch.shown(preferred: .map, preview: drawable) == .text)
    }

    @Test("A value that stops reading leaves the field on Map")
    func anUnreadableEditKeepsTheMap() {
        var latch = ModeLatch()
        latch.offer(preferred: .map, preview: drawable)
        #expect(latch.mode == .map)

        let broken = preview(of: "SRID=4326;POINT(-122.4194")
        latch.offer(preferred: .map, preview: broken)
        #expect(latch.shown(preferred: .map, preview: broken) == .map)
    }

    @Test("The picker moves a latched field")
    func thePickerMovesTheMode() {
        var latch = ModeLatch()
        latch.offer(preferred: .map, preview: .unavailable(.null))
        latch.choose(.map)
        #expect(latch.shown(preferred: .map, preview: .unavailable(.null)) == .map)

        latch.choose(.text)
        #expect(latch.shown(preferred: .map, preview: drawable) == .text)
    }

    /// The preference is shared, so a choice made on one field is seen by every other one.
    @Test("A choice made on another field does not move this one")
    func anotherFieldsChoiceIsIgnored() {
        var latch = ModeLatch()
        latch.offer(preferred: .map, preview: drawable)
        #expect(latch.shown(preferred: .text, preview: drawable) == .map)
    }

    @Test("A large value shows Map while it is first read, then follows the read")
    func aLargeValueWaitsForItsFirstRead() {
        var latch = ModeLatch()
        latch.offer(preferred: .map, preview: nil)
        #expect(latch.mode == nil)
        #expect(latch.shown(preferred: .map, preview: nil) == .map)

        latch.offer(preferred: .map, preview: .unavailable(.unreadable))
        #expect(latch.mode == .text)
    }

    // MARK: - The window

    /// The map window takes the text alone, so a NULL field or several values would open on
    /// "not in a format the map can read".
    @Test("Map mode opens the window only for a value that draws")
    func mapModeOpensTheWindowOnlyWhenDrawable() {
        #expect(GeometryFieldView.canOpenWindow(in: .map, preview: drawable))
        #expect(!GeometryFieldView.canOpenWindow(in: .map, preview: .unavailable(.null)))
        #expect(!GeometryFieldView.canOpenWindow(in: .map, preview: .unavailable(.multipleValues)))
        #expect(!GeometryFieldView.canOpenWindow(in: .map, preview: .unavailable(.unsupportedType("TIN"))))
        #expect(!GeometryFieldView.canOpenWindow(in: .map, preview: nil))
    }

    @Test("Text mode's window does not wait on the map")
    func textModeWindowIgnoresThePreview() {
        #expect(GeometryFieldView.canOpenWindow(in: .text, preview: nil))
        #expect(GeometryFieldView.canOpenWindow(in: .text, preview: .unavailable(.null)))
    }

    @Test("A field on Text never needs its value read")
    func textModeReadsNothing() {
        var latch = ModeLatch()
        #expect(latch.needsPreview(preferred: .map))
        #expect(latch.needsPreview(preferred: .text) == false)

        latch.choose(.text)
        #expect(latch.needsPreview(preferred: .map) == false)

        latch.choose(.map)
        #expect(latch.needsPreview(preferred: .text))
    }
}
