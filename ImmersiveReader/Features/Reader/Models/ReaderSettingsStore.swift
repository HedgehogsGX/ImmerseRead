import Foundation

@MainActor
enum ReaderSettingsStore {
    private enum Key {
        static let layoutMode = "reader.settings.layoutMode"
        static let fontSize = "reader.settings.fontSize"
        static let lineHeight = "reader.settings.lineHeight"
        static let theme = "reader.settings.theme"
    }

    static func load(from defaults: UserDefaults = .standard) -> ReaderDisplaySettings {
        var settings = ReaderDisplaySettings.default

        if let rawLayoutMode = defaults.string(forKey: Key.layoutMode),
           let layoutMode = ReaderLayoutMode(rawValue: rawLayoutMode) {
            settings.layoutMode = layoutMode
        }
        if defaults.object(forKey: Key.fontSize) != nil {
            settings.fontSize = defaults.double(forKey: Key.fontSize)
                .clamped(to: ReaderDisplaySettings.fontSizeRange)
        }
        if defaults.object(forKey: Key.lineHeight) != nil {
            settings.lineHeightMultiple = defaults.double(forKey: Key.lineHeight)
                .clamped(to: ReaderDisplaySettings.lineHeightRange)
        }
        if let rawTheme = defaults.string(forKey: Key.theme),
           let theme = ReaderTheme(rawValue: rawTheme) {
            settings.theme = theme
        }

        return settings
    }

    static func save(
        _ settings: ReaderDisplaySettings,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(settings.layoutMode.rawValue, forKey: Key.layoutMode)
        defaults.set(
            settings.fontSize.clamped(to: ReaderDisplaySettings.fontSizeRange),
            forKey: Key.fontSize
        )
        defaults.set(
            settings.lineHeightMultiple.clamped(to: ReaderDisplaySettings.lineHeightRange),
            forKey: Key.lineHeight
        )
        defaults.set(settings.theme.rawValue, forKey: Key.theme)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else {
            return range.lowerBound
        }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
