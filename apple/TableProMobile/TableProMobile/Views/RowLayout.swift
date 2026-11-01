import SwiftUI
import UIKit

nonisolated enum RowLayout: String, CaseIterable, Identifiable, Sendable {
    case cards
    case grid

    var id: String { rawValue }

    // The idiom, not the size class: a resize or rotation must not swap the layout under a pushed row.
    static func resolved(preferred: RowLayout?, idiom: UIUserInterfaceIdiom) -> RowLayout {
        if let preferred { return preferred }
        return idiom == .phone ? .cards : .grid
    }

    var title: String {
        switch self {
        case .cards: return String(localized: "Cards")
        case .grid: return String(localized: "Grid")
        }
    }

    var systemImage: String {
        switch self {
        case .cards: return "rectangle.grid.1x2"
        case .grid: return "tablecells"
        }
    }
}

struct RowLayoutPicker: View {
    @AppStorage(AppPreferences.rowLayoutKey) private var preferredLayout: RowLayout?

    var body: some View {
        let current = RowLayout.resolved(preferred: preferredLayout, idiom: UIDevice.current.userInterfaceIdiom)
        Picker(selection: Binding(get: { current }, set: { preferredLayout = $0 })) {
            ForEach(RowLayout.allCases) { layout in
                Label(layout.title, systemImage: layout.systemImage).tag(layout)
            }
        } label: {
            Label("Layout", systemImage: current.systemImage)
        }
        .pickerStyle(.inline)
    }
}
