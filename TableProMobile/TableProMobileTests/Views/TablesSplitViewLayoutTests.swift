import SwiftUI
@testable import TableProMobile
import Testing
import UIKit

@MainActor
@Suite("Tables split view layout")
struct TablesSplitViewLayoutTests {
    @Test("A regular width shows the table list and the browser at once, the way the inner display should")
    func regularWidthRevealsBothColumns() throws {
        let probe = ColumnProbe()
        let host = try HostedSplit(probe: probe, width: 1_024, height: 768, widthClass: .regular)
        defer { host.tearDown() }

        try host.settle()

        #expect(!probe.sidebarFrame.isEmpty)
        #expect(!probe.detailFrame.isEmpty)
        #expect(!probe.sidebarFrame.intersects(probe.detailFrame))
        #expect(probe.sidebarFrame.maxX <= probe.detailFrame.minX + 0.5)
    }

    @Test("A compact width shows one column, so the outer display keeps today's single-pane flow")
    func compactWidthCollapsesToOneColumn() throws {
        let probe = ColumnProbe()
        let host = try HostedSplit(probe: probe, width: 466, height: 678, widthClass: .compact)
        defer { host.tearDown() }

        try host.settle()

        #expect(!probe.sidebarFrame.isEmpty)
        #expect(probe.sidebarFrame.maxX > probe.detailFrame.minX)
    }
}

@MainActor
private final class ColumnProbe {
    var sidebarFrame: CGRect = .zero
    var detailFrame: CGRect = .zero
}

private struct SplitProbe: View {
    let probe: ColumnProbe

    var body: some View {
        TabView {
            Tab("Tables", systemImage: "tablecells") {
                NavigationSplitView {
                    List {
                        Text(verbatim: "albums")
                        Text(verbatim: "artists")
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        probe.sidebarFrame = $0
                    }
                } detail: {
                    NavigationStack {
                        Color.clear
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                probe.detailFrame = $0
                            }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
            Tab("Query", systemImage: "terminal") { Color.clear }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

@MainActor
private struct UnsettledLayout: Error {
    let description: String
}

@MainActor
private final class HostedSplit {
    let window: UIWindow
    private let probe: ColumnProbe
    private static let layoutTurns = 60
    private static let turnLength: TimeInterval = 0.05

    init(probe: ColumnProbe, width: CGFloat, height: CGFloat, widthClass: UIUserInterfaceSizeClass) throws {
        self.probe = probe
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let controller = UIHostingController(rootView: SplitProbe(probe: probe))
        controller.traitOverrides.horizontalSizeClass = widthClass
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    func settle() throws {
        for _ in 0 ..< Self.layoutTurns {
            window.layoutIfNeeded()
            if !probe.sidebarFrame.isEmpty {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.turnLength))
                window.layoutIfNeeded()
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.turnLength))
        }
        throw UnsettledLayout(
            description: "No sidebar in window \(window.bounds). "
                + "Sidebar \(probe.sidebarFrame), detail \(probe.detailFrame)"
        )
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
