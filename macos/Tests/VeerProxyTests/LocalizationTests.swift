import Foundation
import Testing

/// Every piece of Chinese interface text in the app has an English translation. Keys are the
/// Chinese text with each interpolation as a format specifier; both sides are compared with the
/// specifiers reduced to `%`, since the source does not say which type a value has.
struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Interface code; sample data in the snapshot runner is not interface text.
    static let sources = ["Sources/VeerApp", "Sources/VeerProxy", "Sources/VeerUI"]
    static let skipped: Set<String> = ["SnapshotRunner.swift"]

    static func table(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/Localization/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: #"%(\d+\$)?(lld|ld|d|@|lf|f)"#, with: "%", options: .regularExpression)
    }

    /// Chinese string literals in interface code, interpolations reduced to `%`.
    static func sourceKeys() throws -> [String: String] {
        let literal = try Regex(#""((?:[^"\\]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*)""#)
        let interpolation = try Regex(#"\\\((?:[^()]|\([^()]*\))*\)"#)
        var keys: [String: String] = [:]
        for directory in sources {
            let folder = root.appendingPathComponent(directory)
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") && !skipped.contains(file) {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    for match in line.matches(of: literal) {
                        let body = String(line[match.range].dropFirst().dropLast())
                        guard body.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { continue }
                        keys[body.replacing(interpolation, with: "%")] = "\(file):\(number + 1)"
                    }
                }
            }
        }
        return keys
    }

    @Test func everyInterfaceStringHasAnEnglishTranslation() throws {
        let english = Set(try Self.table("en").keys.map(Self.normalized))
        let keys = try Self.sourceKeys()
        // The scan itself works: the app has well over a hundred strings.
        #expect(keys.count > 100)
        let missing = keys.filter { !english.contains($0.key) }.map { "\($0.value)  \($0.key)" }.sorted()
        #expect(missing.isEmpty, "Missing from en.lproj/Localizable.strings:\n\(missing.joined(separator: "\n"))")
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for (key, value) in try Self.table("en") {
            let count = { (text: String) in text.matches(of: try! Regex(#"%(\d+\$)?(lld|ld|d|@)"#)).count }
            #expect(count(key) == count(value), "\(key) → \(value)")
        }
    }

    @Test func theChineseTableExistsSoTheLanguageIsOffered() throws {
        #expect(try Self.table("zh-Hans").isEmpty)
    }
}
