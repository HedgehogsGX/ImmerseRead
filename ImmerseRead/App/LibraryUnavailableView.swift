import SwiftUI

/// Shown when the library database cannot be opened.
///
/// The books are still in place, so the screen says so and offers another try.
/// The one thing that would actually lose them is deleting the app, which is
/// the first thing a reader facing a blank shelf tends to do.
struct LibraryUnavailableView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("暂时无法打开书库", systemImage: "books.vertical")
        } description: {
            VStack(spacing: 12) {
                Text("书籍和阅读进度仍保存在这台设备上。请重新打开 App 再试一次，不要删除 App —— 删除会连同书库一起抹掉。")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("library.unavailable")
    }
}

#Preview {
    LibraryUnavailableView(message: "The store could not be opened.") {}
}
