import ApronKit
import SwiftUI

@main
struct LadleApp: App {
    @State private var store: SessionStore = {
        let store = SessionStore(serverStore: try? ServerStore.applicationSupport(), tokens: KeychainStore())
        try? store.load()
        return store
    }()
    @AppStorage("debug.direction") private var direction = Direction.mise

    var body: some Scene {
        WindowGroup {
            ServerListView(store: store)
                .themed(Theme.of(direction))
        }
    }
}
