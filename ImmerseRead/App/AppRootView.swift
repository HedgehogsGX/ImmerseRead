import SwiftData
import SwiftUI

struct AppRootView: View {
    var body: some View {
        NavigationStack {
            LibraryView()
        }
    }
}

#Preview {
    AppRootView()
        .modelContainer(for: Book.self, inMemory: true)
}
