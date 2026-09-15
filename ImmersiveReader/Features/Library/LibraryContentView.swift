import SwiftUI

enum LibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .grid:
            String(localized: "封面视图")
        case .list:
            String(localized: "列表视图")
        }
    }

    var systemImage: String {
        switch self {
        case .grid:
            "square.grid.2x2"
        case .list:
            "list.bullet"
        }
    }
}

enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case recentlyRead
    case recentlyAdded
    case title
    case progress

    var id: Self { self }

    var title: String {
        switch self {
        case .recentlyRead:
            String(localized: "最近阅读")
        case .recentlyAdded:
            String(localized: "最近导入")
        case .title:
            String(localized: "书名")
        case .progress:
            String(localized: "阅读进度")
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyRead:
            "clock"
        case .recentlyAdded:
            "tray.and.arrow.down"
        case .title:
            "textformat.abc"
        case .progress:
            "chart.bar"
        }
    }
}

struct LibraryContentView<Destination: View>: View {
    let books: [LibraryBookPresentation]
    let destination: (LibraryBookPresentation) -> Destination
    let onImport: () -> Void
    let onDelete: (LibraryBookPresentation) -> Void
    var layout: LibraryLayout = .grid
    /// Shown above the shelf; `nil` while searching or when nothing is open.
    var continueReadingBook: LibraryBookPresentation?
    var isFiltering = false
    var onEditDetails: (LibraryBookPresentation) -> Void = { _ in }

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)
    ]

    var body: some View {
        Group {
            if books.isEmpty {
                if isFiltering {
                    LibraryNoResultsState()
                } else {
                    LibraryEmptyState(onImport: onImport)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let continueReadingBook {
                            bookLink(for: continueReadingBook) {
                                LibraryContinueReadingCard(book: continueReadingBook)
                            }
                        }

                        shelfHeader

                        switch layout {
                        case .grid:
                            grid
                        case .list:
                            list
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var shelfHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isFiltering ? "搜索结果" : "全部图书")
                .font(.headline)

            Text("\(books.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .padding(.top, continueReadingBook == nil ? 0 : 4)
        .accessibilityElement(children: .combine)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(books) { book in
                bookLink(for: book) {
                    LibraryBookCard(book: book)
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(books) { book in
                bookLink(for: book) {
                    LibraryBookRow(book: book)
                }

                if book.id != books.last?.id {
                    Divider()
                        .padding(.leading, 70)
                }
            }
        }
    }

    private func bookLink(
        for book: LibraryBookPresentation,
        @ViewBuilder label: () -> some View
    ) -> some View {
        NavigationLink {
            destination(book)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEditDetails(book)
            } label: {
                Label("重命名与封面", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("library.details.\(book.id.uuidString)")

            Button(role: .destructive) {
                onDelete(book)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .accessibilityIdentifier("library.delete.\(book.id.uuidString)")
        }
    }
}

struct LibraryEmptyState: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("还没有书", systemImage: "books.vertical")
        } description: {
            Text("导入文档，把零散文字变成可以专注阅读的书。封面会自动从文件里读取。")
        } actions: {
            Button(action: onImport) {
                Label("导入文档", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("library.empty.import")
        }
        .accessibilityIdentifier("library.empty")
    }
}

struct LibraryNoResultsState: View {
    var body: some View {
        ContentUnavailableView {
            Label("没有找到", systemImage: "magnifyingglass")
        } description: {
            Text("换一个书名或作者试试。")
        }
        .accessibilityIdentifier("library.noResults")
    }
}

struct LibraryImportStatusView: View {
    let completedCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("正在导入")
                    .font(.subheadline.weight(.semibold))

                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.importing")
    }

    private var statusLabel: String {
        guard totalCount > 1 else {
            return String(localized: "正在准备文档…")
        }

        return String(localized: "第 \(min(completedCount + 1, totalCount)) 项，共 \(totalCount) 项")
    }
}

extension LibraryBookPresentation {
    static let previews: [Self] = [
        .init(
            id: UUID(uuidString: "9D2C1220-D735-4F1A-B34B-A26E7D640293")!,
            title: "瓦尔登湖",
            author: "亨利·戴维·梭罗",
            format: .epub,
            progress: 0.42,
            activityLabel: "20 分钟前读过",
            storedRelativePath: "preview/walden.epub",
            fileByteCount: 2_400_000
        ),
        .init(
            id: UUID(uuidString: "7A7F0DF5-E559-4A3B-983D-9D67144125E6")!,
            title: "产品设计手记",
            format: .markdown,
            progress: 0,
            activityLabel: "今天导入",
            storedRelativePath: "preview/design-notes.md",
            fileByteCount: 48_000
        ),
        .init(
            id: UUID(uuidString: "169F3190-F463-42E0-A896-FC25844BEDB2")!,
            title: "长文阅读样例：一个会换行的标题",
            author: "示例作者",
            format: .docx,
            progress: 1,
            activityLabel: "昨天读过",
            storedRelativePath: "preview/long-form.docx",
            fileByteCount: 1_100_000
        )
    ]
}

#Preview("Grid") {
    NavigationStack {
        LibraryContentView(
            books: LibraryBookPresentation.previews,
            destination: { book in Text(book.title) },
            onImport: {},
            onDelete: { _ in },
            layout: .grid,
            continueReadingBook: LibraryBookPresentation.previews[0]
        )
        .navigationTitle("书架")
    }
}

#Preview("List") {
    NavigationStack {
        LibraryContentView(
            books: LibraryBookPresentation.previews,
            destination: { book in Text(book.title) },
            onImport: {},
            onDelete: { _ in },
            layout: .list
        )
        .navigationTitle("书架")
    }
}

#Preview("Empty") {
    NavigationStack {
        LibraryContentView(
            books: [],
            destination: { _ in EmptyView() },
            onImport: {},
            onDelete: { _ in }
        )
        .navigationTitle("书架")
    }
}
