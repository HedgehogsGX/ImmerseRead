import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]

    @State private var isFileImporterPresented = false
    @State private var importProgress: LibraryImportProgress?
    @State private var activeAlert: LibraryAlert?
    @State private var didReconcileStorage = false

    @State private var importService = BookImportService()

    var body: some View {
        LibraryContentView(
            books: presentedBooks,
            destination: { presentation in
                readerDestination(for: presentation)
            },
            onImport: presentFileImporter,
            onDelete: deleteBook
        )
        .navigationTitle("书架")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: presentFileImporter) {
                    Label("导入文档", systemImage: "plus")
                }
                .disabled(importProgress != nil)
                .accessibilityIdentifier("library.toolbar.import")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let importProgress {
                LibraryImportStatusView(
                    completedCount: importProgress.completedCount,
                    totalCount: importProgress.totalCount
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: importProgress != nil)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: LibraryImportTypes.supported,
            allowsMultipleSelection: true,
            onCompletion: handleFileImporterResult
        )
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .task {
            await reconcileStorageIfNeeded()
        }
    }

    private var presentedBooks: [LibraryBookPresentation] {
        books
            .sorted { lhs, rhs in
                let lhsActivity = lhs.lastOpenedAt ?? lhs.importedAt
                let rhsActivity = rhs.lastOpenedAt ?? rhs.importedAt
                return lhsActivity > rhsActivity
            }
            .map { book in
                LibraryBookPresentation(
                    id: book.id,
                    title: book.title,
                    formatLabel: formatLabel(for: book.formatRawValue),
                    progress: book.readingProgress,
                    activityLabel: activityLabel(for: book),
                    storedRelativePath: book.storedRelativePath
                )
            }
    }

    private func presentFileImporter() {
        guard importProgress == nil else {
            return
        }

        isFileImporterPresented = true
    }

    private func handleFileImporterResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                return
            }

            Task {
                await importDocuments(at: urls)
            }

        case .failure(let error):
            guard !error.isUserCancellation else {
                return
            }

            activeAlert = .init(title: "无法选择文档", message: error.localizedDescription)
        }
    }

    private func importDocuments(at urls: [URL]) async {
        guard importProgress == nil else {
            return
        }

        var knownHashes = Set(books.map(\.contentHash))
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            guard !Task.isCancelled else {
                break
            }

            importProgress = .init(completedCount: index, totalCount: urls.count)

            do {
                let result = try await importService.importBook(
                    from: url,
                    existingContentHashes: knownHashes
                )
                let book = Book(importResult: result)
                let importedBookID = book.id
                let importedContentHash = book.contentHash

                modelContext.insert(book)

                do {
                    try modelContext.save()
                    knownHashes.insert(importedContentHash)
                } catch {
                    modelContext.rollback()
                    try? await importService.removeStoredFiles(
                        for: importedBookID,
                        contentHash: importedContentHash
                    )
                    throw error
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        importProgress = nil

        guard !failures.isEmpty else {
            return
        }

        let importedCount = urls.count - failures.count
        let title = importedCount > 0 ? "部分文档未能导入" : "导入失败"
        let visibleFailures = failures.prefix(3).joined(separator: "\n")
        let remainingCount = max(failures.count - 3, 0)
        let suffix = remainingCount > 0 ? "\n另有 \(remainingCount) 个文档未能导入。" : ""
        activeAlert = .init(title: title, message: visibleFailures + suffix)
    }

    private func deleteBook(_ presentation: LibraryBookPresentation) {
        guard let book = books.first(where: { $0.id == presentation.id }) else {
            return
        }

        let bookID = book.id
        let contentHash = book.contentHash
        modelContext.delete(book)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            activeAlert = .init(title: "无法删除", message: error.localizedDescription)
            return
        }

        Task {
            do {
                try await importService.removeStoredFiles(for: bookID, contentHash: contentHash)
            } catch {
                activeAlert = .init(
                    title: "书籍已移除",
                    message: "书架记录已删除，但本地缓存暂时未能清理。"
                )
            }
        }
    }

    private func reconcileStorageIfNeeded() async {
        guard !didReconcileStorage else {
            return
        }
        didReconcileStorage = true

        do {
            try await importService.reconcileStorage(validBookIDs: Set(books.map(\.id)))
        } catch {
            activeAlert = .init(
                title: "书库维护未完成",
                message: "部分无效缓存暂时无法清理，不影响继续阅读。"
            )
        }
    }

    @ViewBuilder
    private func readerDestination(for presentation: LibraryBookPresentation) -> some View {
        if let book = books.first(where: { $0.id == presentation.id }) {
            LibraryReaderDestination(book: book, importService: importService)
        } else {
            ContentUnavailableView(
                "找不到这本书",
                systemImage: "book.closed",
                description: Text("它可能已经从书架中移除。")
            )
        }
    }

    private func formatLabel(for rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "md", "markdown":
            "MD"
        default:
            rawValue.uppercased()
        }
    }

    private func activityLabel(for book: Book) -> String {
        let timestamp: String

        if let lastOpenedAt = book.lastOpenedAt {
            timestamp = relativeLabel(for: lastOpenedAt, action: "读过")
        } else {
            timestamp = relativeLabel(for: book.importedAt, action: "导入")
        }

        guard let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else {
            return timestamp
        }

        return "\(author) · \(timestamp)"
    }

    private func relativeLabel(for date: Date, action: String) -> String {
        if abs(date.timeIntervalSinceNow) < 60 {
            return "刚刚\(action)"
        }

        return "\(date.formatted(.relative(presentation: .named)))\(action)"
    }
}

private struct LibraryImportProgress: Equatable {
    let completedCount: Int
    let totalCount: Int
}

private struct LibraryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum LibraryImportTypes {
    static let supported: [UTType] = [
        "epub",
        "pdf",
        "txt",
        "md",
        "markdown",
        "docx",
        "doc"
    ].compactMap { UTType(filenameExtension: $0) }
}

private extension Error {
    var isUserCancellation: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}
