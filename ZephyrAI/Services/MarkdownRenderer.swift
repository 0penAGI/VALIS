import Foundation
import SwiftUI

enum MarkdownRenderer {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    private enum RenderingMode: String {
        case inline
        case block
    }

    static func renderInline(
        _ text: String,
        cacheResult: Bool = true,
        linkifyURLs: Bool = true
    ) -> AttributedString? {
        let input = linkifyURLs ? linkifyBareURLs(in: text) : text
        let normalized = preserveSpacing(input)
        let mode = renderingMode(for: normalized)
        let key = cacheKey(for: normalized, mode: mode)
        if cacheResult, let cached = cache.object(forKey: key) {
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
        if cacheResult {
            cache.setObject(
                NSAttributedString(styled),
                forKey: key,
                cost: max(1, normalized.utf8.count * 4)
            )
        }
        return styled
    }

    static func prewarmInline(_ text: String) {
        _ = renderInline(text)
    }

    static func renderPreservingLineBreaks(
        _ text: String,
        cacheFinalLine: Bool = true
    ) -> AttributedString? {
        let normalized = preserveSpacing(text)
        let parts = normalized.components(separatedBy: "\n")
        var combined = AttributedString()
        var insideCodeFence = false

        for (index, part) in parts.enumerated() {
            if index > 0 {
                combined += AttributedString("\n")
            }

            guard !part.isEmpty else { continue }

            let isFenceMarker = part.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            let shouldLinkifyURLs = !insideCodeFence && !isFenceMarker
            let shouldCacheLine = cacheFinalLine || index != parts.count - 1
            if let rendered = renderInline(
                part,
                cacheResult: shouldCacheLine,
                linkifyURLs: shouldLinkifyURLs
            ) {
                combined += rendered
            } else {
                combined += AttributedString(part)
            }
            if isFenceMarker { insideCodeFence.toggle() }
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

    /// Converts plain-text URLs into Markdown links before parsing so they are
    /// tappable and long URLs do not leak into the visible message text.
    private static func linkifyBareURLs(in text: String) -> String {
        let pattern = #"https?://[^\s<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            var urlRange = match.range
            var urlText = nsText.substring(with: urlRange)
            while let last = urlText.last {
                let isTrailingPunctuation = ".,;:!?]}".contains(last)
                    || (last == ")" && urlText.filter { $0 == "(" }.count < urlText.filter { $0 == ")" }.count)
                guard isTrailingPunctuation else { break }
                urlText.removeLast()
                urlRange.length -= 1
            }
            guard !urlText.isEmpty, let url = URL(string: urlText) else { continue }

            let prefixRange = NSRange(location: 0, length: urlRange.location)
            let prefix = nsText.substring(with: prefixRange)

            // Leave URLs inside existing Markdown links and inline code alone.
            if prefix.hasSuffix("](") { continue }
            if prefix.hasSuffix("<"), NSMaxRange(match.range) < nsText.length,
               nsText.substring(from: NSMaxRange(match.range)).hasPrefix(">") { continue }
            if prefix.filter({ $0 == "`" }).count % 2 == 1 { continue }

            let separatorCandidates = [" – ", " — ", " - ", ": "]
            let sourceSeparator = separatorCandidates
                .compactMap { separator -> (NSRange, String)? in
                    let range = (prefix as NSString).range(of: separator, options: .backwards)
                    return range.location == NSNotFound ? nil : (range, separator)
                }
                .max { $0.0.location < $1.0.location }

            let replacementRange: NSRange
            let displayText: String
            if let (separatorRange, _) = sourceSeparator {
                let labelStart = NSMaxRange(separatorRange)
                let labelRange = NSRange(location: labelStart, length: prefixRange.length - labelStart)
                let label = (prefix as NSString).substring(with: labelRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    replacementRange = NSRange(
                        location: separatorRange.location,
                        length: urlRange.location + urlRange.length - separatorRange.location
                    )
                    displayText = "[\(label)](\(urlText))"
                } else {
                    replacementRange = urlRange
                    displayText = "[\(shortHost(for: url))](\(urlText))"
                }
            } else {
                replacementRange = urlRange
                displayText = "[\(shortHost(for: url))](\(urlText))"
            }

            output.replaceCharacters(in: replacementRange, with: displayText)
        }
        return output as String
    }

    private static func shortHost(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return "Open source" }
        return host.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
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
