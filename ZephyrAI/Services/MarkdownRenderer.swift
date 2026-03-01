import Foundation
import SwiftUI

enum MarkdownRenderer {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func renderInline(_ text: String) -> AttributedString? {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }

        guard let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return nil
        }

        cache.setObject(NSAttributedString(attributed), forKey: key)
        return attributed
    }

    static func prewarmInline(_ text: String) {
        _ = renderInline(text)
    }
}
