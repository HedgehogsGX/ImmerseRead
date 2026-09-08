import SwiftUI

struct LibraryContentView<Destination: View>: View {
    let books: [LibraryBookPresentation]
    let destination: (LibraryBookPresentation) -> Destination
    let onImport: () -> Void
    let onDelete: (LibraryBookPresentation) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 20, alignment: .top)
    ]

    var body: some View {
        Group {
            if books.isEmpty {
                LibraryEmptyState(onImport: onImport)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(books) { book in
                            NavigationLink {
                                destination(book)
                            } label: {
                                LibraryBookCard(book: book) {
                                    onDelete(book)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct LibraryEmptyState: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("还没有书", systemImage: "books.vertical")
        } description: {
            Text("导入文档，把零散文字变成可以专注阅读的书。")
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
            return "正在准备文档…"
        }

        return "第 \(min(completedCount + 1, totalCount)) 项，共 \(totalCount) 项"
    }
}

private extension LibraryBookPresentation {
    static let previews: [Self] = [
        .init(
            id: UUID(uuidString: "9D2C1220-D735-4F1A-B34B-A26E7D640293")!,
            title: "瓦尔登湖",
            formatLabel: "EPUB",
            progress: 0.42,
            activityLabel: "20 分钟前读过",
            storedRelativePath: "preview/walden.epub"
        ),
        .init(
            id: UUID(uuidString: "7A7F0DF5-E559-4A3B-983D-9D67144125E6")!,
            title: "产品设计手记",
            formatLabel: "MD",
            progress: 0,
            activityLabel: "今天导入",
            storedRelativePath: "preview/design-notes.md"
        ),
        .init(
            id: UUID(uuidString: "169F3190-F463-42E0-A896-FC25844BEDB2")!,
            title: "长文阅读样例：一个会换行的标题",
            formatLabel: "DOCX",
            progress: 0.86,
            activityLabel: "昨天读过",
            storedRelativePath: "preview/long-form.docx"
        )
    ]
}

#Preview("Loaded") {
    NavigationStack {
        LibraryContentView(
            books: LibraryBookPresentation.previews,
            destination: { book in Text(book.title) },
            onImport: {},
            onDelete: { _ in }
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
