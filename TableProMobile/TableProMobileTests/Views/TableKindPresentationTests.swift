import Foundation
@testable import TableProMobile
import TableProModels
import Testing
import UIKit

@Suite("Table kind presentation")
struct TableKindPresentationTests {
    @Test("a materialized view has its own symbol and spoken kind, apart from a view's")
    func materializedViewIsNotAView() {
        #expect(TableKindPresentation.systemImage(for: .materializedView) == "square.stack.3d.up")
        #expect(
            TableKindPresentation.systemImage(for: .materializedView)
                != TableKindPresentation.systemImage(for: .view)
        )
        #expect(
            TableKindPresentation.accessibilityKind(for: .materializedView)
                != TableKindPresentation.accessibilityKind(for: .view)
        )
    }

    @Test("every kind names a symbol the system has and a spoken kind of its own", arguments: TableInfo.TableKind.allCases)
    func everyKindIsPresented(kind: TableInfo.TableKind) {
        let symbol = TableKindPresentation.systemImage(for: kind)
        #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        #expect(!TableKindPresentation.accessibilityKind(for: kind).isEmpty)
    }

    @Test("no two kinds share a symbol or a spoken kind")
    func kindsAreDistinct() {
        let kinds = TableInfo.TableKind.allCases
        #expect(Set(kinds.map { TableKindPresentation.systemImage(for: $0) }).count == kinds.count)
        #expect(Set(kinds.map { TableKindPresentation.accessibilityKind(for: $0) }).count == kinds.count)
    }
}
