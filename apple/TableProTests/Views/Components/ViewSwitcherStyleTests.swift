import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct ViewSwitcherStyleTests {
    private enum Mode: Hashable {
        case first
        case second
    }

    private struct Switcher: View {
        @State private var mode = Mode.first

        var body: some View {
            Picker(selection: $mode) {
                Text(verbatim: "First").tag(Mode.first)
                Text(verbatim: "Second").tag(Mode.second)
            } label: {
                Text(verbatim: "Mode")
            }
            .labelsHidden()
            .fixedSize()
            .viewSwitcherStyle()
        }
    }

    @Test("A view switcher is small, with the tabs role on macOS 27")
    func smallWithTabsRoleOnMacOS27() throws {
        let (host, control) = try hostedControl()
        #expect(control.controlSize == .small)
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            #expect(control.role == .tabs)
        }
        #endif
        withExtendedLifetime(host) {}
    }

    /// Measured on macOS 27, the tabs role turns the radio group into a tab group, but each segment
    /// is still a radio button named by its label, which is what a UI test clicks.
    @Test("Each segment stays a radio button named by its label")
    func segmentsStayNamedRadioButtons() throws {
        let (host, control) = try hostedControl()
        var labels: [String] = []
        func collect(_ element: Any, depth: Int) {
            guard depth < 4, let object = element as? NSObject else { return }
            if (object.value(forKey: "accessibilityRole") as? String) == NSAccessibility.Role.radioButton.rawValue,
               let label = object.value(forKey: "accessibilityLabel") as? String {
                labels.append(label)
            }
            for child in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
                collect(child, depth: depth + 1)
            }
        }
        collect(control, depth: 0)

        #expect(labels == ["First", "Second"])
        withExtendedLifetime(host) {}
    }

    private func hostedControl() throws -> (NSHostingView<Switcher>, NSSegmentedControl) {
        let host = NSHostingView(rootView: Switcher())
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        host.layoutSubtreeIfNeeded()
        let control = try #require(segmentedControls(in: host).first)
        return (host, control)
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        let own = (view as? NSSegmentedControl).map { [$0] } ?? []
        return own + view.subviews.flatMap { segmentedControls(in: $0) }
    }
}
