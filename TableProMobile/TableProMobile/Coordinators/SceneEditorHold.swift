import Foundation
import SwiftUI

@MainActor
final class SceneEditorHold {
    private weak var presenter: ScenePresenter?
    private let token = UUID()

    func update(isHolding: Bool, in presenter: ScenePresenter) {
        self.presenter = presenter
        presenter.setEditorHold(token, isHolding: isHolding)
    }

    deinit {
        guard let presenter else { return }
        let token = token
        Task { @MainActor in
            presenter.setEditorHold(token, isHolding: false)
        }
    }
}

extension View {
    func holdsScene(withUnsavedChanges isHolding: Bool) -> some View {
        modifier(SceneEditorHoldModifier(isHolding: isHolding))
    }
}

private struct SceneEditorHoldModifier: ViewModifier {
    let isHolding: Bool

    @Environment(ScenePresenter.self) private var presenter: ScenePresenter?
    @State private var hold = SceneEditorHold()

    func body(content: Content) -> some View {
        content.onChange(of: isHolding, initial: true) { _, holding in
            guard let presenter else { return }
            hold.update(isHolding: holding, in: presenter)
        }
    }
}
