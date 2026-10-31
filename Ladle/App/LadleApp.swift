import ApronKit
import SwiftUI

@main
struct LadleApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = SessionStore(serverStore: try? ServerStore.applicationSupport(), tokens: KeychainStore(),
                                            notifier: LocalReminderNotifier())
    @State private var loadError: String?

    init() {
        // Picked files wait here only until they are fitted; a draft's fitted files are kept by `Drafts`.
        AttachmentStaging.clear()
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, loadError: loadError)
                .task {
                    do { try store.load() } catch { loadError = error.localizedDescription }
                }
        }
    }
}
