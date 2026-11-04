import SwiftUI
import TableProModels

// macOS 27 evaluates a presented root once without the presenter's environment (scripts/probes/check-presented-root-environment.sh).
struct SceneObjects {
    let appState: AppState
    let coordinatorStore: ConnectionCoordinatorStore
    let presenter: ScenePresenter
    let menuState: SceneMenuState?
}

extension View {
    func sceneObjects(_ objects: SceneObjects) -> some View {
        environment(objects.appState)
            .environment(objects.coordinatorStore)
            .environment(objects.presenter)
            .environment(objects.menuState)
    }
}

struct ConnectionCover: View {
    let connection: DatabaseConnection
    let objects: SceneObjects
    let onAppear: () -> Void

    var body: some View {
        ConnectedView(connection: connection)
            .id(connection.id)
            .onAppear(perform: onAppear)
            .sceneObjects(objects)
    }
}

struct ConnectionFormSheet: View {
    let connection: DatabaseConnection?
    let objects: SceneObjects
    let onSaved: (UUID) -> Void

    var body: some View {
        ConnectionFormView(editing: connection, onSaved: onSaved)
            .sceneObjects(objects)
    }
}
