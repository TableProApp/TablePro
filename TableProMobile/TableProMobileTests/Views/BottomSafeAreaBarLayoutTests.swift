import SwiftUI
@testable import TableProMobile
import Testing
import UIKit

@MainActor
@Suite("Bottom safe area bar layout")
struct BottomSafeAreaBarLayoutTests {
    @Test("A bar placed on a tab's content clears the tab bar and takes its own touches")
    func barClearsTheTabBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let probe = LayoutProbe()
        let host = try HostedTree(probe: probe, variant: .bar)
        defer { host.tearDown() }

        let tabBar = try host.settledTabBar()
        let marker = probe.markerFrame

        #expect(!marker.isEmpty)
        #expect(!marker.intersects(tabBar.convert(tabBar.bounds, to: host.window)))
        let hit = host.window.hitTest(CGPoint(x: marker.midX, y: marker.midY), with: nil)
        #expect(hit.map { !$0.isDescendant(of: tabBar) } ?? false)
    }

    @Test("A hidden bar leaves no blank strip above the tab bar")
    func emptyBarAddsNoInset() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let emptyProbe = LayoutProbe()
        let emptyHost = try HostedTree(probe: emptyProbe, variant: .emptyBar)
        defer { emptyHost.tearDown() }
        _ = try emptyHost.settledTabBar()

        let plainProbe = LayoutProbe()
        let plainHost = try HostedTree(probe: plainProbe, variant: .noBar)
        defer { plainHost.tearDown() }
        _ = try plainHost.settledTabBar()

        #expect(emptyProbe.listInsets.bottom == plainProbe.listInsets.bottom)
    }
}

@MainActor
private final class LayoutProbe {
    var markerFrame: CGRect = .zero
    var listInsets = EdgeInsets()
}

private struct UnsettledLayout: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private struct HostedTree {
    enum Variant {
        case bar
        case emptyBar
        case noBar
    }

    private static let layoutTurns = 300
    private static let turnLength: TimeInterval = 0.01

    let window: UIWindow
    let probe: LayoutProbe

    init(probe: LayoutProbe, variant: Variant) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        window = UIWindow(windowScene: scene)
        self.probe = probe
        window.rootViewController = UIHostingController(rootView: ProbeTabs(probe: probe, variant: variant))
        window.makeKeyAndVisible()
    }

    /// Drives the layout from this thread instead of waiting to be scheduled again.
    ///
    /// SwiftUI reports a geometry change on a later run-loop turn, so the tree needs the run loop
    /// to reach its final size. Awaiting that change costs the test its turn on the main actor, and
    /// the whole suite runs there: on CI both cases in this file spent a full minute waiting and
    /// were killed by the execution time allowance, which took the test host down with them and
    /// left 284 later tests unrun. Running the run loop here keeps the main thread, so progress
    /// never depends on the scheduler, and the bound is a number of turns rather than a clock.
    func settledTabBar() throws -> UITabBar {
        for _ in 0 ..< Self.layoutTurns {
            window.layoutIfNeeded()
            if let tabBar = visibleTabBar(in: window), isSettled(against: tabBar) {
                return tabBar
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.turnLength))
        }
        throw UnsettledLayout(description: layoutReport())
    }

    private func layoutReport() -> String {
        guard let tabBar = visibleTabBar(in: window) else {
            return "No visible tab bar. List insets \(probe.listInsets), marker \(probe.markerFrame)"
        }
        let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
        return "The list's bottom inset \(probe.listInsets.bottom) never covered the tab bar band "
            + "\(window.bounds.maxY - tabBarFrame.minY). Window \(window.bounds), tab bar \(tabBarFrame), "
            + "marker \(probe.markerFrame), list insets \(probe.listInsets)"
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func isSettled(against tabBar: UITabBar) -> Bool {
        let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
        guard !tabBarFrame.isEmpty else { return false }
        let tabBarBand = window.bounds.maxY - tabBarFrame.minY
        return probe.listInsets.bottom >= tabBarBand - 0.5
    }

    private func visibleTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar, !tabBar.isHidden, tabBar.alpha > 0.01 {
            return tabBar
        }
        for subview in view.subviews {
            if let found = visibleTabBar(in: subview) {
                return found
            }
        }
        return nil
    }
}

private struct ProbeTabs: View {
    let probe: LayoutProbe
    let variant: HostedTree.Variant

    var body: some View {
        TabView {
            Tab("Tables", systemImage: "tablecells") {
                NavigationStack {
                    content
                        .navigationTitle("Rows")
                }
            }
            Tab("Query", systemImage: "terminal") {
                Text(verbatim: "Query")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @ViewBuilder
    private var content: some View {
        switch variant {
        case .bar:
            rows.bottomSafeAreaBar { marker }
        case .emptyBar:
            rows.bottomSafeAreaBar {
                if variant == .bar {
                    marker
                }
            }
        case .noBar:
            rows
        }
    }

    private var rows: some View {
        List(0..<50, id: \.self) { index in
            Text(verbatim: "Row \(index)")
        }
        .onGeometryChange(for: EdgeInsets.self) { proxy in
            proxy.safeAreaInsets
        } action: { insets in
            probe.listInsets = insets
        }
    }

    private var marker: some View {
        Color.red
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                probe.markerFrame = frame
            }
    }
}
