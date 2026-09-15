import XCTest
@testable import CodeEditSourceEditor
@testable import CodeEditTextView
import CodeEditLanguages
import AppKit

private var pendingTextStore: [ObjectIdentifier: String] = [:]
private var pendingMinimapStore: [ObjectIdentifier: Bool] = [:]

extension TextViewController {
    var pendingText: String {
        get { pendingTextStore[ObjectIdentifier(self)] ?? "" }
        set { pendingTextStore[ObjectIdentifier(self)] = newValue }
    }

    var pendingShowMinimap: Bool {
        get { pendingMinimapStore[ObjectIdentifier(self)] ?? false }
        set { pendingMinimapStore[ObjectIdentifier(self)] = newValue }
    }
}

final class ZZProbeDormantCostTests: XCTestCase {
    private func makeController(showMinimap: Bool, text: String) -> TextViewController {
        let theme = Mock.theme()
        let controller = Mock.textViewController(theme: theme)
        controller.pendingText = text
        controller.pendingShowMinimap = showMinimap
        return controller
    }

    private func mount(_ controller: TextViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        controller.setText(controller.pendingText)
        controller.configuration.peripherals = .init(
            showGutter: true,
            showMinimap: controller.pendingShowMinimap,
            showReformattingGuide: false,
            showFoldingRibbon: false
        )
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    func test_probe_minimapViewCount() {
        let text = String(repeating: "SELECT id, name FROM users WHERE created_at > now();\n", count: 2000)
        let controller = makeController(showMinimap: false, text: text)
        let window = mount(controller)
        _ = window

        print("PROBE-MINIMAP hidden=\(controller.minimapView.isHidden) width=\(controller.minimapView.frame.width)")
        print("PROBE-MINIMAP hasLayoutManager=\(controller.minimapView.layoutManager != nil)")
        print("PROBE-MINIMAP hasSelectionManager=\(controller.minimapView.selectionManager != nil)")
        print("PROBE-MINIMAP lineCount=\(controller.minimapView.layoutManager?.lineCount ?? -1)")
        print("PROBE-MINIMAP processesEdits=\(controller.minimapView.layoutManager?.processesEdits ?? false)")
        print("PROBE-REFORMAT hidden=\(controller.reformattingGuideView.isHidden)")
        print("PROBE-REFORMAT superview=\(controller.reformattingGuideView.superview != nil)")

        var subviews = 0
        func walk(_ view: NSView) {
            subviews += 1
            view.subviews.forEach(walk)
        }
        walk(controller.minimapView)
        print("PROBE-MINIMAP subtreeViewCount=\(subviews)")
    }

    func test_probe_constructionCost() {
        let text = String(repeating: "SELECT id, name FROM users WHERE created_at > now();\n", count: 2000)

        // warm
        _ = mount(makeController(showMinimap: false, text: text))

        var minimapInit: TimeInterval = 0
        var controllers: [TextViewController] = []
        var windows: [NSWindow] = []
        for _ in 0..<5 {
            let controller = makeController(showMinimap: false, text: text)
            let clock = Date()
            let window = mount(controller)
            minimapInit += Date().timeIntervalSince(clock)
            controllers.append(controller)
            windows.append(window)
        }
        print(String(format: "PROBE-LOADVIEW total(5 editors)=%.1fms", minimapInit * 1000))

        // Isolate the minimap's own construction over the same storage.
        let host = controllers[0]
        var direct: TimeInterval = 0
        for _ in 0..<5 {
            let clock = Date()
            let minimap = MinimapView(textView: host.textView, theme: Mock.theme())
            direct += Date().timeIntervalSince(clock)
            _ = minimap
        }
        print(String(format: "PROBE-MINIMAP-INIT total(5)=%.1fms", direct * 1000))
    }

    func test_probe_eventMonitorMask() {
        let controller = makeController(showMinimap: false, text: "SELECT 1;")
        _ = mount(controller)
        print("PROBE-MONITOR hasLocalMonitor=\(controller.localEventMonitor != nil)")
        print("PROBE-JUMP delegateIsNil=\(controller.jumpToDefinitionDelegate == nil)")
    }
}
