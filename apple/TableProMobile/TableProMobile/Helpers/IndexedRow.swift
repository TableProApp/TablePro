import Foundation

struct IndexedRow<Element>: Identifiable {
    let id: Int
    let values: Element
}
