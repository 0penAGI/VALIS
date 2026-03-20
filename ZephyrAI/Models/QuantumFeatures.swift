import Foundation

enum QuantumFeatures {
    static let memorySearchEnabledKey = "quantum.memorySearch.enabled"
    static let snippetParserEnabledKey = "quantum.snippetParser.enabled"

    static func isMemorySearchEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: memorySearchEnabledKey) as? Bool ?? true
    }

    static func isSnippetParserEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: snippetParserEnabledKey) as? Bool ?? true
    }
}
