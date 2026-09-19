import Foundation
import Testing
@testable import ImmerseRead

struct PDFReadingLocationTests {
    @Test
    func startsInReflowWithIndependentEmptyBookmarks() {
        let location = PDFReadingLocation()

        #expect(location.mode == .reflow)
        #expect(location.progress(for: .reflow) == 0)
        #expect(location.progress(for: .original) == 0)
    }

    @Test
    func switchingModesDoesNotOverwriteEitherBookmark() {
        var location = PDFReadingLocation()
        location.updateProgress(0.42, for: .reflow)

        location.mode = .original
        location.updateProgress(0, for: .original)
        #expect(location.reflowProgress == 0.42)

        location.updateProgress(0.8, for: .original)
        location.mode = .reflow
        #expect(location.progress(for: location.mode) == 0.42)
        #expect(location.originalProgress == 0.8)

        location.updateProgress(0.47, for: .reflow)
        #expect(location.originalProgress == 0.8)
    }

    @Test
    func lateOriginalCallbackDoesNotSelectOriginalMode() {
        var location = PDFReadingLocation(mode: .reflow, reflowProgress: 0.42)

        location.updateProgress(0.8, for: .original)

        #expect(location.mode == .reflow)
        #expect(location.reflowProgress == 0.42)
        #expect(location.originalProgress == 0.8)
    }

    @Test(arguments: [PDFReadingMode.reflow, .original])
    func serializingAndReopeningPreservesBothBookmarksAndTheSelectedMode(
        mode: PDFReadingMode
    ) throws {
        let expected = PDFReadingLocation(
            mode: mode,
            reflowProgress: 0.42,
            originalProgress: 0.8
        )
        let data = try #require(expected.encoded())

        let restored = PDFReadingLocation.restore(from: data, legacyOriginalProgress: 0.05)

        #expect(restored == expected)
        #expect(restored.progress(for: .reflow) == 0.42)
        #expect(restored.progress(for: .original) == 0.8)
    }

    @Test
    func serializationIncludesAnExplicitSchemaVersion() throws {
        let data = try #require(PDFReadingLocation().encoded())
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["version"] as? Int == 1)
        #expect(payload["mode"] as? String == "reflow")
        #expect(payload["reflowProgress"] as? Double == 0)
        #expect(payload["originalProgress"] as? Double == 0)
    }

    @Test
    func legacyPageProgressMigratesOnlyToTheOriginalBookmark() {
        let restored = PDFReadingLocation.restore(from: nil, legacyOriginalProgress: 0.75)

        #expect(restored.mode == .reflow)
        #expect(restored.reflowProgress == 0)
        #expect(restored.originalProgress == 0.75)
    }

    @Test
    func unsupportedVersionsFallBackToLegacyPageProgressWithoutUsingForeignBookmarks() {
        for version in [-1, 0, 2, 999] {
            let data = Data("""
            {"version":\(version),"mode":"original","reflowProgress":0.42,"originalProgress":0.8}
            """.utf8)

            let restored = PDFReadingLocation.restore(from: data, legacyOriginalProgress: 0.25)

            #expect(restored == PDFReadingLocation(originalProgress: 0.25))
        }
    }

    @Test
    func malformedOrIncompleteSavedDataFallsBackSafely() {
        let malformedPayloads = [
            "not JSON",
            "",
            "null",
            "[]",
            "{}",
            #"{"mode":"reflow","reflowProgress":0.4,"originalProgress":0.8}"#,
            #"{"version":1,"mode":"unknown","reflowProgress":0.4,"originalProgress":0.8}"#,
            #"{"version":1,"mode":"reflow","reflowProgress":"bad","originalProgress":0.8}"#,
            #"{"version":1,"mode":"reflow","reflowProgress":null,"originalProgress":0.8}"#,
            #"{"version":1,"mode":"reflow","reflowProgress":0.4}"#,
            #"{"version":1,"mode":"reflow","reflowProgress":NaN,"originalProgress":0.8}"#,
        ]

        for payload in malformedPayloads {
            let restored = PDFReadingLocation.restore(
                from: Data(payload.utf8),
                legacyOriginalProgress: 0.25
            )

            #expect(restored == PDFReadingLocation(originalProgress: 0.25))
        }
    }

    @Test
    func clampsInitializerUpdateAndLegacyMigrationInputs() {
        let cases: [(input: Double, expected: Double)] = [
            (.nan, 0),
            (.infinity, 0),
            (-.infinity, 0),
            (-1, 0),
            (0, 0),
            (0.42, 0.42),
            (1, 1),
            (2, 1),
        ]

        for testCase in cases {
            var location = PDFReadingLocation(
                reflowProgress: testCase.input,
                originalProgress: testCase.input
            )
            #expect(location.reflowProgress == testCase.expected)
            #expect(location.originalProgress == testCase.expected)

            location.updateProgress(0.6, for: .reflow)
            location.updateProgress(testCase.input, for: .original)
            #expect(location.reflowProgress == 0.6)
            #expect(location.originalProgress == testCase.expected)

            location.updateProgress(0.7, for: .original)
            location.updateProgress(testCase.input, for: .reflow)
            #expect(location.reflowProgress == testCase.expected)
            #expect(location.originalProgress == 0.7)

            let migrated = PDFReadingLocation.restore(
                from: nil,
                legacyOriginalProgress: testCase.input
            )
            #expect(migrated.reflowProgress == 0)
            #expect(migrated.originalProgress == testCase.expected)
        }
    }

    @Test
    func clampsOutOfRangeNumbersReadFromSavedData() {
        let data = Data(#"{"version":1,"mode":"original","reflowProgress":-0.5,"originalProgress":4}"#.utf8)

        let restored = PDFReadingLocation.restore(from: data, legacyOriginalProgress: 0.2)

        #expect(restored.mode == .original)
        #expect(restored.reflowProgress == 0)
        #expect(restored.originalProgress == 1)
    }

    @Test
    func customDecodersCannotIntroduceNonfiniteProgress() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        for value in ["NaN", "Infinity", "-Infinity"] {
            let data = Data("""
            {"version":1,"mode":"reflow","reflowProgress":"\(value)","originalProgress":"\(value)"}
            """.utf8)
            let decoded = try decoder.decode(PDFReadingLocation.self, from: data)

            #expect(decoded.reflowProgress == 0)
            #expect(decoded.originalProgress == 0)
            #expect(decoded.encoded() != nil)
        }
    }
}
