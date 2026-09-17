import SwiftData
import SwiftUI

@main
struct ImmersiveReaderApp: App {
    @State private var libraryStore = LibraryStoreLoader()

    var body: some Scene {
        WindowGroup {
            switch libraryStore.state {
            case .ready(let container):
                AppRootView()
                    .modelContainer(container)

            case .unavailable(let message):
                LibraryUnavailableView(message: message) {
                    libraryStore.reload()
                }
            }
        }
    }
}
