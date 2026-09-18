import Foundation
import TableProSpannerCore
import Testing

@Suite("SpannerPlanRenderer")
struct SpannerPlanRendererTests {
    private typealias Link = SpannerPlanNode.ChildLink

    @Test("The column is named QUERY PLAN")
    func columnName() {
        #expect(SpannerPlanRenderer.columnName == "QUERY PLAN")
    }

    @Test("No plan, an empty plan and the emulator placeholder all say so")
    func noPlan() throws {
        #expect(SpannerPlanRenderer.lines(nil) == ["No query plan returned"])
        #expect(SpannerPlanRenderer.lines(SpannerQueryPlan(nodes: [])) == ["No query plan returned"])
        let emulator = try JSONDecoder().decode(
            SpannerQueryPlan.self,
            from: Data(#"{"planNodes":[{"displayName":"No query plan"}]}"#.utf8)
        )
        #expect(SpannerPlanRenderer.lines(emulator) == ["No query plan returned"])
    }

    @Test("Relational children are indented and scalar children annotate their parent")
    func rendersTree() throws {
        let json = #"""
        {"planNodes":[
          {"kind":"RELATIONAL","displayName":"Distributed Union","childLinks":[{"childIndex":1},{"childIndex":6,"type":"Split Range"}]},
          {"index":1,"kind":"RELATIONAL","displayName":"Serialize Result","childLinks":[{"childIndex":2},{"childIndex":5}]},
          {"index":2,"kind":"RELATIONAL","displayName":"Filter Scan","childLinks":[{"childIndex":3},{"childIndex":4,"type":"Seek Condition"}]},
          {"index":3,"kind":"RELATIONAL","displayName":"Scan","metadata":{"scan_target":"Singers","scan_type":"TableScan"}},
          {"index":4,"kind":"SCALAR","displayName":"Function","shortRepresentation":{"description":"($Age > 3)"}},
          {"index":5,"kind":"SCALAR","displayName":"Reference","shortRepresentation":{"description":"$Id"}},
          {"index":6,"kind":"SCALAR","displayName":"Constant","shortRepresentation":{"description":"true"}}
        ]}
        """#
        let plan = try JSONDecoder().decode(SpannerQueryPlan.self, from: Data(json.utf8))
        #expect(SpannerPlanRenderer.lines(plan) == [
            "Distributed Union [Split Range: true]",
            "  Serialize Result [Reference: $Id]",
            "    Filter Scan [Seek Condition: ($Age > 3)]",
            "      Scan (TableScan: Singers)"
        ])
    }

    @Test("Siblings keep their order and a short description follows the name")
    func siblings() {
        let plan = SpannerQueryPlan(nodes: [
            SpannerPlanNode(index: 0, kind: "RELATIONAL", displayName: "Cross Apply",
                            childLinks: [Link(childIndex: 1, type: "Input"), Link(childIndex: 2, type: "Map")]),
            SpannerPlanNode(index: 1, kind: "RELATIONAL", displayName: "Scan", shortDescription: "Albums"),
            SpannerPlanNode(index: 2, displayName: "Scan", metadata: ["scan_target": .string("Songs")])
        ])
        #expect(SpannerPlanRenderer.lines(plan) == ["Cross Apply", "  Scan (Albums)", "  Scan (Songs)"])
    }

    @Test("Cycles and missing children do not loop or crash")
    func cycles() {
        let plan = SpannerQueryPlan(nodes: [
            SpannerPlanNode(index: 0, kind: "RELATIONAL", displayName: "A", childLinks: [Link(childIndex: 1), Link(childIndex: 9)]),
            SpannerPlanNode(index: 1, kind: "RELATIONAL", displayName: "B", childLinks: [Link(childIndex: 0), Link(childIndex: 1)])
        ])
        #expect(SpannerPlanRenderer.lines(plan) == ["A", "  B"])
    }

    @Test("A scalar child without a description adds nothing")
    func scalarWithoutDescription() {
        let plan = SpannerQueryPlan(nodes: [
            SpannerPlanNode(index: 0, kind: "RELATIONAL", displayName: "Scan", childLinks: [Link(childIndex: 1, variable: "Id")]),
            SpannerPlanNode(index: 1, kind: "SCALAR", displayName: "Reference")
        ])
        #expect(SpannerPlanRenderer.lines(plan) == ["Scan"])
    }
}
