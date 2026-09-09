//
//  DiagramPaintCoverageTests.swift
//  TableProTests
//
//  Both diagrams live inside a magnifying NSScrollView, and a SwiftUI `Canvas` there stops
//  painting past `contentSize * magnification + 128` document points once the magnification
//  reaches 0.5 (#2692). These rasterise the real drawing surface at the zoom levels the app
//  actually reaches and assert that content near the far corner is on screen.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("Diagram paint coverage under magnification")
@MainActor
struct DiagramPaintCoverageTests {
    private static let canvasSize = CGSize(width: 2_400, height: 1_600)
    private static let viewportSize = CGSize(width: 1_200, height: 800)
    private static let farNodeCentre = CGPoint(x: 2_200, y: 1_400)
    private static let nearNodeCentre = CGPoint(x: 200, y: 200)

    private struct Probe {
        let scrollView: NSScrollView
        let window: NSWindow
    }

    private func makeScene() -> ERDiagramScene {
        let near = node(named: "near")
        let far = node(named: "far")
        return ERDiagramScene(
            nodes: [near, far],
            edges: [],
            nodeRects: [
                near.id: rect(centredOn: Self.nearNodeCentre),
                far.id: rect(centredOn: Self.farNodeCentre)
            ],
            nodeIndex: [near.tableName: near.id, far.tableName: far.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: Self.canvasSize
        )
    }

    private func node(named name: String) -> ERTableNode {
        let columns = [
            ERColumnDisplay(id: "\(name).id", name: "id", dataType: "integer", isPrimaryKey: true, isForeignKey: false, isNullable: false),
            ERColumnDisplay(id: "\(name).label", name: "label", dataType: "text", isPrimaryKey: false, isForeignKey: false, isNullable: true)
        ]
        return ERTableNode(id: UUID(), tableName: name, columns: columns, displayColumns: columns, clusterId: nil)
    }

    private func rect(centredOn centre: CGPoint) -> CGRect {
        let height = ERDiagramLayout.estimateHeight(columnCount: 2)
        return CGRect(
            x: centre.x - ERDiagramLayout.nodeWidth / 2,
            y: centre.y - height / 2,
            width: ERDiagramLayout.nodeWidth,
            height: height
        )
    }

    private func makeProbe(documentView: NSView, magnification: CGFloat) -> Probe {
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: Self.viewportSize))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .systemBlue
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = documentView

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.viewportSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(scrollView)

        scrollView.magnification = magnification
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        return Probe(scrollView: scrollView, window: window)
    }

    /// Samples the viewport where a document point lands. The scroll is pinned at the origin, so a
    /// document point is simply scaled by the magnification.
    ///
    /// `grounds` are the colours that count as "nothing drawn here". The scroll view's own
    /// background is always one of them; a document that fills itself has to name its fill too, or
    /// the assertion passes on the fill alone and never sees whether the content was drawn.
    private func isPainted(
        _ documentPoint: CGPoint,
        in probe: Probe,
        magnification: CGFloat,
        grounds: [NSColor] = [.systemBlue]
    ) -> Bool {
        let scrollView = probe.scrollView
        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else { return false }
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / scrollView.bounds.width
        let x = Int((documentPoint.x * magnification * scale).rounded())
        let y = Int((documentPoint.y * magnification * scale).rounded())
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return false }
        guard let sampled = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }

        return grounds.allSatisfy { ground in
            guard let ground = ground.usingColorSpace(.sRGB) else { return true }
            let distance = abs(sampled.redComponent - ground.redComponent)
                + abs(sampled.greenComponent - ground.greenComponent)
                + abs(sampled.blueComponent - ground.blueComponent)
            return distance > 0.1
        }
    }

    private func makeDiagramView(_ scene: ERDiagramScene) -> ERDiagramSceneView {
        let view = ERDiagramSceneView(frame: CGRect(origin: .zero, size: scene.size))
        view.scene = scene
        return view
    }

    /// Every magnification here is low enough to put the far node inside the viewport, which is
    /// exactly the range where the old drawing surface stopped painting: at 0.41 it gave up at
    /// document x 1112, and the far node sits at 2200.
    @Test(
        "The ER diagram paints its far corner at every zoom that can show it",
        arguments: [DiagramZoom.minimum, 0.1, 0.33, 0.41, 0.5]
    )
    func erDiagramPaintsWholeCanvas(magnification: CGFloat) {
        let scene = makeScene()
        let probe = makeProbe(documentView: makeDiagramView(scene), magnification: magnification)

        #expect(isPainted(Self.nearNodeCentre, in: probe, magnification: magnification))
        #expect(isPainted(Self.farNodeCentre, in: probe, magnification: magnification))
    }

    @Test("The ER diagram still paints at natural scale")
    func erDiagramPaintsAtNaturalScale() {
        let scene = makeScene()
        let probe = makeProbe(documentView: makeDiagramView(scene), magnification: 1.0)

        #expect(isPainted(Self.nearNodeCentre, in: probe, magnification: 1.0))
    }

    @Test("The query plan paints its arrows at every zoom the app can reach", arguments: [DiagramZoom.minimum, 0.41])
    func queryPlanPaintsArrows(magnification: CGFloat) {
        let arrow = QueryPlanDiagramLayout.Arrow(
            id: UUID(),
            start: CGPoint(x: 40, y: 40),
            end: CGPoint(x: 2_200, y: 1_400),
            control1: CGPoint(x: 40, y: 720),
            control2: CGPoint(x: 2_200, y: 720),
            head: [
                CGPoint(x: 2_200, y: 1_400),
                CGPoint(x: 2_120, y: 1_280),
                CGPoint(x: 2_280, y: 1_280)
            ]
        )
        let hosting = NSHostingView(
            rootView: QueryPlanArrowsView(arrows: [arrow], size: Self.canvasSize)
                .background(Color.white)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = CGRect(origin: .zero, size: Self.canvasSize)

        let probe = makeProbe(documentView: hosting, magnification: magnification)
        let grounds: [NSColor] = [.systemBlue, .white]

        #expect(isPainted(CGPoint(x: 2_200, y: 1_330), in: probe, magnification: magnification, grounds: grounds))
        #expect(!isPainted(CGPoint(x: 1_200, y: 100), in: probe, magnification: magnification, grounds: grounds))
    }
}
