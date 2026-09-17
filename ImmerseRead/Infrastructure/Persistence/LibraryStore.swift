import Foundation
import SwiftData

/// Opens the library database.
///
/// The store keeps its default location, `Application Support/default.store`,
/// alongside the imported documents in `Application Support/Books`. Installing
/// a new build over an old one replaces the app bundle and leaves that
/// container untouched, so shelves, covers and reading positions carry across
/// an update from TestFlight or the App Store. Moving the store, or naming it,
/// would strand every library already on a device.
enum LibraryStore {
    static let schema = Schema(versionedSchema: LibrarySchemaV1.self)

    static var defaultConfiguration: ModelConfiguration {
        ModelConfiguration(schema: schema)
    }

    static func makeContainer(
        configuration: ModelConfiguration = defaultConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: LibraryMigrationPlan.self,
            configurations: configuration
        )
    }
}

/// Holds the opened database for the app, and the reason when it cannot open.
///
/// A store that refuses to open is never erased or replaced with an empty one:
/// the documents are still on disk, and a later build — or simply a retry — can
/// still reach them. Starting over would silently discard the whole shelf.
@MainActor
@Observable
final class LibraryStoreLoader {
    enum State {
        case ready(ModelContainer)
        case unavailable(String)
    }

    private(set) var state: State
    private let makeContainer: () throws -> ModelContainer

    init(makeContainer: @escaping () throws -> ModelContainer = { try LibraryStore.makeContainer() }) {
        self.makeContainer = makeContainer
        state = Self.load(makeContainer)
    }

    func reload() {
        state = Self.load(makeContainer)
    }

    private static func load(_ makeContainer: () throws -> ModelContainer) -> State {
        do {
            return .ready(try makeContainer())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
