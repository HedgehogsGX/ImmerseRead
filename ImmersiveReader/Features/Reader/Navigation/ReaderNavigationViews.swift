import SwiftUI

struct ReaderNavigationToolbar: View {
    @ObservedObject var model: ReaderNavigationModel
    let supportsNavigation: Bool

    @State private var presentedPanel: Panel?

    var body: some View {
        if supportsNavigation {
            Menu {
                Button {
                    presentedPanel = .contents
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                Button {
                    presentedPanel = .search
                } label: {
                    Label("搜索正文", systemImage: "magnifyingglass")
                }
                if model.currentLocation != nil {
                    Button {
                        model.toggleBookmark()
                    } label: {
                        Label(
                            model.isBookmarked() ? String(localized: "移除书签") : String(localized: "添加书签"),
                            systemImage: model.isBookmarked() ? "bookmark.fill" : "bookmark"
                        )
                    }
                }
                Button {
                    presentedPanel = .bookmarks
                } label: {
                    Label("书签", systemImage: "bookmark")
                }
            } label: {
                Label("导航", systemImage: "list.bullet.indent")
            }
            .accessibilityIdentifier("reader.navigation.menu")
            .sheet(item: $presentedPanel) { panel in
                ReaderNavigationPanel(model: model, panel: panel)
            }
            .alert("无法保存书签", isPresented: Binding(
                get: { model.bookmarkError != nil },
                set: { if !$0 { model.bookmarkError = nil } }
            )) {
                Button("好") { model.bookmarkError = nil }
            } message: {
                Text(model.bookmarkError ?? "")
            }
        }
    }
}

private struct ReaderNavigationPanel: View {
    @ObservedObject var model: ReaderNavigationModel
    let panel: ReaderNavigationToolbar.Panel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .contents:
                    List(model.sections) { section in
                        Button {
                            model.requestJump(to: section.location)
                            dismiss()
                        } label: {
                            Text(section.title)
                                .font(section.level <= 1 ? .headline : .body)
                                .padding(.leading, CGFloat(max(section.level - 1, 0) * 12))
                        }
                    }
                    .overlay {
                        if model.sections.isEmpty {
                            ContentUnavailableView("没有目录", systemImage: "list.bullet")
                        }
                    }
                case .search:
                    VStack(spacing: 0) {
                        TextField("搜索正文", text: $model.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .padding()
                            .onChange(of: model.searchQuery) { _, newValue in
                                model.search(newValue)
                            }
                        List(model.searchResults) { result in
                            Button {
                                model.requestJump(to: result.location)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title).font(.headline)
                                    Text(result.snippet).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .overlay {
                            if model.isSearching {
                                ProgressView("正在搜索…")
                            } else if let error = model.searchError {
                                ContentUnavailableView("无法搜索", systemImage: "exclamationmark.triangle", description: Text(error))
                            } else if model.searchResults.isEmpty, !model.searchQuery.isEmpty {
                                ContentUnavailableView("没有匹配结果", systemImage: "magnifyingglass")
                            }
                        }
                    }
                case .bookmarks:
                    List {
                        ForEach(model.bookmarks) { bookmark in
                            Button {
                                model.requestJump(to: bookmark.location)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(bookmark.title)
                                    Text(bookmark.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let removed = offsets.map { model.bookmarks[$0] }
                            removed.forEach(model.removeBookmark)
                        }
                    }
                    .overlay {
                        if model.bookmarks.isEmpty {
                            ContentUnavailableView("没有书签", systemImage: "bookmark")
                        }
                    }
                }
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension ReaderNavigationToolbar {
    enum Panel: String, Identifiable {
        case contents
        case search
        case bookmarks

        var id: Self { self }

        var title: String {
            switch self {
            case .contents: String(localized: "目录")
            case .search: String(localized: "搜索正文")
            case .bookmarks: String(localized: "书签")
            }
        }
    }
}
