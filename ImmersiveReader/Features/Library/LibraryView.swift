import Foundation
import SwiftData
import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]

    @AppStorage("library.layout") private var layoutRawValue = LibraryLayout.grid.rawValue
    @AppStorage("library.sortOrder") private var sortOrderRawValue = LibrarySortOrder.recentlyRead.rawValue

    @State private var searchText = ""
    @State private var isFileImporterPresented = false
    @State private var importProgress: LibraryImportProgress?
    @State private var activeAlert: LibraryAlert?
    @State private var didReconcileStorage = false
    @State private var coverURLs: [UUID: URL] = [:]
    @State private var coverEditorTarget: LibraryCoverEditorTarget?
    @State private var coverEditorError: String?
    @State private var isCoverWorking = false

    @State private var importService = BookImportService()

    var body: some View {
        LibraryContentView(
            books: presentedBooks,
            destination: { presentation in
                readerDestination(for: presentation)
            },
            onImport: presentFileImporter,
            onDelete: deleteBook,
            layout: layout,
            continueReadingBook: continueReadingBook,
            isFiltering: !trimmedSearchText.isEmpty,
            onEditCover: presentCoverEditor
        )
        .navigationTitle("书架")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("搜索书名或作者")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                shelfOptionsMenu
            }

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
            allowedContentTypes: BookFormat.importContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileImporterResult
        )
        .sheet(item: $coverEditorTarget, onDismiss: { coverEditorError = nil }) { target in
            coverEditor(for: target)
        }
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .task {
            await prepareLibraryIfNeeded()
        }
    }

    private var shelfOptionsMenu: some View {
        Menu {
            Picker("显示方式", selection: $layoutRawValue) {
                ForEach(LibraryLayout.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)

            Picker("排序方式", selection: $sortOrderRawValue) {
                ForEach(LibrarySortOrder.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("书架选项", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("library.toolbar.options")
    }

    // MARK: - Shelf contents

    private var layout: LibraryLayout {
        LibraryLayout(rawValue: layoutRawValue) ?? .grid
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRawValue) ?? .recentlyRead
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presentedBooks: [LibraryBookPresentation] {
        sortedBooks(matchingSearch: true).map(presentation(for:))
    }

    /// The book to offer at the top: opened most recently, started, unfinished.
    private var continueReadingBook: LibraryBookPresentation? {
        guard trimmedSearchText.isEmpty else {
            return nil
        }

        return books
            .filter { book in
                book.lastOpenedAt != nil
                    && book.readingProgress > 0.001
                    && book.readingProgress < 0.999
            }
            .max { lhs, rhs in
                (lhs.lastOpenedAt ?? .distantPast) < (rhs.lastOpenedAt ?? .distantPast)
            }
            .map(presentation(for:))
    }

    private func sortedBooks(matchingSearch: Bool) -> [Book] {
        let query = trimmedSearchText
        let matched = !matchingSearch || query.isEmpty
            ? books
            : books.filter { book in
                [book.title, book.author ?? "", book.originalFilename].contains { field in
                    field.localizedStandardContains(query)
                }
            }

        switch sortOrder {
        case .recentlyRead:
            return matched.sorted { activityDate(for: $0) > activityDate(for: $1) }
        case .recentlyAdded:
            return matched.sorted { $0.importedAt > $1.importedAt }
        case .title:
            return matched.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .progress:
            return matched.sorted { lhs, rhs in
                lhs.readingProgress == rhs.readingProgress
                    ? activityDate(for: lhs) > activityDate(for: rhs)
                    : lhs.readingProgress > rhs.readingProgress
            }
        }
    }

    private func activityDate(for book: Book) -> Date {
        book.lastOpenedAt ?? book.importedAt
    }

    private func presentation(for book: Book) -> LibraryBookPresentation {
        LibraryBookPresentation(
            id: book.id,
            title: book.title,
            author: book.author,
            format: book.format,
            progress: book.readingProgress,
            activityLabel: activityLabel(for: book),
            storedRelativePath: book.storedRelativePath,
            fileByteCount: book.fileByteCount,
            coverURL: coverURLs[book.id],
            coverStyle: book.coverStyle,
            coverSource: book.coverSource,
            coverUpdatedAt: book.coverUpdatedAt
        )
    }

    private func book(with id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    // MARK: - Importing

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

            activeAlert = .init(title: String(localized: "无法选择文档"), message: error.localizedDescription)
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
                    await refreshCoverURL(for: importedBookID)
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
        let title = importedCount > 0
            ? String(localized: "部分文档未能导入")
            : String(localized: "导入失败")
        let visibleFailures = failures.prefix(3).joined(separator: "\n")
        let remainingCount = max(failures.count - 3, 0)
        let suffix = remainingCount > 0
            ? String(localized: "\n另有 \(remainingCount) 个文档未能导入。")
            : ""
        activeAlert = .init(title: title, message: visibleFailures + suffix)
    }

    private func deleteBook(_ presentation: LibraryBookPresentation) {
        guard let book = book(with: presentation.id) else {
            return
        }

        let bookID = book.id
        let contentHash = book.contentHash
        modelContext.delete(book)
        coverURLs.removeValue(forKey: bookID)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            activeAlert = .init(title: String(localized: "无法删除"), message: error.localizedDescription)
            return
        }

        Task {
            do {
                try await importService.removeStoredFiles(for: bookID, contentHash: contentHash)
            } catch {
                activeAlert = .init(
                    title: String(localized: "书籍已移除"),
                    message: String(localized: "书架记录已删除，但本地缓存暂时未能清理。")
                )
            }
        }
    }

    // MARK: - Covers

    @ViewBuilder
    private func coverEditor(for target: LibraryCoverEditorTarget) -> some View {
        if let book = book(with: target.id) {
            BookCoverEditorView(
                book: presentation(for: book),
                canDetect: book.format.canCarryCover,
                isWorking: isCoverWorking,
                errorMessage: coverEditorError,
                onPickImageData: { data in
                    performCoverWork { await applyPickedCover(data, to: target.id) }
                },
                onDetect: {
                    performCoverWork { await detectCover(for: target.id) }
                },
                onRemoveCover: {
                    performCoverWork { await removeCover(for: target.id) }
                },
                onSelectStyle: { style in
                    selectCoverStyle(style, for: target.id)
                },
                onCommitDetails: { title, author in
                    commitDetails(title: title, author: author, for: target.id)
                }
            )
        } else {
            ContentUnavailableView(
                "找不到这本书",
                systemImage: "book.closed",
                description: Text("它可能已经从书架中移除。")
            )
        }
    }

    private func presentCoverEditor(_ presentation: LibraryBookPresentation) {
        coverEditorError = nil
        coverEditorTarget = .init(id: presentation.id)
    }

    /// Runs one cover change, keeping the sheet busy and reporting the failure
    /// in place rather than behind an alert.
    private func performCoverWork(_ work: @escaping () async -> String?) {
        guard !isCoverWorking else {
            return
        }

        isCoverWorking = true
        coverEditorError = nil

        Task {
            let message = await work()
            isCoverWorking = false
            coverEditorError = message
        }
    }

    private func applyPickedCover(_ imageData: Data, to bookID: UUID) async -> String? {
        do {
            let relativePath = try await importService.replaceCover(
                for: bookID,
                imageData: imageData
            )
            guard let book = book(with: bookID) else {
                return nil
            }

            book.applyCover(relativePath: relativePath, source: .custom)
            try modelContext.save()
            await refreshCoverURL(for: bookID)
            return nil
        } catch {
            modelContext.rollback()
            return error.localizedDescription
        }
    }

    private func removeCover(for bookID: UUID) async -> String? {
        do {
            try await importService.removeCover(for: bookID)
            guard let book = book(with: bookID) else {
                return nil
            }

            book.applyCover(relativePath: nil, source: .generated)
            try modelContext.save()
            coverURLs.removeValue(forKey: bookID)
            return nil
        } catch {
            modelContext.rollback()
            return error.localizedDescription
        }
    }

    @discardableResult
    private func detectCover(for bookID: UUID) async -> String? {
        guard let pendingBook = book(with: bookID) else {
            return nil
        }

        let storedRelativePath = pendingBook.storedRelativePath
        let format = pendingBook.format

        do {
            let detection = try await importService.detectCover(
                for: bookID,
                storedRelativePath: storedRelativePath,
                format: format
            )
            // The shelf may have changed while the document was inspected.
            guard let book = book(with: bookID) else {
                return nil
            }

            book.applyCover(
                relativePath: detection.coverRelativePath,
                source: detection.source
            )
            try modelContext.save()
            await refreshCoverURL(for: bookID)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            modelContext.rollback()
            return error.localizedDescription
        }
    }

    private func selectCoverStyle(_ style: BookCoverStyle, for bookID: UUID) {
        guard let book = book(with: bookID) else {
            return
        }

        book.coverStyle = style
        guard (try? modelContext.save()) != nil else {
            modelContext.rollback()
            return
        }
    }

    private func commitDetails(title: String, author: String, for bookID: UUID) {
        guard let book = book(with: bookID) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty {
            book.title = String(trimmedTitle.prefix(512))
        }
        book.author = trimmedAuthor.isEmpty ? nil : String(trimmedAuthor.prefix(512))

        guard (try? modelContext.save()) != nil else {
            modelContext.rollback()
            return
        }
    }

    // MARK: - Startup

    private func prepareLibraryIfNeeded() async {
        guard !didReconcileStorage else {
            return
        }
        didReconcileStorage = true

        do {
            try await importService.reconcileStorage(validBookIDs: Set(books.map(\.id)))
            await refreshCoverURLs()
        } catch {
            activeAlert = .init(
                title: String(localized: "书库维护未完成"),
                message: String(localized: "部分无效缓存暂时无法清理，不影响继续阅读。")
            )
        }

        await detectMissingCovers()
    }

    /// Gives books imported before covers were read one pass of detection.
    private func detectMissingCovers() async {
        let pendingBookIDs = books
            .filter(\.needsCoverDetection)
            .map(\.id)

        for bookID in pendingBookIDs {
            guard !Task.isCancelled else {
                return
            }
            await detectCover(for: bookID)
        }
    }

    private func refreshCoverURLs() async {
        var resolvedURLs: [UUID: URL] = [:]
        for book in books {
            guard let relativePath = book.coverRelativePath,
                  let coverURL = try? await importService.storedCoverURL(for: relativePath)
            else {
                continue
            }
            resolvedURLs[book.id] = coverURL
        }
        guard !Task.isCancelled else {
            return
        }
        coverURLs = resolvedURLs
    }

    private func refreshCoverURL(for bookID: UUID) async {
        guard let book = book(with: bookID),
              let relativePath = book.coverRelativePath,
              let coverURL = try? await importService.storedCoverURL(for: relativePath)
        else {
            coverURLs.removeValue(forKey: bookID)
            return
        }
        coverURLs[bookID] = coverURL
    }

    @ViewBuilder
    private func readerDestination(for presentation: LibraryBookPresentation) -> some View {
        if let book = book(with: presentation.id) {
            LibraryReaderDestination(book: book, importService: importService)
        } else {
            ContentUnavailableView(
                "找不到这本书",
                systemImage: "book.closed",
                description: Text("它可能已经从书架中移除。")
            )
        }
    }

    private func activityLabel(for book: Book) -> String {
        let timestamp: String

        if let lastOpenedAt = book.lastOpenedAt {
            timestamp = lastReadLabel(for: lastOpenedAt)
        } else {
            timestamp = importedLabel(for: book.importedAt)
        }

        guard let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else {
            return timestamp
        }

        return "\(author) · \(timestamp)"
    }

    /// Each wording is its own localized format, so a translation can put the
    /// verb wherever its language needs it.
    private func lastReadLabel(for date: Date) -> String {
        guard abs(date.timeIntervalSinceNow) >= 60 else {
            return String(localized: "刚刚读过")
        }

        let timestamp = date.formatted(.relative(presentation: .named))
        return String(localized: "\(timestamp)读过")
    }

    private func importedLabel(for date: Date) -> String {
        guard abs(date.timeIntervalSinceNow) >= 60 else {
            return String(localized: "刚刚导入")
        }

        let timestamp = date.formatted(.relative(presentation: .named))
        return String(localized: "\(timestamp)导入")
    }
}

private struct LibraryImportProgress: Equatable {
    let completedCount: Int
    let totalCount: Int
}

private struct LibraryCoverEditorTarget: Identifiable {
    let id: UUID
}

private struct LibraryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private extension Error {
    var isUserCancellation: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}
