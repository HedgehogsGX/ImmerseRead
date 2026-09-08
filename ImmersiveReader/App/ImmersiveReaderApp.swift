import SwiftData
import SwiftUI

@main
struct ImmersiveReaderApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(for: Book.self)
    }
}
