import SwiftUI
import UIKit

@Observable final class Marker {}

@MainActor enum Evaluations {
    static var sawMarker: [Bool] = []
}

@main
struct PresentedRootProbe: App {
    @State private var marker = Marker()

    var body: some Scene {
        WindowGroup {
            Presenter()
                .environment(marker)
        }
    }
}

struct Item: Identifiable {
    let id = 1
}

struct Presenter: View {
    @Environment(Marker.self) private var marker
    @State private var item: Item?
    private let injects = ProcessInfo.processInfo.environment["PROBE_INJECT"] == "1"

    var body: some View {
        let marker = marker
        Text(verbatim: "presenter")
            .fullScreenCover(item: $item) { _ in
                if injects {
                    PresentedRoot().environment(marker)
                } else {
                    PresentedRoot()
                }
            }
            .task { item = Item() }
    }
}

// ConnectedView's shape: a branch root with an alert and a sheet outside any NavigationStack.
struct PresentedRoot: View {
    @Environment(Marker.self) private var marker: Marker?
    @State private var never = false

    var body: some View {
        let _ = Evaluations.sawMarker.append(marker != nil)
        Group {
            if never {
                Text(verbatim: "never")
            } else {
                Text(verbatim: "presented")
            }
        }
        .alert("never", isPresented: $never) {}
        .sheet(isPresented: $never) { Text(verbatim: "never") }
        .task {
            try? await Task.sleep(for: .seconds(1))
            print("evaluations saw the presenter's object: \(Evaluations.sawMarker)")
            exit(Evaluations.sawMarker.first == true ? 0 : 1)
        }
    }
}
