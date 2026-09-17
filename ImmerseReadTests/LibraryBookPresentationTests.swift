import Foundation
import Testing
@testable import ImmerseRead

struct LibraryBookPresentationTests {
    @Test
    func includesAuthorInShelfAccessibilityMetadata() {
        let presentation = LibraryBookPresentation(
            id: UUID(),
            title: "书名",
            author: "作者",
            format: .epub,
            progress: 0.25,
            activityLabel: "刚刚读过",
            storedRelativePath: "book/original.epub"
        )

        #expect(presentation.accessibilityLabel.contains("书名，作者"))
        #expect(presentation.accessibilityLabel.contains("EPUB"))
        #expect(presentation.isInProgress)
    }

    @Test
    func describesReadingStateAtTheEdges() {
        let untouched = LibraryBookPresentation(
            id: UUID(),
            title: "未读",
            format: .pdf,
            progress: 0,
            activityLabel: "今天导入",
            storedRelativePath: "book/original.pdf"
        )
        let finished = LibraryBookPresentation(
            id: UUID(),
            title: "读完",
            format: .pdf,
            progress: 1,
            activityLabel: "昨天读过",
            storedRelativePath: "book/original.pdf"
        )

        #expect(!untouched.hasStarted)
        #expect(!untouched.isInProgress)
        #expect(finished.isFinished)
        #expect(!finished.isInProgress)
    }

    @Test
    func coverIdentityFollowsTheStoredCover() {
        let id = UUID()
        let coverURL = URL(fileURLWithPath: "/covers/\(id.uuidString)/cover.jpg")
        func presentation(
            coverURL: URL?,
            coverUpdatedAt: Date?
        ) -> LibraryBookPresentation {
            LibraryBookPresentation(
                id: id,
                title: "书名",
                format: .epub,
                progress: 0,
                activityLabel: "今天导入",
                storedRelativePath: "book/original.epub",
                coverURL: coverURL,
                coverUpdatedAt: coverUpdatedAt
            )
        }

        let unresolved = presentation(
            coverURL: nil,
            coverUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let first = presentation(
            coverURL: coverURL,
            coverUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let replaced = presentation(
            coverURL: coverURL,
            coverUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        // Resolving the stored file has to reload the shelf's cover, and so
        // does replacing it.
        #expect(unresolved.coverIdentity != first.coverIdentity)
        #expect(first.coverIdentity != replaced.coverIdentity)
        #expect(first.coverIdentity == presentation(
            coverURL: coverURL,
            coverUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        ).coverIdentity)
    }

    @Test
    func letteringStyleIsStableForTheSameBook() {
        let style = BookCoverStyle.automatic(for: "瓦尔登湖|梭罗")
        #expect(BookCoverStyle.automatic(for: "瓦尔登湖|梭罗") == style)
        #expect(BookCoverStyle.allCases.contains(style))
    }
}
