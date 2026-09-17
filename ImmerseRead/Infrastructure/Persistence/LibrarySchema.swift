import Foundation
import SwiftData

/// The shape of the library database as it ships today.
///
/// Naming the schema is what makes a future release upgradeable: SwiftData can
/// only migrate a store when it knows which version wrote it. An unnamed model
/// leaves every update relying on implicit inference, and the first change it
/// cannot infer would leave installed copies unable to open their own library.
enum LibrarySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [Book.self] }
}

/// The ordered list of schemas an installed copy may be coming from.
///
/// Adding a version means appending its `VersionedSchema` here together with a
/// stage that describes the step, so a reader who skipped releases still walks
/// from their version to the current one. Never renumber or remove a published
/// version: that path is what an old install follows home.
enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}
