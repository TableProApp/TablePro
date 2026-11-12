import Combine
import Foundation
import SwiftUI
@testable import TablePro
import TableProEditorKit
import Testing

// The query editor binds its caret to `$coordinator.cursorPositions`. Every view in the main window observes the
// coordinator, so a publish per caret move re-rendered the window on each arrow key.
@MainActor
struct MainContentCoordinatorCaretPublishTests {
    @Test("Moving the caret writes through the editor's binding without publishing the coordinator")
    func caretMoveDoesNotPublish() {
        let fixture = CoordinatorFixture()
        var publishes = 0
        let subscription = fixture.coordinator.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        let binding = ObservedObject(wrappedValue: fixture.coordinator).projectedValue.cursorPositions
        for offset in 0..<20 {
            binding.wrappedValue = [CursorPosition(range: NSRange(location: offset, length: 0))]
        }

        #expect(publishes == 0)
        #expect(fixture.coordinator.cursorPositions.map { $0.range } == [NSRange(location: 19, length: 0)])
    }
}
