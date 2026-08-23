import Foundation
import SwiftUI

enum MarkdownRenderer {
    private static let cache = NSCache<NSString, NSAttributedString>()

    private enum RenderingMode: String {
        case inline
        case block
    }

    static func renderInline(_ text: String) -> AttributedString? {
        let normalized = preserveSpacing(text)
        let mode = renderingMode(for: normalized)
        let key = cacheKey(for: normalized, mode: mode)
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: mode == .block ? .full : .inlineOnlyPreservingWhitespace
        )

        guard let attributed = try? AttributedString(
            markdown: normalized,
            options: options
        ) else {
            return nil
        }

        let styled = styleLinks(in: attributed)
        cache.setObject(NSAttributedString(styled), forKey: key)
        return styled
    }

    static func prewarmInline(_ text: String) {
        _ = renderInline(text)
    }

    static func renderPreservingLineBreaks(_ text: String) -> AttributedString? {
        let normalized = preserveSpacing(text)
        let parts = normalized.components(separatedBy: "\n")
        var combined = AttributedString()

        for (index, part) in parts.enumerated() {
            if index > 0 {
                combined += AttributedString("\n")
            }

            guard !part.isEmpty else { continue }

            if let rendered = renderInline(part) {
                combined += rendered
            } else {
                combined += AttributedString(part)
            }
        }

        return combined
    }

    private static func styleLinks(in attributed: AttributedString) -> AttributedString {
        var styled = attributed
        let linkRuns = styled.runs
            .filter { $0.link != nil }
            .sorted { $0.range.lowerBound > $1.range.lowerBound }

        for run in linkRuns {
            guard let url = run.link else { continue }
            let visibleText = String(styled[run.range].characters)
            let displayText = displayText(for: visibleText, url: url)

            if displayText != visibleText {
                var replacement = AttributedString(displayText)
                replacement.link = url
                replacement.foregroundColor = .primary
                replacement.underlineStyle = .single
                replacement.font = .system(size: 16, weight: .semibold)
                styled.replaceSubrange(run.range, with: replacement)
            } else {
                styled[run.range].foregroundColor = .primary
                styled[run.range].underlineStyle = .single
                styled[run.range].font = .system(size: 16, weight: .semibold)
            }
        }
        return styled
    }

    private static func displayText(for visibleText: String, url: URL) -> String {
        let trimmed = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !looksLikeRawURL(trimmed) {
            return trimmed
        }

        if let host = url.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression),
           !host.isEmpty {
            return host
        }

        return trimmed
            .replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeRawURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("www.")
    }

    private static func preserveSpacing(_ text: String) -> String {
        // убираем только реально лишние артефакты стрима, но сохраняем смысловые пробелы и переносы
        let result = text

        // If text already looks like markdown, avoid aggressive normalization
        if text.contains("**") || text.contains(">") || text.contains("- ") || text.contains("```") {
            return text
        }

        // заменяем множественные пробелы на один (но не трогаем переносы строк)

        // IMPORTANT: keep newline boundaries intact to avoid merging sentences in rendered output

        return result
    }

    private static func renderingMode(for text: String) -> RenderingMode {
        if text.contains("\n") {
            return .block
        }
        if looksLikeBlockMarkdown(text) {
            return .block
        }
        return .inline
    }

    private static func looksLikeBlockMarkdown(_ text: String) -> Bool {
        if text.contains("\n\n") { return true }
        if text.contains("```") { return true }
        if text.contains("\n- ") || text.contains("\n* ") || text.contains("\n• ") { return true }
        if text.contains("\n1. ") || text.contains("\n2. ") || text.contains("\n3. ") { return true }
        if text.contains("\n# ") || text.contains("\n## ") || text.contains("\n### ") { return true }
        if text.contains("\n> ") { return true }
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("• ") { return true }
        if text.hasPrefix("1. ") || text.hasPrefix("2. ") || text.hasPrefix("3. ") { return true }
        if text.hasPrefix("# ") || text.hasPrefix("## ") || text.hasPrefix("### ") { return true }
        return false
    }

    private static func cacheKey(for text: String, mode: RenderingMode) -> NSString {
        "\(mode.rawValue)|\(text)" as NSString
    }
}
