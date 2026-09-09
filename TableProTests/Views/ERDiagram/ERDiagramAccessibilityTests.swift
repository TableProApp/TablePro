//
//  ERDiagramAccessibilityTests.swift
//  TableProTests
//
//  The diagram used to publish one image element for the whole schema, so VoiceOver announced a
//  count and stopped. These pin the per-table tree and the frames it reports, which are the part
//  that silently goes wrong: a frame written in the wrong space lands the cursor on another table.
//

import AppKit
@testable import TablePro
import Testing

@Suite("ER diagram accessibility")
@MainActor
struct ERDiagramAccessibilityTests {
    private func column(_ name: String, primaryKey: Bool = false, foreignKey: Bool = false) -> ERColumnDisplay {
        ERColumnDisplay(
            id: "c.\(name)",
            name: name,
            dataType: "integer",
            isPrimaryKey: primaryKey,
            isForeignKey: foreignKey,
            isNullable: !primaryKey
        )
    }

    private func node(_ name: String, columns: [ERColumnDisplay]) -> ERTableNode {
        ERTableNode(id: UUID(), tableName: name, columns: columns, displayColumns: columns, clusterId: nil)
    }

    private func makeScene() -> ERDiagramScene {
        let employees = node("employees", columns: [column("id", primaryKey: true), column("company_id", foreignKey: true)])
        let organization = node("organization", columns: [column("id", primaryKey: true)])
        let edge = EREdge(
            id: UUID(),
            fkName: "fk_company",
            fromTable: "employees",
            fromColumn: "company_id",
            toTable: "organization",
            toColumn: "id",
            cardinality: .zeroOrManyToOne
        )
        return ERDiagramScene(
            nodes: [employees, organization],
            edges: [edge],
            nodeRects: [
                employees.id: CGRect(x: 40, y: 40, width: ERDiagramLayout.nodeWidth, height: 80),
                organization.id: CGRect(x: 400, y: 300, width: ERDiagramLayout.nodeWidth, height: 60)
            ],
            nodeIndex: ["employees": employees.id, "organization": organization.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: CGSize(width: 800, height: 600)
        )
    }

    private func makeView(_ scene: ERDiagramScene, magnification: CGFloat = 1.0) -> (ERDiagramSceneView, NSScrollView) {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum

        let view = ERDiagramSceneView(frame: CGRect(origin: .zero, size: scene.size))
        view.scene = scene
        scrollView.documentView = view

        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 100, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(scrollView)
        scrollView.magnification = magnification
        window.layoutIfNeeded()
        return (view, scrollView)
    }

    @Test("The canvas publishes one element per table instead of a single image")
    func publishesOneElementPerTable() {
        let scene = makeScene()
        let (view, _) = makeView(scene)

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .layoutArea)
        #expect(view.accessibilityLabel() == "2 tables, 1 relationships")

        let children = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        #expect(children.count == 2)
        #expect(Set(children.compactMap { $0.accessibilityLabel() }) == ["employees", "organization"])
        #expect(children.allSatisfy { $0.accessibilityRole() == .layoutItem })
    }

    @Test("A table reads its column count and what it is joined to")
    func tableCarriesItsSummary() {
        let scene = makeScene()
        let (view, _) = makeView(scene)
        let children = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        let employees = children.first { $0.accessibilityLabel() == "employees" }
        let organization = children.first { $0.accessibilityLabel() == "organization" }

        #expect(employees?.accessibilityValue() as? String == "2 columns")
        #expect(employees?.accessibilityHelp() == "references organization")
        #expect(organization?.accessibilityHelp() == "referenced by employees")
    }

    @Test("A table's columns are reachable, with their type and key role")
    func columnsAreReachable() {
        let scene = makeScene()
        let (view, _) = makeView(scene)
        let children = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        guard let employees = children.first(where: { $0.accessibilityLabel() == "employees" }) else {
            Issue.record("no employees element")
            return
        }

        let columns = employees.accessibilityChildren() as? [ERDiagramColumnElement] ?? []
        #expect(columns.count == 2)
        #expect(columns.first?.accessibilityLabel() == "id")
        #expect(columns.first?.accessibilityValue() as? String == "integer, primary key, required")
        #expect(columns.last?.accessibilityValue() as? String == "integer, foreign key, optional")
    }

    /// The frame is the part that fails silently. `accessibilityFrameInParentSpace` honours neither
    /// the flip nor the magnification, so an element written that way is announced over a
    /// different table at any zoom but 100%.
    @Test("Every element reports the rectangle it is actually drawn in", arguments: [1.0, 0.41, 2.0] as [CGFloat])
    func framesTrackMagnification(magnification: CGFloat) {
        let scene = makeScene()
        let (view, _) = makeView(scene, magnification: magnification)
        let children = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []

        for element in children {
            guard let name = element.accessibilityLabel(),
                  let node = scene.nodes.first(where: { $0.tableName == name }),
                  let rect = scene.nodeRects[node.id] else {
                Issue.record("unmatched element")
                continue
            }
            let expected = NSAccessibility.screenRect(fromView: view, rect: rect)
            let reported = element.accessibilityFrame()

            #expect(abs(reported.origin.x - expected.origin.x) < 0.01)
            #expect(abs(reported.origin.y - expected.origin.y) < 0.01)
            #expect(abs(reported.width - expected.width) < 0.01)
            #expect(abs(reported.height - expected.height) < 0.01)
        }
    }

    @Test("A column element lands on its own row, not on the whole table")
    func columnFramesFollowTheirRow() {
        let scene = makeScene()
        let (view, _) = makeView(scene)
        let children = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        guard let employees = children.first(where: { $0.accessibilityLabel() == "employees" }),
              let columns = employees.accessibilityChildren() as? [ERDiagramColumnElement],
              columns.count == 2 else {
            Issue.record("no column elements")
            return
        }

        let first = columns[0].accessibilityFrame()
        let second = columns[1].accessibilityFrame()
        #expect(first.height == ERDiagramLayout.columnRowHeight)
        #expect(first != second)
        #expect(employees.accessibilityFrame().contains(first.insetBy(dx: 1, dy: 1)))
    }

    /// A collapsed junction becomes one synthetic edge between the two parents, and the hidden
    /// table owns both foreign keys, so neither parent references the other.
    @Test("A collapsed many-to-many reads the same from both sides")
    func manyToManyIsSymmetric() {
        let left = node("users", columns: [column("id", primaryKey: true)])
        let right = node("roles", columns: [column("id", primaryKey: true)])
        let scene = ERDiagramScene(
            nodes: [left, right],
            edges: [
                EREdge(
                    id: UUID(),
                    fkName: "user_roles",
                    fromTable: "users",
                    fromColumn: "user_id",
                    toTable: "roles",
                    toColumn: "role_id",
                    cardinality: .manyToMany
                )
            ],
            nodeRects: [
                left.id: CGRect(x: 40, y: 40, width: ERDiagramLayout.nodeWidth, height: 60),
                right.id: CGRect(x: 400, y: 40, width: ERDiagramLayout.nodeWidth, height: 60)
            ],
            nodeIndex: ["users": left.id, "roles": right.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: CGSize(width: 800, height: 600)
        )
        let joins = ERDiagramAccessibilityTree.Joins(scene: scene)

        #expect(joins.description(of: "users") == "related to roles")
        #expect(joins.description(of: "roles") == "related to users")
    }

    @Test("Moving a table keeps the elements a client is holding")
    func elementsAreReusedAcrossSceneChanges() {
        var scene = makeScene()
        let (view, _) = makeView(scene)
        let before = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        #expect(before.count == 2)

        guard let moved = scene.nodes.first else {
            Issue.record("no node")
            return
        }
        scene.nodeRects[moved.id] = CGRect(x: 500, y: 500, width: ERDiagramLayout.nodeWidth, height: 80)
        view.scene = scene

        let after = view.accessibilityChildren() as? [ERDiagramNodeElement] ?? []
        #expect(after.count == 2)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        let element = after.first { $0.accessibilityLabel() == moved.tableName }
        #expect(element?.accessibilityFrame() == NSAccessibility.screenRect(
            fromView: view,
            rect: CGRect(x: 500, y: 500, width: ERDiagramLayout.nodeWidth, height: 80)
        ))
    }

    @Test("The selected table is what the canvas reports as focused")
    func selectionIsFocused() {
        var scene = makeScene()
        let (view, _) = makeView(scene)
        #expect(view.accessibilityFocusedUIElement as? ERDiagramSceneView === view)

        scene.selectedNodeId = scene.nodes.first?.id
        view.scene = scene

        let focused = view.accessibilityFocusedUIElement as? ERDiagramNodeElement
        #expect(focused?.accessibilityLabel() == scene.nodes.first?.tableName)
    }

    @Test("Selecting a table selects its element")
    func selectionIsPublished() {
        var scene = makeScene()
        let (view, _) = makeView(scene)
        #expect((view.accessibilitySelectedChildren() ?? []).isEmpty)

        scene.selectedNodeId = scene.nodes.first?.id
        view.scene = scene

        let selected = view.accessibilitySelectedChildren() as? [ERDiagramNodeElement] ?? []
        #expect(selected.count == 1)
        #expect(selected.first?.accessibilityLabel() == scene.nodes.first?.tableName)
    }

    @Test("A self-referencing table says so")
    func selfReferenceIsAnnounced() {
        let employees = node("employees", columns: [column("id", primaryKey: true), column("manager_id", foreignKey: true)])
        let scene = ERDiagramScene(
            nodes: [employees],
            edges: [
                EREdge(
                    id: UUID(),
                    fkName: "fk_manager",
                    fromTable: "employees",
                    fromColumn: "manager_id",
                    toTable: "employees",
                    toColumn: "id",
                    cardinality: .zeroOrManyToOne
                )
            ],
            nodeRects: [employees.id: CGRect(x: 40, y: 40, width: ERDiagramLayout.nodeWidth, height: 80)],
            nodeIndex: ["employees": employees.id],
            clusterColors: [:],
            selectedNodeId: nil,
            size: CGSize(width: 800, height: 600)
        )

        #expect(ERDiagramAccessibilityTree.Joins(scene: scene).description(of: "employees") == "references itself")
    }
}
