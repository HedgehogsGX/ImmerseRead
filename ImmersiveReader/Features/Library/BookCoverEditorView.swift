import PhotosUI
import SwiftUI

/// Lets the reader replace a cover with their own picture, ask for the
/// document's own cover back, or fall back to lettering — and fix the title
/// that the lettering is built from.
struct BookCoverEditorView: View {
    let book: LibraryBookPresentation
    /// Whether this format can carry a cover the app could find again.
    let canDetect: Bool
    var isWorking = false
    var errorMessage: String?
    var onPickImageData: (Data) -> Void = { _ in }
    var onDetect: () -> Void = {}
    var onRemoveCover: () -> Void = {}
    var onSelectStyle: (BookCoverStyle) -> Void = { _ in }
    var onCommitDetails: (String, String) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var photoSelection: PhotosPickerItem?
    @State private var isImageImporterPresented = false
    @State private var selectedStyle: BookCoverStyle?
    @State private var editedTitle = ""
    @State private var editedAuthor = ""
    @State private var hasLoadedDetails = false
    @State private var localErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                pictureSection

                if book.coverURL == nil {
                    letteringSection
                }

                detailsSection
            }
            .disabled(isWorking)
            .navigationTitle("封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .accessibilityIdentifier("cover.done")
                }
            }
            // Picture and palette changes land as they are made, so the title
            // and author are saved on the way out rather than pretending the
            // whole sheet can be cancelled.
            .onDisappear {
                guard hasLoadedDetails else {
                    return
                }
                onCommitDetails(editedTitle, editedAuthor)
            }
            .overlay {
                if isWorking {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleImageFileResult
        )
        .onChange(of: photoSelection) { _, selection in
            guard let selection else {
                return
            }
            Task {
                await loadPhoto(selection)
            }
        }
        .task {
            guard !hasLoadedDetails else {
                return
            }
            hasLoadedDetails = true
            editedTitle = book.title
            editedAuthor = book.author ?? ""
            selectedStyle = book.coverStyle
        }
    }

    private var previewSection: some View {
        Section {
            VStack(spacing: 12) {
                LibraryBookCover(book: previewBook, cornerRadius: 12, targetWidth: 168)
                    .frame(width: 168)
                    .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)

                Text(sourceLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let message = errorMessage ?? localErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
        }
    }

    private var pictureSection: some View {
        Section {
            PhotosPicker(
                selection: $photoSelection,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("从照片选择", systemImage: "photo")
            }
            .accessibilityIdentifier("cover.pickPhoto")

            Button {
                isImageImporterPresented = true
            } label: {
                Label("从文件选择", systemImage: "folder")
            }
            .accessibilityIdentifier("cover.pickFile")

            if canDetect {
                Button {
                    localErrorMessage = nil
                    onDetect()
                } label: {
                    Label("重新识别文件内封面", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("cover.detect")
            }

            if book.coverURL != nil {
                Button(role: .destructive) {
                    localErrorMessage = nil
                    onRemoveCover()
                } label: {
                    Label("移除封面图片", systemImage: "trash")
                }
                .accessibilityIdentifier("cover.remove")
            }
        } header: {
            Text("封面图片")
        } footer: {
            Text(canDetect
                ? "移除图片后，书架会显示按书名排版的文字封面。"
                : "这种格式不携带封面图片，可以自己选一张，或使用文字封面。")
        }
    }

    private var letteringSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(BookCoverStyle.allCases) { style in
                        Button {
                            selectedStyle = style
                            onSelectStyle(style)
                        } label: {
                            CoverArtwork(
                                title: previewTitle,
                                author: nil,
                                formatLabel: book.formatLabel,
                                style: style,
                                cornerRadius: 8
                            )
                            .frame(width: 54)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        style == selectedStyle ? Color.accentColor : .clear,
                                        lineWidth: 2.5
                                    )
                                    .padding(-3)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                    }
                }
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("cover.styles")
        } header: {
            Text("文字封面配色")
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("书名", text: $editedTitle)
                .accessibilityIdentifier("cover.title")

            TextField("作者", text: $editedAuthor)
                .accessibilityIdentifier("cover.author")
        } header: {
            Text("书籍信息")
        } footer: {
            Text("书名和作者同时用于书架显示和文字封面。")
        }
    }

    private var previewTitle: String {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? book.title : trimmed
    }

    /// Mirrors the edits so the lettering preview updates while typing, while
    /// keeping the cover identity so a loaded picture is not decoded again.
    private var previewBook: LibraryBookPresentation {
        let trimmedAuthor = editedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryBookPresentation(
            id: book.id,
            title: previewTitle,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor,
            format: book.format,
            progress: book.progress,
            activityLabel: book.activityLabel,
            storedRelativePath: book.storedRelativePath,
            fileByteCount: book.fileByteCount,
            coverURL: book.coverURL,
            coverStyle: selectedStyle ?? book.coverStyle,
            coverSource: book.coverSource,
            coverUpdatedAt: book.coverUpdatedAt
        )
    }

    private var sourceLabel: String {
        guard book.coverURL != nil, let coverSource = book.coverSource else {
            return BookCoverSource.generated.title
        }
        return coverSource.title
    }

    private func loadPhoto(_ selection: PhotosPickerItem) async {
        localErrorMessage = nil
        defer { photoSelection = nil }

        guard let data = try? await selection.loadTransferable(type: Data.self),
              !data.isEmpty
        else {
            localErrorMessage = String(localized: "无法读取这张照片，请换一张。")
            return
        }
        onPickImageData(data)
    }

    private func handleImageFileResult(_ result: Result<[URL], any Error>) {
        localErrorMessage = nil

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty
            else {
                localErrorMessage = String(localized: "无法读取这个图片文件，请换一个。")
                return
            }
            onPickImageData(data)

        case .failure(let error):
            let nsError = error as NSError
            guard nsError.domain != NSCocoaErrorDomain
                || nsError.code != NSUserCancelledError
            else {
                return
            }
            localErrorMessage = error.localizedDescription
        }
    }
}

#Preview("Lettering cover") {
    BookCoverEditorView(
        book: LibraryBookPresentation.previews[1],
        canDetect: false
    )
}

#Preview("Detected cover") {
    BookCoverEditorView(
        book: LibraryBookPresentation.previews[0],
        canDetect: true
    )
}
