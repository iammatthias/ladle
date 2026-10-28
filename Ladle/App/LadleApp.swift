import ApronKit
import SwiftUI

@main
struct LadleApp: App {
    @State private var store: SessionStore = {
        let store = SessionStore(serverStore: try? ServerStore.applicationSupport(), tokens: KeychainStore())
        try? store.load()
        return store
    }()

    var body: some Scene {
        WindowGroup {
            ServerListView(store: store)
        }
    }
}
