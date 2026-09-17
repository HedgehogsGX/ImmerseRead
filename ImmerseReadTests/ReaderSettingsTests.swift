import Foundation
import Testing

@testable import ImmerseRead

struct ReaderSettingsTests {
    @Test @MainActor
    func newTypographySettingsRoundTripThroughUserDefaults() throws {
        let suiteName = "ReaderTypographySettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = ReaderDisplaySettings(
            fontFamily: .serif,
            margin: 36
        )
        ReaderSettingsStore.save(expected, to: defaults)

        let restored = ReaderSettingsStore.load(from: defaults)
        #expect(restored.fontFamily == .serif)
        #expect(restored.margin == 36)
    }

    @Test @MainActor
    func missingTypographySettingsUseBackwardsCompatibleDefaults() throws {
        let suiteName = "ReaderLegacySettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(24, forKey: "reader.settings.fontSize")
        defaults.set(1.8, forKey: "reader.settings.lineHeight")

        let restored = ReaderSettingsStore.load(from: defaults)
        #expect(restored.fontFamily == .system)
        #expect(restored.margin == ReaderDisplaySettings.default.margin)
        #expect(restored.fontSize == 24)
        #expect(restored.lineHeightMultiple == 1.8)
    }

    @Test @MainActor
    func typographySettingsClampInvalidMargins() throws {
        let suiteName = "ReaderMarginRangeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(100, forKey: "reader.settings.margin")
        #expect(ReaderSettingsStore.load(from: defaults).margin == 48)

        defaults.set(1, forKey: "reader.settings.margin")
        #expect(ReaderSettingsStore.load(from: defaults).margin == 12)
    }
}
