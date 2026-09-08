import SwiftData
import SwiftUI

@MainActor
struct LibraryReaderDestination: View {
    let book: Book
    let importService: BookImportService

    @Environment(\.modelContext) private var modelContext
    @State private var loadState: LoadState = .loading
    @State private var retryID = UUID()
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var isProgressSaveAlertPresented = false

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("正在打开…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("reader.loading")

            case .loaded(let document):
                ReaderContainerView(
                    document: document,
                    initialProgress: book.readingProgress,
                    onProgressChange: saveProgress,
                    initialLocationData: book.readingLocationData,
                    onLocationChange: saveLocation
                )

            case .failed(let message):
                ContentUnavailableView {
                    Label("无法打开文档", systemImage: "exclamationmark.book.closed")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        retryID = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("reader.open.failed")
            }
        }
        .task(id: retryID) {
            await loadDocument()
        }
        .onDisappear {
            progressSaveTask?.cancel()
            try? modelContext.save()
        }
        .alert("无法保存阅读进度", isPresented: $isProgressSaveAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text("本次阅读可以继续，但退出后可能无法恢复到当前位置。")
        }
    }

    private func loadDocument() async {
        loadState = .loading
        book.lastOpenedAt = .now

        do {
            try modelContext.save()
            let fileURL = try await importService.storedFileURL(for: book.storedRelativePath)

            let document = ReaderDocument(
                id: book.id,
                title: book.title,
                fileURL: fileURL,
                format: book.format
            )

            guard !Task.isCancelled else {
                return
            }

            loadState = .loaded(document)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func saveLocation(_ progress: Double, _ locationData: Data) {
        book.readingLocationData = locationData
        saveProgress(progress)
    }

    private func saveProgress(_ progress: Double) {
        book.readingProgress = progress.clampedToUnitInterval
        progressSaveTask?.cancel()
        progressSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else {
                return
            }
            do {
                try modelContext.save()
            } catch {
                isProgressSaveAlertPresented = true
            }
        }
    }
}

private extension LibraryReaderDestination {
    enum LoadState {
        case loading
        case loaded(ReaderDocument)
        case failed(String)
    }
}
