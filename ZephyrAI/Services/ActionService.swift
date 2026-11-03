import Foundation
import EventKit
import WeatherKit
import CoreMotion
import CoreLocation
@preconcurrency import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ActionService {
    static let shared = ActionService()

    struct WebImageCandidate {
        let query: String
        let imageURL: URL
        let title: String
        let sourcePageURL: URL?
    }

    private struct PreparedSearchCandidate {
        let query: String
        let summary: String
        let wikipediaSummary: String
        let results: [SearchResult]
        let trustedEvidence: [String]
        let reliability: SearchReliability
        let numericConflict: Bool
        let sourceDisagreement: Bool

        var score: Int {
            var total = 0

            // stronger reliability weighting
            switch reliability {
            case .high: total += 40
            case .medium: total += 20
            case .low: total += 5
            }

            // more sources = better (bounded)
            total += min(results.count, 5) * 4

            // trusted sources are critical
            total += min(trustedEvidence.count, 4) * 10

            let hasWiki = !wikipediaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasDDG = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // consensus priority
            if hasWiki && hasDDG {
                total += 20
            } else if hasWiki {
                total += 10
            } else if hasDDG {
                total += 5
            }

            // hard penalties for conflicts
            if sourceDisagreement { total -= 10 }
            if numericConflict { total -= 12 }

            return total
        }
    }

    private enum SearchReliability: String {
        case high
        case medium
        case low
    }

    struct ContextBlock {
        let kind: Kind
        let text: String

        enum Kind {
            case date
            case search
            case news
            case url
            case wiki
            case weather
            case health
            case system
            case error
        }
    }

    struct PreparedContext {
        let blocks: [ContextBlock]

        var isEmpty: Bool {
            blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        var rendered: String {
            blocks
                .filter { $0.kind != .error }
                .map { $0.text }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        func text(for kind: ContextBlock.Kind) -> String? {
            blocks
                .first(where: { $0.kind == kind })?
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? blocks.first(where: { $0.kind == kind })?.text
                : nil
        }

        func hasSuccessBlock(for kind: ContextBlock.Kind) -> Bool {
            blocks.contains { block in
                block.kind == kind &&
                !block.text.lowercased().contains("signal error") &&
                !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    struct ActionCall {
        let name: String
        let query: String
        let args: [String: String]

        var signature: String {
            let argsKey = args
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ";")
            return "\(name)|\(query)|\(argsKey)"
        }
    }

    private let multiSearchProvider = MultiSearchProvider.makeDefault()
    private let eventStore = EKEventStore()
    private let memoryService = MemoryService.shared
    private var urlAnalysisCache: [String: (text: String, timestamp: Date)] = [:]
    private var urlValidationCache: [String: (isValid: Bool, timestamp: Date)] = [:]
    private let preparedContextCache = NSCache<NSString, NSString>()
    private let urlCacheTTL: TimeInterval = 900

    private init() {}

    // MARK: - Public API

    func buildToolGuidanceBlock(hasTools: Bool) -> String {
        if hasTools {
            return """
Use the provided context to answer. Be direct and specific. Do not emit tool calls.
Prefer local iPhone sources first: weather, device/system info, health/activity, calendar, reminders, and open_url when the user gave a URL.
Use web_search only for external facts that local iPhone APIs cannot answer.
"""
        }
        return """
Answer from your knowledge. Be direct and specific.
Prefer local iPhone sources first when they can answer the request: weather, device/system info, health/activity, calendar, reminders, and open_url for explicit URLs.
"""
    }

    func buildNewsToolPrimerBlock() -> String {
        """
For news, headlines, breaking stories, current events, and "что нового", the system automatically fetches RSS news from BBC, HN, and other sources. Answer from the fetched context. If no context is available, answer from your knowledge. NEVER ask for links.
"""
    }

    func parseCall(from text: String) -> ActionCall? {
        if let parsed = parseXMLStyleCall(from: text) {
            return parsed
        }

        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let parsed = parseCallLine(line) {
                return parsed
            }
        }

        // Fallback: inline occurrence in a single paragraph.
        let inlinePattern = "(?i)(?:TOOL|ACTION)\\s*:\\s*([^\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: inlinePattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let payloadRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return parseCallPayload(String(text[payloadRange]))
    }

    private func parseXMLStyleCall(from text: String) -> ActionCall? {
        let pattern = #"(?is)<\s*(web_search|wikipedia|rss_news|date|analyze_url|open_url|calendar|weather|health|system|tool|action)\s*>(.*?)\s*(?:</\s*\1\s*>)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let name = normalizeToolName(String(text[nameRange]))
        let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if name == "tool" || name == "action" {
            return parseCallPayload(body)
        }

        let flattenedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return parseCallPayload("\(name) \(flattenedBody)")
    }

    private func parseCallLine(_ line: String) -> ActionCall? {
        let lower = line.lowercased()
        guard lower.hasPrefix("tool:") || lower.hasPrefix("action:") else { return nil }

        guard let colon = line.firstIndex(of: ":") else { return nil }
        let payload = line[line.index(after: colon)...]
        return parseCallPayload(String(payload))
    }

    private func parseCallPayload(_ payload: String) -> ActionCall? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawName: String
        let rawArgs: String

        if let pipe = trimmed.firstIndex(of: "|") {
            rawName = String(trimmed[..<pipe]).trimmingCharacters(in: .whitespacesAndNewlines)
            rawArgs = String(trimmed[trimmed.index(after: pipe)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            rawName = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            rawArgs = String(inside).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            rawName = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            rawArgs = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        let name = normalizeToolName(rawName)
        guard !name.isEmpty else { return nil }

        let args = parseArgs(rawArgs)
        var query = ""
        if let q = args["query"], !q.isEmpty {
            query = q
        } else if let q = args["q"], !q.isEmpty {
            query = q
        } else if let u = args["url"], !u.isEmpty {
            query = u
        } else if rawArgs.lowercased().hasPrefix("query=") {
            query = String(rawArgs.dropFirst("query=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            query = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ActionCall(name: name, query: query, args: args)
    }

    private func normalizeToolName(_ raw: String) -> String {
        let key = raw
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "news", "reddit", "redditnews", "reddit_news", "rss_news", "rss", "feed":
            return "rss_news"
        case "wiki", "wikipedia", "wikipedia_search", "wiki_search", "encyclopedia":
            return "wikipedia"
        case "search", "web", "websearch", "internet_search", "browse", "web_search":
            return "web_search"
        case "analyze_url", "url_analyze", "analyze_link", "link_analyze", "read_url", "summarize_url":
            return "analyze_url"
        case "openurl", "open_url", "url", "url_open":
            return "open_url"
        case "calendar", "open_calendar", "calendar_event", "event":
            return "calendar"
        case "date", "time", "today_date":
            return "date"
        case "weather", "forecast", "погода", "прогноз":
            return "weather"
        case "health", "steps", "pedometer", "шаги", "активность":
            return "health"
        case "system", "device", "battery", "storage", "устройство", "батарея":
            return "system"
        default:
            return key
        }
    }

    func context(for call: ActionCall) async -> String {
        switch call.name {
        case "date":
            return buildDateContextBlock()
        case "wikipedia":
            let topic = call.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else {
                return buildToolErrorBlock(toolName: "wikipedia", message: "Empty query.")
            }
            let wikiSummary = await fetchWikipediaSummary(topic: topic)
            guard !wikiSummary.isEmpty else {
                return buildToolErrorBlock(toolName: "wikipedia", message: "Wikipedia summary unavailable.")
            }
            ingestExternalSnippets(text: wikiSummary, source: "wikipedia", query: topic)
            return buildWikipediaContextBlock(topic: topic, summary: wikiSummary)
        case "web_search":
            let q = call.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                return buildToolErrorBlock(toolName: "web_search", message: "Empty query.")
            }
            let webContext = await buildPreparedSearchContext(for: q)
            if !webContext.isEmpty {
                return webContext
            }
            return buildToolErrorBlock(toolName: "web_search", message: "Web search unavailable (network error).")
        case "analyze_url":
            return await runAnalyzeURLTool(call: call)
        case "rss_news":
            let news = await fetchRSSNews(limit: 8, query: call.query)
            if !news.isEmpty {
                return buildNewsContextBlock(from: news, query: call.query)
            }
            return buildToolErrorBlock(toolName: "rss_news", message: "No news items returned from RSS feeds.")
        case "open_url", "url":
            return await runOpenURLAction(call: call)
        case "calendar", "open_calendar":
            return await runCalendarAction(call: call)
        case "weather":
            return await runWeatherAction(call: call)
        case "health":
            return await runHealthAction(call: call)
        case "system":
            return await runSystemAction(call: call)
        default:
            return buildToolErrorBlock(toolName: call.name, message: "Unknown tool.")
        }
    }

    func aggregateRuleBasedContext(for prompt: String) async -> PreparedContext {
        let intent = IntentRouter.classify(prompt)
        print("[SearchDiag] prompt=\(prompt.prefix(80)) search=\(intent.search) news=\(intent.news) wiki=\(intent.wiki)")

        async let dateTask: String = buildDateContextBlock()
        async let weatherTask: String = {
            guard intent.weather else { return "" }
            let location = self.extractWeatherLocationCandidate(from: prompt)
            let args = location.map { ["location": $0] } ?? [:]
            return await self.runWeatherAction(call: ActionCall(name: "weather", query: prompt, args: args))
        }()
        async let healthTask: String = {
            guard intent.health else { return "" }
            return await self.runHealthAction(call: ActionCall(name: "health", query: prompt, args: [:]))
        }()
        async let systemTask: String = {
            guard intent.system else { return "" }
            return await self.runSystemAction(call: ActionCall(name: "system", query: prompt, args: [:]))
        }()
        async let searchTask: String = {
            guard intent.search || intent.news || intent.wiki else { return "" }
            let result = await self.buildPreparedSearchContext(for: prompt)
            if !result.isEmpty { return result }

            let topic = prompt
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard topic.count >= 3 else { return "" }

            let titles = await self.fetchWikipediaSearchResults(query: topic, limit: 2)
            if let first = titles.first {
                let summary = await self.fetchWikipediaSummary(topic: first)
                if !summary.isEmpty {
                    return await self.buildWikipediaContextBlock(topic: first, summary: summary)
                }
            }
            let directSummary = await self.fetchWikipediaSummary(topic: topic)
            if !directSummary.isEmpty {
                return await self.buildWikipediaContextBlock(topic: topic, summary: directSummary)
            }
            return ""
        }()
        async let newsTask: String = {
            guard intent.news || intent.search else { return "" }
            let news = await self.fetchRSSNews(limit: 8, query: prompt)
            if !news.isEmpty {
                return await self.buildNewsContextBlock(from: news, query: prompt)
            }
            return ""
        }()
        async let urlFetchResults: [(String, String)] = {
            guard !intent.urlAnalysis.isEmpty else { return [] }
            var results: [(String, String)] = []
            for urlString in intent.urlAnalysis {
                guard let url = URL(string: urlString) else { continue }
                let analysis = await self.analyzeURL(url)
                results.append((url.absoluteString, analysis))
            }
            return results
        }()

        let (dateResult, weatherResult, healthResult, systemResult, searchResult, newsResult, rawUrlResults) = await (dateTask, weatherTask, healthTask, systemTask, searchTask, newsTask, urlFetchResults)
        print("[SearchDiag] date=\(dateResult.prefix(40)) weather=\(weatherResult.prefix(40)) search=\(searchResult.prefix(60)) news=\(newsResult.prefix(60))")

        var urlBlocks: [ContextBlock] = []
        for (urlString, analysis) in rawUrlResults {
            if !analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: urlString) {
                ingestExternalSnippets(text: analysis, source: "url", query: urlString)
                urlBlocks.append(ContextBlock(kind: .url, text: buildURLContextBlock(url: url, analysis: analysis)))
            } else {
                urlBlocks.append(ContextBlock(kind: .error, text: buildToolErrorBlock(toolName: "analyze_url", message: "Could not extract meaningful content from \(urlString).")))
            }
        }

        var blocks: [ContextBlock] = []
        if !dateResult.isEmpty {
            blocks.append(ContextBlock(kind: .date, text: dateResult))
        }
        if !weatherResult.isEmpty {
            blocks.append(ContextBlock(kind: .weather, text: weatherResult))
        }
        if !healthResult.isEmpty {
            blocks.append(ContextBlock(kind: .health, text: healthResult))
        }
        if !systemResult.isEmpty {
            blocks.append(ContextBlock(kind: .system, text: systemResult))
        }
        if !searchResult.isEmpty {
            blocks.append(ContextBlock(kind: .search, text: searchResult))
        }
        if !newsResult.isEmpty {
            blocks.append(ContextBlock(kind: .news, text: newsResult))
        }
        blocks.append(contentsOf: urlBlocks)

        return PreparedContext(blocks: blocks)
    }

    func fetchRelevantWebImage(for query: String) async -> WebImageCandidate? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for candidate in searchQueryCandidates(from: trimmed) {
            if let image = await fetchWikipediaImageCandidate(topic: candidate) {
                return image
            }
            if let image = await fetchSearchResultImageCandidate(topic: candidate) {
                return image
            }
        }
        return nil
    }

    func validatedSuggestedURL(from raw: String) async -> URL? {
        guard let url = normalizeURL(raw) else { return nil }
        guard await validateReachableWebURL(url) else { return nil }
        return url
    }

    func autonomousContext(for topic: String) async -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return buildDateContextBlock() }

        var parts: [String] = [buildDateContextBlock()]
        let searchContext = await buildPreparedSearchContext(for: trimmedTopic)
        if !searchContext.isEmpty {
            parts.append(searchContext)
        } else {
            let wiki = await fetchWikipediaSummary(topic: trimmedTopic)
            if !wiki.isEmpty {
                ingestExternalSnippets(text: wiki, source: "wikipedia", query: trimmedTopic)
                parts.append(buildWikipediaContextBlock(topic: trimmedTopic, summary: wiki))
            }
        }
        return parts.joined(separator: "\n")
    }

    func autonomousSnippets(for topic: String) async -> [String] {
        let context = await autonomousContext(for: topic)
        let snippets = context
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { snippet -> String in
                let singleLine = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                return singleLine.count > 320 ? String(singleLine.prefix(320)) + "…" : singleLine
            }
        return Array(snippets.prefix(4))
    }

    // MARK: - Parsing / Blocks

    private func parseArgs(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var out: [String: String] = [:]
        let separators = CharacterSet(charactersIn: ";&,|")
        let parts = trimmed.components(separatedBy: separators)
        for part in parts {
            let token = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = String(token[token.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private func replyLanguageLine(for query: String) -> String {
        guard let code = LanguageRoutingService.detectedNormalizedCode(for: query),
              let name = LanguageRoutingService.displayName(forNormalizedCode: code),
              !name.isEmpty else {
            return "Reply language: same as the user's query."
        }
        return "Reply language: \(name)."
    }

    private func buildPreparedSearchContextBlock(
        query: String,
        summary: String,
        wikipediaSummary: String,
        results: [SearchResult],
        trustedEvidence: [String]
    ) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return "" }

        let reliability = searchReliability(forSummary: summary, wikipediaSummary: wikipediaSummary, results: results)
        let numericConflict = detectNumericConflict(summary: summary, wikipediaSummary: wikipediaSummary, trustedEvidence: trustedEvidence)
        let sourceDisagreement = detectSourceDisagreement(
            summary: summary,
            wikipediaSummary: wikipediaSummary,
            trustedEvidence: trustedEvidence
        )
        var lines: [String] = [
            "Verified tool context:",
            "Query: \(trimmedQuery)",
            replyLanguageLine(for: trimmedQuery),
        ]

        let isLowConfidence = (reliability == .low) || numericConflict

        if isLowConfidence {
            lines.append("Note: evidence is limited. Answer cautiously.")
        }

        let compactSummary = compactSearchSummary(summary)
        if !compactSummary.isEmpty {
            lines.append("Search summary: \(compactSummary)")
        }

        let compactWikipedia = compactSearchSummary(wikipediaSummary)
        if !compactWikipedia.isEmpty {
            lines.append("Wikipedia summary: \(compactWikipedia)")
        }

        if sourceDisagreement {
            lines.append("Source note: different sources describe the topic differently. Present the disagreement instead of collapsing it into one claim.")
        }

        if numericConflict {
            lines.append("Verification note: numeric values differ across sources. Never output a single number without attribution.")
        }

        if containsPopulationIntent(trimmedQuery) {
            lines.append("Verification note: population figures may refer to metro area vs city proper. Name the source and scope.")
        }

        let topResults = results.prefix(3).map { result in
            let host = result.url.host?.lowercased() ?? result.url.absoluteString
            let trust = trustedDomainScore(for: result.url)
            let trustLabel = trust >= 0.85 ? "reference-source" : (trust >= 0.55 ? "reputable-source" : "open-source")
            return "- \(result.title)\n  \(result.url.absoluteString)\n  domain: \(host) · \(trustLabel)"
        }
        if !topResults.isEmpty {
            lines.append("Top results:\n" + topResults.joined(separator: "\n"))
        }

        if !trustedEvidence.isEmpty {
            lines.append("Trusted evidence:\n" + trustedEvidence.joined(separator: "\n"))
        }

        return "\n" + lines.joined(separator: "\n") + "\n"
    }

    func testBuildPreparedSearchContextBlock(query: String, summary: String, wikipediaSummary: String, results: [(title: String, url: URL)], trustedEvidence: [String] = []) -> String {
        buildPreparedSearchContextBlock(
            query: query,
            summary: summary,
            wikipediaSummary: wikipediaSummary,
            results: results.map { SearchResult(title: $0.title, url: $0.url) },
            trustedEvidence: trustedEvidence
        )
    }

    private func buildWikipediaContextBlock(topic: String, summary: String) -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = compactSearchSummary(summary, maxChars: 420)
        guard !trimmedTopic.isEmpty, !trimmedSummary.isEmpty else { return "" }
        return """

Signal context (wikipedia):
Topic: \(trimmedTopic)
Summary: \(trimmedSummary)

"""
    }

    private func buildNewsContextBlock(from newsContext: String, query: String = "") -> String {
        guard !newsContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return """

Signal context (news):
\(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : replyLanguageLine(for: query) + "\n")
\(newsContext)

"""
    }

    private func buildURLContextBlock(url: URL, analysis: String) -> String {
        let trimmed = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

Signal context (url analysis):
URL: \(url.absoluteString)
\(trimmed)

"""
    }

    private func buildToolErrorBlock(toolName: String, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

Signal error (\(toolName)):
\(trimmed)

"""
    }

    private func buildDateContextBlock() -> String {
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let formatted = formatter.string(from: date)

        let isoFormatter = ISO8601DateFormatter()
        let iso = isoFormatter.string(from: date)

        return """

Signal (system time):
Сегодняшняя дата (локально): \(formatted)
ISO‑время: \(iso)

"""
    }

    nonisolated private func extractWeatherLocationCandidate(from prompt: String) -> String? {
        let text = normalizedRuleTriggerText(prompt)
        let patterns = [
            #"(?i)\b(?:weather|forecast|погода|прогноз)\s+(?:in|at|for|в|для)\s+([A-Za-zА-Яа-яЁё0-9\-\s\.,]{2,})$"#,
            #"(?i)\b(?:weather in|forecast in|погода в|прогноз в)\s+([A-Za-zА-Яа-яЁё0-9\-\s\.,]{2,})$"#,
            #"(?i)\b(?:in|at|for|в|для)\s+([A-Za-zА-Яа-яЁё0-9\-\s\.,]{2,})$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let locationRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let location = String(text[locationRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !location.isEmpty {
                return location
            }
        }

        return nil
    }

    private func actionResultBlock(_ title: String, _ message: String) -> String {
        """

Signal action (\(title)):
\(message)

"""
    }

    nonisolated private func normalizedRuleTriggerText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return trimmed }
        let prefixes = [
            "user question:",
            "question:",
            "user prompt:",
            "prompt:",
            "query:"
        ]
        let lowerFirst = first.lowercased()
        guard let prefix = prefixes.first(where: { lowerFirst.hasPrefix($0) }) else {
            return trimmed
        }

        let remainder = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = lines.dropFirst()
        return ([remainder] + tail).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Actions

    private func runOpenURLAction(call: ActionCall) async -> String {
        let rawURL = call.args["url"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? call.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty, let url = URL(string: rawURL) else {
            return buildToolErrorBlock(toolName: "open_url", message: "Invalid or empty URL.")
        }

        guard let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto", "tel", "shortcuts", "calshow", "webcal"].contains(scheme) else {
            return buildToolErrorBlock(toolName: "open_url", message: "URL scheme is not allowed.")
        }

        if ["https", "http"].contains(scheme) {
            guard await validateReachableWebURL(url) else {
                return buildToolErrorBlock(toolName: "open_url", message: "URL looks invalid or unavailable.")
            }
        }

        let opened = await openExternalURL(url)
        if opened {
            return actionResultBlock("open_url", "Opened: \(rawURL)")
        }
        return buildToolErrorBlock(toolName: "open_url", message: "Failed to open URL.")
    }

    private func runAnalyzeURLTool(call: ActionCall) async -> String {
        let rawURL = call.args["url"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? call.query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = normalizeURL(rawURL), isAllowedWebURL(url) else {
            return buildToolErrorBlock(toolName: "analyze_url", message: "Invalid URL. Use http(s) URL.")
        }

        guard await validateReachableWebURL(url) else {
            return buildToolErrorBlock(toolName: "analyze_url", message: "URL looks invalid or unavailable.")
        }

        let analysis = await analyzeURL(url)
        if analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return buildToolErrorBlock(toolName: "analyze_url", message: "Could not extract meaningful content from URL.")
        }

        ingestExternalSnippets(text: analysis, source: "url", query: url.absoluteString)
        return buildURLContextBlock(url: url, analysis: analysis)
    }

    private func runCalendarAction(call: ActionCall) async -> String {
        let rawOp = call.args["op"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawType = call.args["type"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasCreationPayload =
            !(call.args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !(call.args["start"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !(call.args["date"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !call.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let op: String = {
            guard let rawOp, !rawOp.isEmpty else {
                return hasCreationPayload ? "create" : "open"
            }

            switch rawOp {
            case "open", "show", "view":
                return "open"
            case "create", "add", "new", "set", "schedule", "book", "make", "plan",
                 "remind", "reminder", "create_event", "add_event", "new_event", "event":
                return "create"
            case "list", "upcoming", "show_upcoming", "agenda":
                return "list"
            default:
                return rawOp
            }
        }()

        switch op {
        case "open":
            return await openCalendarAtDate(call.args["date"])
        case "create":
            if rawType == "reminder" || rawOp == "remind" || rawOp == "reminder" {
                return await createReminder(call: call)
            }
            return await createCalendarEvent(call: call)
        case "list":
            return await listCalendarEvents(call: call)
        default:
            return buildToolErrorBlock(toolName: "calendar", message: "Unknown op. Use open, create, or list.")
        }
    }

    private func openExternalURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            #if canImport(UIKit)
            UIApplication.shared.open(url, options: [:]) { ok in
                continuation.resume(returning: ok)
            }
            #elseif canImport(AppKit)
            let ok = NSWorkspace.shared.open(url)
            continuation.resume(returning: ok)
            #else
            continuation.resume(returning: false)
            #endif
        }
    }

    private func openCalendarAtDate(_ dateString: String?) async -> String {
        if let dateString, !dateString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let date = parseCalendarDate(dateString) else {
                return buildToolErrorBlock(toolName: "calendar", message: "Invalid date format. Use ISO like 2026-03-01T14:00:00.")
            }
            let seconds = Int(date.timeIntervalSinceReferenceDate)
            if let url = URL(string: "calshow:\(seconds)"), await openExternalURL(url) {
                return actionResultBlock("calendar", "Opened Calendar at \(iso8601String(from: date)).")
            }
            return buildToolErrorBlock(toolName: "calendar", message: "Failed to open Calendar at date.")
        }

        let secondsNow = Int(Date().timeIntervalSinceReferenceDate)
        if let url = URL(string: "calshow:\(secondsNow)"), await openExternalURL(url) {
            return actionResultBlock("calendar", "Opened Calendar.")
        }
        return buildToolErrorBlock(toolName: "calendar", message: "Failed to open Calendar app.")
    }

    private func createCalendarEvent(call: ActionCall) async -> String {
        let access = await requestCalendarAccess()
        guard access else {
            return buildToolErrorBlock(toolName: "calendar", message: "Calendar access denied.")
        }

        let title = (call.args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? call.args["title"]!
            : call.query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return buildToolErrorBlock(toolName: "calendar", message: "create requires title=... or query text.")
        }

        let rawStart = (call.args["start"] ?? call.args["date"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let start: Date
        if !rawStart.isEmpty {
            guard let parsed = resolveCalendarDate(primaryText: rawStart, fallbackText: call.query) else {
                return buildToolErrorBlock(toolName: "calendar", message: "Invalid start date format. Use ISO like 2026-03-01T14:00:00.")
            }
            start = parsed
        } else if let inferred = parseCalendarDate(call.query) {
            start = inferred
        } else {
            start = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
        }

        if start < Date().addingTimeInterval(-300) {
            return buildToolErrorBlock(toolName: "calendar", message: "Start date is in the past. Please provide a future date/time.")
        }

        let duration = max(5, Int(call.args["duration_min"] ?? "60") ?? 60)
        let rawEnd = (call.args["end"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var end: Date
        if !rawEnd.isEmpty {
            guard let parsedEnd = parseCalendarDate(rawEnd) else {
                return buildToolErrorBlock(toolName: "calendar", message: "Invalid end date format. Use ISO like 2026-03-01T15:00:00.")
            }
            end = parsedEnd
        } else {
            end = Calendar.current.date(byAdding: .minute, value: duration, to: start)
                ?? start.addingTimeInterval(Double(duration * 60))
        }

        let allDay = parseBoolean(call.args["all_day"])
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.notes = call.args["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = call.args["location"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if allDay {
            let dayStart = Calendar.current.startOfDay(for: start)
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            event.isAllDay = true
            event.startDate = dayStart
            event.endDate = nextDay
        } else {
            if end <= start {
                end = start.addingTimeInterval(Double(duration * 60))
            }
            event.startDate = start
            event.endDate = end
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            return actionResultBlock(
                "calendar",
                "Created event: \(event.title ?? title)\nStart: \(formatEventDate(event.startDate, allDay: event.isAllDay))"
            )
        } catch {
            return buildToolErrorBlock(toolName: "calendar", message: "Failed to create event: \(error.localizedDescription)")
        }
    }

    private func createReminder(call: ActionCall) async -> String {
        let access = await requestReminderAccess()
        guard access else {
            return buildToolErrorBlock(toolName: "calendar", message: "Reminders access denied.")
        }

        let title = (call.args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? call.args["title"]!
            : call.query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return buildToolErrorBlock(toolName: "calendar", message: "reminder requires title=... or query text.")
        }

        let rawDue = (call.args["due"] ?? call.args["start"] ?? call.args["date"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dueDate: Date? = rawDue.isEmpty
            ? parseCalendarDate(call.query)
            : resolveCalendarDate(primaryText: rawDue, fallbackText: call.query)

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        reminder.notes = call.args["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                in: .current,
                from: dueDate
            )
        }

        do {
            try eventStore.save(reminder, commit: true)
            if let dueDate {
                return actionResultBlock(
                    "calendar",
                    "Created reminder '\(title)' for \(iso8601String(from: dueDate))."
                )
            }
            return actionResultBlock("calendar", "Created reminder '\(title)'.")
        } catch {
            return buildToolErrorBlock(toolName: "calendar", message: "Failed to create reminder: \(error.localizedDescription)")
        }
    }

    private func listCalendarEvents(call: ActionCall) async -> String {
        let access = await requestCalendarAccess()
        guard access else {
            return buildToolErrorBlock(toolName: "calendar", message: "Calendar access denied.")
        }

        let days = max(1, min(30, Int(call.args["days"] ?? "3") ?? 3))
        let limit = max(1, min(15, Int(call.args["limit"] ?? "5") ?? 5))

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days * 86400))
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        if events.isEmpty {
            return actionResultBlock("calendar", "No upcoming events in next \(days) day(s).")
        }

        let lines = events.map { event in
            let when = formatEventDate(event.startDate, allDay: event.isAllDay)
            return "- \(when): \(event.title ?? "(No title)")"
        }
        return actionResultBlock("calendar", "Upcoming events:\n" + lines.joined(separator: "\n"))
    }

    private func requestCalendarAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return true
        case .writeOnly:
            return true
        case .notDetermined:
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestReminderAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return true
        case .writeOnly:
            return true
        case .notDetermined:
            if #available(iOS 17.0, *) {
                return (try? await eventStore.requestFullAccessToReminders()) ?? false
            } else {
                return (try? await eventStore.requestAccess(to: .reminder)) ?? false
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func parseCalendarDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        
        // tomorrow с опечатками
        if lower == "tomorrow" || lower == "tommorow" || lower == "завтра" {
            return composeRelativeDate(dayOffset: 1, sourceText: lower)
        }
        if lower == "today" || lower == "сегодня" {
            return composeRelativeDate(dayOffset: 0, sourceText: lower)
        }
        if lower.contains("tomorrow") || lower.contains("tommorow") || lower.contains("завтра") {
            return composeRelativeDate(dayOffset: 1, sourceText: lower)
        }
        if lower.contains("today") || lower.contains("сегодня") {
            return composeRelativeDate(dayOffset: 0, sourceText: lower)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }

        let isoNoFraction = ISO8601DateFormatter()
        if let d = isoNoFraction.date(from: text) { return d }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy",
            "d MMMM yyyy HH:mm",
            "d MMMM yyyy",
            "d MMM yyyy HH:mm",
            "d MMM yyyy",
            "MMMM d yyyy HH:mm",
            "MMMM d yyyy",
            "MMM d yyyy HH:mm",
            "MMM d yyyy"
        ]
        let locales = [
            Locale(identifier: "en_US_POSIX"),
            Locale(identifier: "ru_RU"),
            Locale.current
        ]
        let formatter = DateFormatter()
        formatter.timeZone = .current
        for locale in locales {
            formatter.locale = locale
            for f in formats {
                formatter.dateFormat = f
                if let d = formatter.date(from: text) { return d }
            }
        }
        if let extracted = extractEmbeddedCalendarDate(from: text) { return extracted }
        return nil
    }

    private func resolveCalendarDate(primaryText: String, fallbackText: String) -> Date? {
        guard let primaryDate = parseCalendarDate(primaryText) else { return nil }
        guard !containsExplicitTime(primaryText),
              let time = extractTimeFromText(fallbackText) else {
            return primaryDate
        }
        return applyingTime(time, to: primaryDate)
    }

    private func applyingTime(_ time: (Int, Int), to date: Date) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.timeZone = .current
        components.hour = time.0
        components.minute = time.1
        components.second = 0
        return Calendar.current.date(from: components)
    }

    private func containsExplicitTime(_ text: String) -> Bool {
        extractTimeFromText(text) != nil
    }

    private func extractEmbeddedCalendarDate(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns: [(String, [String])] = [
            (#"\b\d{1,2}\.\d{1,2}\.\d{4}(?:\s+\d{1,2}:\d{2})?\b"#, ["dd.MM.yyyy HH:mm", "dd.MM.yyyy"]),
            (#"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?\b"#, ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]),
            (#"\b\d{1,2}\s+[A-Za-z]+\s+\d{4}(?:\s+\d{1,2}:\d{2})?\b"#, ["d MMMM yyyy HH:mm", "d MMMM yyyy", "d MMM yyyy HH:mm", "d MMM yyyy"]),
            (#"\b\d{1,2}\s+[А-Яа-яЁё]+\s+\d{4}(?:\s+\d{1,2}:\d{2})?\b"#, ["d MMMM yyyy HH:mm", "d MMMM yyyy", "d MMM yyyy HH:mm", "d MMM yyyy"])
        ]

        for (pattern, formats) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let matchRange = Range(match.range, in: trimmed) else { continue }
            let snippet = String(trimmed[matchRange])
            let locales = [Locale(identifier: "en_US_POSIX"), Locale(identifier: "ru_RU"), Locale.current]
            let formatter = DateFormatter()
            formatter.timeZone = .current
            for locale in locales {
                formatter.locale = locale
                for format in formats {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: snippet) {
                        return date
                    }
                }
            }
        }

        return nil
    }

    private func composeRelativeDate(dayOffset: Int, sourceText: String) -> Date? {
        var target = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: target)
        components.timeZone = .current

        // Сначала ищем явное время (9:30)
        if let (h, m) = extractTimeFromText(sourceText) {
            components.hour = h
            components.minute = m
        } else {
            // morning/afternoon/evening по умолчанию
            let lower = sourceText.lowercased()
            if lower.contains("morning") || lower.contains("утра") || lower.contains("утром") {
                components.hour = 9
                components.minute = 0
            } else if lower.contains("afternoon") || lower.contains("дня") || lower.contains("днём") {
                components.hour = 14
                components.minute = 0
            } else if lower.contains("evening") || lower.contains("вечера") || lower.contains("вечером") {
                components.hour = 18
                components.minute = 0
            } else if lower.contains("night") || lower.contains("ночи") || lower.contains("ночью") {
                components.hour = 20
                components.minute = 0
            } else {
                components.hour = 9
                components.minute = 0
            }
        }

        target = Calendar.current.date(from: components) ?? target
        return target
    }

    private func extractTimeFromText(_ text: String) -> (Int, Int)? {
        let lower = text.lowercased()
        
        // Сначала ищем явное время HH:MM
        let pattern = #"(\d{1,2}):(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            // Если нет явного времени, используем morning/afternoon/evening
            if lower.contains("morning") || lower.contains("утра") || lower.contains("утром") {
                return (9, 0)
            }
            if lower.contains("afternoon") || lower.contains("дня") || lower.contains("днём") {
                return (14, 0)
            }
            if lower.contains("evening") || lower.contains("вечера") || lower.contains("вечером") {
                return (18, 0)
            }
            if lower.contains("night") || lower.contains("ночи") || lower.contains("ночью") {
                return (20, 0)
            }
            return nil
        }
        return (hour, minute)
    }

    private func parseBoolean(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    private func formatEventDate(_ date: Date?, allDay: Bool) -> String {
        guard let date else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = allDay ? .none : .short
        return formatter.string(from: date)
    }

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    // MARK: - Weather (WeatherKit)

    private func runWeatherAction(call: ActionCall) async -> String {
        let rawLocation = call.args["location"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? extractWeatherLocationCandidate(from: call.query)
            ?? ""
        let rawTime = call.args["time"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "now"
        let rawUnits = call.args["units"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "metric"
        let includeHourly = parseBoolean(call.args["includeHourly"])
        let includeDaily: Bool = {
            if let v = call.args["includeDaily"] { return parseBoolean(v) }
            return rawTime != "now" && rawTime != "24h"
        }()

        let location: CLLocation
        if rawLocation.isEmpty {
            guard let current = await resolveDeviceLocation() else {
                return buildToolErrorBlock(toolName: "weather", message: "Location unavailable. Set location param or allow location access.")
            }
            location = current
        } else {
            guard let geocoded = await geocodeLocation(rawLocation) else {
                return buildToolErrorBlock(toolName: "weather", message: "Could not resolve location: \(rawLocation)")
            }
            location = geocoded
        }

        let weather: Weather
        do {
            weather = try await WeatherService.shared.weather(for: location)
        } catch {
            return buildToolErrorBlock(toolName: "weather", message: "Weather fetch failed: \(error.localizedDescription)")
        }

        let tempUnit: UnitTemperature = rawUnits == "imperial" ? .fahrenheit : .celsius
        let speedUnit: UnitSpeed = rawUnits == "imperial" ? .milesPerHour : .kilometersPerHour

        let current = weather.currentWeather
        let temp = current.temperature.converted(to: tempUnit).value
        let feelsLike = current.apparentTemperature.converted(to: tempUnit).value
        let condition = current.condition.description
        let humidity = current.humidity
        let wind = current.wind.speed.converted(to: speedUnit).value
        let uvIndex = current.uvIndex.value

        var lines: [String] = [
            "Signal context (weather):",
            "Location: \(location.coordinate.latitude), \(location.coordinate.longitude)",
            "Current: \(String(format: "%.0f", temp))° (\(condition))",
            "Feels like: \(String(format: "%.0f", feelsLike))°",
            "Humidity: \(Int(humidity * 100))%",
            "Wind: \(String(format: "%.0f", wind)) \(rawUnits == "imperial" ? "mph" : "km/h")",
            "UV index: \(Int(uvIndex))"
        ]

        let timeWindow = resolveTimeWindow(rawTime)

        if includeHourly {
            let hourly = weather.hourlyForecast.forecast.prefix(12)
            let hourLines = hourly.map { h in
                let t = h.temperature.converted(to: tempUnit).value
                let hour = Calendar.current.component(.hour, from: h.date)
                return "  \(hour):00 — \(String(format: "%.0f", t))° \(h.condition.description)"
            }
            lines.append("Hourly (next 12h):\n" + hourLines.joined(separator: "\n"))
        }

        if includeDaily {
            let daily = weather.dailyForecast.forecast.prefix(timeWindow)
            let dayLines = daily.map { d in
                let hi = d.highTemperature.converted(to: tempUnit).value
                let lo = d.lowTemperature.converted(to: tempUnit).value
                let df = DateFormatter()
                df.dateFormat = "EEE"
                return "  \(df.string(from: d.date)): \(String(format: "%.0f", lo))–\(String(format: "%.0f", hi))° \(d.condition.description)"
            }
            lines.append("Daily forecast:\n" + dayLines.joined(separator: "\n"))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func resolveTimeWindow(_ raw: String) -> Int {
        switch raw {
        case "3d": return 3
        case "7d": return 7
        case "10d": return 10
        default: return 1
        }
    }

    // MARK: - Health (CoreMotion)

    private func runHealthAction(call: ActionCall) async -> String {
        let rawStat = call.args["stat"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "summary"
        let rawRange = call.args["range"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "today"

        guard CMPedometer.isStepCountingAvailable() else {
            return buildToolErrorBlock(toolName: "health", message: "Step counting not available on this device.")
        }

        let (start, end) = resolveHealthRange(rawRange)

        let pedometer = CMPedometer()
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<CMPedometerData?, Never>) in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data else {
            return buildToolErrorBlock(toolName: "health", message: "No step data available for this range.")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)

        var lines: [String] = [
            "Signal context (health):",
            "Range: \(startStr) — \(endStr)",
            "Steps: \(data.numberOfSteps.intValue)"
        ]

        if rawStat == "distance" || rawStat == "summary" {
            if let dist = data.distance {
                lines.append("Distance: \(String(format: "%.1f", dist.doubleValue)) m")
            }
        }

        if rawStat == "floors" || rawStat == "summary" {
            let up = data.floorsAscended?.intValue ?? 0
            let down = data.floorsDescended?.intValue ?? 0
            lines.append("Floors: ↑\(up) ↓\(down)")
        }

        if rawStat == "summary" {
            let hours = Calendar.current.dateComponents([.hour], from: start, to: end).hour ?? 1
            let pace = hours > 0 ? Double(data.numberOfSteps.intValue) / Double(hours) : 0
            lines.append("Avg steps/hour: \(Int(pace))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func resolveHealthRange(_ raw: String) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch raw {
        case "yesterday":
            let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
            return (yesterday, cal.startOfDay(for: now))
        case "week":
            let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)) ?? now
            return (weekAgo, now)
        case "month":
            let monthAgo = cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now)) ?? now
            return (monthAgo, now)
        default:
            return (cal.startOfDay(for: now), now)
        }
    }

    // MARK: - System (Device Info)

    private func runSystemAction(call: ActionCall) async -> String {
        let rawInclude = call.args["include"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "general"
        let parts = Set(rawInclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        var lines: [String] = ["Signal context (system):"]

        if parts.contains("general") || parts.isEmpty {
            lines.append(contentsOf: buildSystemGeneralInfo())
        }
        if parts.contains("battery") {
            lines.append(contentsOf: buildSystemBatteryInfo())
        }
        if parts.contains("storage") {
            lines.append(contentsOf: buildSystemStorageInfo())
        }
        if parts.contains("memory") {
            lines.append(contentsOf: buildSystemMemoryInfo())
        }
        if parts.contains("network") {
            lines.append(contentsOf: buildSystemNetworkInfo())
        }
        if parts.contains("thermal") {
            lines.append(contentsOf: buildSystemThermalInfo())
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func buildSystemGeneralInfo() -> [String] {
        #if canImport(UIKit)
        let device = UIDevice.current
        return [
            "Model: \(device.model)",
            "System: \(device.systemName) \(device.systemVersion)",
            "Name: \(device.name)",
            "Cores: \(ProcessInfo.processInfo.activeProcessorCount)/\(ProcessInfo.processInfo.processorCount)"
        ]
        #else
        return ["Platform: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        #endif
    }

    private func buildSystemBatteryInfo() -> [String] {
        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return [
            "Battery: \(level >= 0 ? "\(Int(level * 100))%" : "unknown")",
            "State: \(state)",
            "Low Power Mode: \(lowPower ? "on" : "off")"
        ]
        #else
        return ["Battery: N/A"]
        #endif
    }

    private func buildSystemStorageInfo() -> [String] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfFileSystem(forPath: fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"),
              let total = attrs[.systemSize] as? Int64,
              let free = attrs[.systemFreeSize] as? Int64 else {
            return ["Storage: unavailable"]
        }
        let used = total - free
        return [
            "Storage: \(formatByteCount(used)) used / \(formatByteCount(total)) total",
            "Free: \(formatByteCount(free))"
        ]
    }

    private func buildSystemMemoryInfo() -> [String] {
        let total = ProcessInfo.processInfo.physicalMemory
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return ["Memory: \(formatByteCount(Int64(total))) total, usage unavailable"]
        }
        let used = info.resident_size
        return [
            "Memory: \(formatByteCount(Int64(used))) used / \(formatByteCount(Int64(total))) total"
        ]
    }

    private func buildSystemNetworkInfo() -> [String] {
        let monitor = NWPathMonitor()
        let path = monitor.currentPath
        if path.usesInterfaceType(.wifi) {
            return ["Network: Wi-Fi"]
        } else if path.usesInterfaceType(.cellular) {
            return ["Network: Cellular"]
        } else if path.usesInterfaceType(.wiredEthernet) {
            return ["Network: Wired"]
        } else {
            return ["Network: offline or unknown"]
        }
    }

    private func buildSystemThermalInfo() -> [String] {
        #if canImport(UIKit)
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = "nominal"
        case .fair: state = "fair"
        case .serious: state = "serious — performance reduced"
        case .critical: state = "critical — app may be suspended"
        @unknown default: state = "unknown"
        }
        return ["Thermal: \(state)"]
        #else
        return ["Thermal: N/A"]
        #endif
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Location Helpers

    private var cachedLocation: CLLocation?
    private var locationCacheTime: Date?

    private func resolveDeviceLocation() async -> CLLocation? {
        if let cached = cachedLocation, let t = locationCacheTime,
           Date().timeIntervalSince(t) < 300 {
            return cached
        }
        return await withCheckedContinuation { continuation in
            let manager = CLLocationManager()
            let helper = LocationHelper(manager: manager) { location in
                self.cachedLocation = location
                self.locationCacheTime = Date()
                continuation.resume(returning: location)
            }
            helper.onFailure = {
                continuation.resume(returning: nil)
            }
            helper.request()
        }
    }

    private func geocodeLocation(_ query: String) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(query) { placemarks, _ in
                guard let first = placemarks?.first, let loc = first.location else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: loc)
            }
        }
    }

    // MARK: - External Fetch

    private struct WikipediaSearchResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let search: [SearchResult]?

            struct SearchResult: Decodable {
                let title: String?
                let snippet: String?
            }
        }
    }

    private struct WikipediaSummary: Decodable {
        let title: String?
        let extract: String?
        let thumbnail: Thumbnail?

        struct Thumbnail: Decodable {
            let source: String?
            let width: Int?
            let height: Int?
        }
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var out = text
        let map: [String: String] = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (k, v) in map {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    func buildPreparedSearchContext(for query: String) async -> String {
        let candidates = Array(searchQueryCandidates(from: query).prefix(3))
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[SearchDiag] buildPreparedSearchContext query=\(trimmedQuery.prefix(60)) candidates=\(candidates.map { $0.prefix(40) })")
        guard trimmedQuery.count >= 4 else {
            print("[SearchDiag] query too short (\(trimmedQuery.count) chars), skipping")
            return ""
        }

        let cacheKey = trimmedQuery.lowercased() as NSString
        if let cached = preparedContextCache.object(forKey: cacheKey) {
            print("[SearchDiag] cache hit for \(trimmedQuery.prefix(40))")
            return String(cached)
        }

        guard !candidates.isEmpty else {
            print("[SearchDiag] no candidates, returning empty")
            return ""
        }

        var preparedCandidates: [PreparedSearchCandidate] = []
        for candidate in candidates {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty else { continue }

            let candidateResult = await fetchCandidateEvidence(trimmedCandidate)
            if let candidateResult {
                preparedCandidates.append(candidateResult)
                if preparedCandidates.count >= 2 { break }
            }
        }

        print("[SearchDiag] collected \(preparedCandidates.count) candidates")

        guard let bestCandidate =
            preparedCandidates.max(by: { $0.score < $1.score }) else {
            print("[SearchDiag] no bestCandidate found, returning empty")
            return ""
        }

        print("[SearchDiag] bestCandidate query=\(bestCandidate.query.prefix(40)) score=\(bestCandidate.score) summaryLen=\(bestCandidate.summary.count) wikiSummaryLen=\(bestCandidate.wikipediaSummary.count) results=\(bestCandidate.results.count) trusted=\(bestCandidate.trustedEvidence.count)")

        let normalizedSummary = compactSearchSummary(bestCandidate.summary, maxChars: 800)
        let normalizedWikipedia = compactSearchSummary(bestCandidate.wikipediaSummary, maxChars: 800)

        if !bestCandidate.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = (!normalizedWikipedia.isEmpty && normalizedSummary == normalizedWikipedia) ? "wikipedia" : "duckduckgo"
            ingestExternalSnippets(text: bestCandidate.summary, source: source, query: bestCandidate.query)
        }
        if !bestCandidate.wikipediaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedSummary != normalizedWikipedia {
            ingestExternalSnippets(text: bestCandidate.wikipediaSummary, source: "wikipedia", query: bestCandidate.query)
        }

        let finalContext = buildPreparedSearchContextBlock(
            query: bestCandidate.query,
            summary: bestCandidate.summary,
            wikipediaSummary: bestCandidate.wikipediaSummary,
            results: bestCandidate.results,
            trustedEvidence: bestCandidate.trustedEvidence
        )

        preparedContextCache.setObject(
            finalContext as NSString,
            forKey: cacheKey
        )

        return finalContext
    }

    private func fetchCandidateEvidence(_ trimmedCandidate: String) async -> PreparedSearchCandidate? {
        print("[SearchDiag] fetching evidence for: \(trimmedCandidate.prefix(40))")

        // 1. Try full multi-provider search (SearXNG/OpenSERP/DDG/Wiki/Lite).
        let searchResponse = await multiSearchProvider.search(trimmedCandidate)

        // 2. Always fetch Wikipedia in parallel — it's a reliable structured source.
        async let wikipediaSummary = fetchWikipediaSummary(topic: trimmedCandidate)
        async let titles = fetchWikipediaSearchResults(query: trimmedCandidate, limit: 4)
        let (wikiSummary, wikiTitles) = await (wikipediaSummary, titles)

        let wikiResults = wikiTitles.compactMap { title -> SearchResult? in
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            guard let url = URL(string: "https://en.wikipedia.org/wiki/\(encoded)") else { return nil }
            return SearchResult(title: title, url: url, snippet: nil)
        }

        // 3. Merge: web results from multi-provider + Wikipedia results.
        let summary: String
        var allResults: [SearchResult]
        var seen = Set<URL>()

        if let response = searchResponse {
            summary = response.answer ?? response.results.first?.snippet ?? ""
            allResults = response.results
            for r in response.results { seen.insert(r.url) }
            // Append Wikipedia results that aren't already in the web results.
            for w in wikiResults where !seen.contains(w.url) {
                allResults.append(w)
                seen.insert(w.url)
            }
        } else {
            summary = ""
            allResults = wikiResults
        }

        let combinedSummary = [summary, wikiSummary]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        print("[SearchDiag] candidate=\(trimmedCandidate.prefix(40)) summary=\(combinedSummary.prefix(60)) wikiSummary=\(wikiSummary.prefix(60)) results=\(allResults.map { $0.title })")

        var trustedEvidence: [String] = []
        if !wikiSummary.isEmpty {
            trustedEvidence.append(wikiSummary)
        }
        for result in wikiResults.prefix(2) {
            let topic = result.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? result.title
            if let wikiURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(topic)"),
               let (data, _) = try? await URLSession.shared.data(from: wikiURL),
               let decoded = try? JSONDecoder().decode(WikipediaSummary.self, from: data),
               let extract = decoded.extract, !extract.isEmpty {
                trustedEvidence.append(extract)
            }
        }

        if combinedSummary.isEmpty && allResults.isEmpty && trustedEvidence.isEmpty {
            return nil
        }

        let reliability = searchReliability(forSummary: combinedSummary, wikipediaSummary: wikiSummary, results: allResults)
        let numericConflict = detectNumericConflict(summary: combinedSummary, wikipediaSummary: wikiSummary, trustedEvidence: trustedEvidence)
        let sourceDisagreement = detectSourceDisagreement(summary: combinedSummary, wikipediaSummary: wikiSummary, trustedEvidence: trustedEvidence)

        return PreparedSearchCandidate(
            query: trimmedCandidate,
            summary: combinedSummary,
            wikipediaSummary: wikiSummary,
            results: allResults,
            trustedEvidence: trustedEvidence,
            reliability: reliability,
            numericConflict: numericConflict,
            sourceDisagreement: sourceDisagreement
        )
    }

    func searchQueryCandidates(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let canonical = canonicalSearchQuery(from: trimmed)
        let quoted = quotedSearchPhrases(in: trimmed)
        let keywordQuery = keywordSearchQuery(from: trimmed)
        let expanded = expandedSearchQueries(from: canonical.isEmpty ? trimmed : canonical)

        var out: [String] = []
        if !canonical.isEmpty {
            out.append(canonical)
        }
        out.append(contentsOf: quoted)
        if canonical != trimmed {
            out.append(trimmed)
        }
        if !keywordQuery.isEmpty {
            out.append(keywordQuery)
        }
        out.append(contentsOf: expanded)

        return deduplicateQueries(out)
    }

    private func expandedSearchQueries(from canonical: String) -> [String] {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants: [String] = []
        let lower = trimmed.lowercased()

        if containsPopulationIntent(trimmed) {
            variants.append("\(trimmed) wikipedia")
            variants.append("\(trimmed) city population")
        }

        if containsBiographyIntent(trimmed) {
            variants.append("\(trimmed) wikipedia")
            variants.append("\(trimmed) biography")
        }

        if containsNewsIntent(trimmed) {
            variants.append("\(trimmed) latest news")
        }

        if lower.split(separator: " ").count >= 3 {
            let focused = keywordSearchQuery(from: trimmed)
            if !focused.isEmpty, focused != lower {
                variants.append(focused)
            }
        }

        return deduplicateQueries(variants)
    }

    private func containsPopulationIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "population", "population of", "city population", "metro population",
            "население", "сколько жителей", "сколько человек", "численность населения"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private func containsBiographyIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "who is", "biography", "born", "career",
            "кто такой", "кто такая", "биография", "родился", "родилась"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private func containsNewsIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "news", "latest", "headlines", "breaking", "current events",
            "новости", "последние новости", "свежие новости", "что нового"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private func canonicalSearchQuery(from raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lower = trimmed.lowercased()
        let prefixes = [
            "найди информацию в интернете о",
            "найди в интернете о",
            "найди информацию о",
            "найди в интернете",
            "найди",
            "найти",
            "поищи в интернете",
            "поищи информацию о",
            "поищи",
            "расскажи подробнее про",
            "расскажи подробнее о",
            "расскажи про",
            "расскажи о",
            "tell me more about",
            "tell me about",
            "tell me everything about",
            "search the internet for",
            "search for",
            "find information about",
            "find info about",
            "find",
            "look up",
            "look for",
            "what is",
            "who is",
            "what are",
            "what was",
            "кто такой",
            "кто такая",
            "кто такие",
            "что такое",
            "что за",
            "какой",
            "какая",
            "какие",
            "сколько"
        ]

        var topic = trimmed
        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            topic = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        topic = topic.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}"))
        topic = topic.replacingOccurrences(of: #"^(?:о|про|about)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        topic = topic.replacingOccurrences(of: #"(?i)\b(please|пожалуйста|pls|now|сейчас|быстро)\b"#, with: "", options: .regularExpression)
        topic = topic.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)

        if topic.count < 2 {
            return trimmed
        }
        return topic
    }

    private func quotedSearchPhrases(in raw: String) -> [String] {
        let patterns = [
            #""([^"]{2,120})""#,
            #"'([^']{2,120})'"#
        ]
        var out: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let matches = regex.matches(in: raw, range: range)
            for match in matches {
                guard let phraseRange = Range(match.range(at: 1), in: raw) else { continue }
                let phrase = String(raw[phraseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if phrase.count >= 2 {
                    out.append(phrase)
                }
            }
        }

        return deduplicateQueries(out)
    }

    private func keywordSearchQuery(from raw: String) -> String {
        let lower = canonicalSearchQuery(from: raw).lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "then", "more", "tell", "show",
            "what", "which", "when", "where", "who", "how", "why", "is", "are", "was", "were",
            "это", "как", "что", "когда", "где", "кто", "почему", "зачем", "какой", "какая",
            "какие", "сколько", "про", "about", "please", "пожалуйста", "найди", "поищи"
        ]

        let tokens = parts.filter { token in
            token.count > 2 && !stopWords.contains(token)
        }
        guard !tokens.isEmpty else { return "" }
        return tokens.prefix(8).joined(separator: " ")
    }

    private func deduplicateQueries(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private func compactSearchSummary(_ text: String, maxChars: Int = 320) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.count > maxChars ? String(cleaned.prefix(maxChars)) + "…" : cleaned
    }

    private func compactSearchAnswerSeed(from text: String, maxChars: Int = 180) -> String {
        let summary = compactSearchSummary(text, maxChars: maxChars * 2)
        guard !summary.isEmpty else { return "" }

        let sentence = summary
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first
            ?? summary

        let compact = sentence.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.count > maxChars ? String(compact.prefix(maxChars)) + "…" : compact
    }

    private func detectNumericConflict(summary: String, wikipediaSummary: String, trustedEvidence: [String]) -> Bool {
        let texts = [summary, wikipediaSummary] + trustedEvidence
        let values = texts
            .flatMap(extractMeaningfulNumbers(from:))
            .filter { $0 >= 1_000 }

        guard values.count >= 2 else { return false }
        guard let minValue = values.min(), let maxValue = values.max(), minValue > 0 else { return false }
        return Double(maxValue - minValue) / Double(minValue) >= 0.18
    }

    private func normalizeSearchClaim(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-zа-я0-9\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectSourceDisagreement(summary: String, wikipediaSummary: String, trustedEvidence: [String]) -> Bool {
        let fragments = ([summary, wikipediaSummary] + trustedEvidence)
            .map { compactSearchAnswerSeed(from: $0, maxChars: 220) }
            .map(normalizeSearchClaim)
            .filter { !$0.isEmpty }

        guard fragments.count >= 2 else { return false }
        let unique = Array(Set(fragments))
        guard unique.count >= 2 else { return false }

        for fragment in unique {
            let compatibleCount = unique.filter { other in
                other == fragment || other.contains(fragment) || fragment.contains(other)
            }.count
            if compatibleCount >= 2 {
                return false
            }
        }

        return true
    }

    private func extractMeaningfulNumbers(from text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d[\d\s,._]{2,}\b"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            let token = String(text[tokenRange]).replacingOccurrences(of: #"[\s,._]"#, with: "", options: .regularExpression)
            return Int(token)
        }
    }

    private func searchReliability(
        forSummary summary: String,
        wikipediaSummary: String,
        results: [SearchResult]
    ) -> SearchReliability {
        let trustedCount = results.filter { trustedDomainScore(for: $0.url) >= 0.55 }.count
        let highTrustCount = results.filter { trustedDomainScore(for: $0.url) >= 0.85 }.count
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if highTrustCount >= 1 || trustedCount >= 2 {
            return .high
        }
        if !wikipediaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasSummary || trustedCount >= 1 || !results.isEmpty {
            return .medium
        }
        return .low
    }

    private func trustedDomainScore(for url: URL) -> Double {
        guard let host = url.host?.lowercased() else { return 0.2 }

        let highTrustDomains = [
            "wikipedia.org", "wikimedia.org", "github.com", "arxiv.org", "nature.com", "science.org",
            "openai.com", "apple.com", "developer.apple.com", "microsoft.com", "docs.python.org",
            "python.org", "swift.org", "mozilla.org", "ietf.org", "w3.org", "who.int", "cdc.gov",
            "nih.gov", "nasa.gov", "europa.eu", "gov",
            "britannica.com", "data.worldbank.org"
        ]
        let mediumTrustDomains = [
            "reuters.com", "apnews.com", "bbc.com", "nytimes.com", "bloomberg.com",
            "stackoverflow.com", "huggingface.co", "ollama.com", "reddit.com"
        ]

        if highTrustDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return 1.0
        }
        if mediumTrustDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return 0.7
        }
        if host.hasSuffix(".gov") || host.hasSuffix(".edu") {
            return 0.95
        }
        if host.hasSuffix(".org") {
            return 0.55
        }
        return 0.3
    }

    private func fetchWikipediaSummary(topic: String) async -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)") else { return "" }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            return decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func fetchWikipediaImageCandidate(topic: String) async -> WebImageCandidate? {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try 1: MediaWiki pageimages API (most reliable for thumbnails)
        if let candidate = await fetchWikipediaPageImage(topic: trimmed) {
            return candidate
        }

        // Try 2: REST API summary (sometimes has thumbnail)
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)") else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            guard let source = decoded.thumbnail?.source,
                  let imageURL = URL(string: source),
                  let title = decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return nil
            }
            return WebImageCandidate(query: trimmed, imageURL: imageURL, title: title, sourcePageURL: url)
        } catch {
            return nil
        }
    }

    private func fetchWikipediaPageImage(topic: String) async -> WebImageCandidate? {
        let escaped = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? topic
        let urlString = "https://en.wikipedia.org/w/api.php?action=query&prop=pageimages&titles=\(escaped)&piprop=thumbnail&pithumbsize=800&format=json"
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any] else { return nil }

            for (_, page) in pages {
                guard let pageDict = page as? [String: Any],
                      let title = pageDict["title"] as? String,
                      let thumbnail = pageDict["thumbnail"] as? [String: Any],
                      let source = thumbnail["source"] as? String,
                      let imageURL = URL(string: source) else { continue }

                let pageURL = URL(string: "https://en.wikipedia.org/wiki/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)")
                return WebImageCandidate(query: topic, imageURL: imageURL, title: title, sourcePageURL: pageURL ?? url)
            }
        } catch {}
        return nil
    }

    private func fetchSearchResultImageCandidate(topic: String) async -> WebImageCandidate? {
        let titles = await fetchWikipediaSearchResults(query: topic, limit: 4)
        guard !titles.isEmpty else { return nil }

        for title in titles {
            if let candidate = await fetchWikipediaImageCandidate(topic: title) {
                return candidate
            }
        }
        return nil
    }

    private struct RSSFeedItem {
        let title: String
        let link: String
        let pubDate: String?
    }

    private static let rssFeeds = [
        URL(string: "https://feeds.bbci.co.uk/news/technology/rss.xml")!,
        URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!,
        URL(string: "https://hnrss.org/frontpage?count=20")!,
    ]

    private func fetchRSSNews(limit: Int = 10, query: String = "") async -> String {
        let clamped = max(1, min(20, limit))
        var allItems: [RSSFeedItem] = []

        await withTaskGroup(of: [RSSFeedItem].self) { group in
            for feedURL in ActionService.rssFeeds {
                group.addTask {
                    await self.fetchSingleRSSFeed(feedURL)
                }
            }
            for await items in group {
                allItems.append(contentsOf: items)
            }
        }

        let queryLower = query.lowercased()
        let queryTerms = queryLower
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 2 }

        if !queryTerms.isEmpty {
            allItems.sort { a, b in
                let scoreA = queryTerms.filter { a.title.lowercased().contains($0) }.count
                let scoreB = queryTerms.filter { b.title.lowercased().contains($0) }.count
                return scoreA > scoreB
            }
        }

        var seen = Set<String>()
        var unique: [RSSFeedItem] = []
        for item in allItems {
            let key = item.title.lowercased()
            if seen.insert(key).inserted {
                unique.append(item)
            }
        }

        guard !unique.isEmpty else { return "" }

        let lines: [String] = unique.prefix(clamped).map { item in
            if item.link.isEmpty {
                return "- \(item.title)"
            }
            return "- \(item.title)\n  \(item.link)"
        }

        return lines.joined(separator: "\n")
    }

    private func fetchSingleRSSFeed(_ url: URL) async -> [RSSFeedItem] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else {
            return []
        }

        var items: [RSSFeedItem] = []
        let itemPattern = "(?s)<item[^>]*>(.*?)</item>"
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern) else { return [] }
        let itemMatches = itemRegex.matches(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml))

        for match in itemMatches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let itemXML = String(xml[range])

            let title = decodeHTMLEntities(
                extractXMLTag("title", from: itemXML)
                    .replacingOccurrences(of: "<!\\[CDATA\\[", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\]\\]>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let link = decodeHTMLEntities(
                extractXMLTag("link", from: itemXML)
                    .replacingOccurrences(of: "<!\\[CDATA\\[", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\]\\]>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let pubDate = extractXMLTag("pubDate", from: itemXML)

            if !title.isEmpty {
                items.append(RSSFeedItem(title: title, link: link, pubDate: pubDate))
            }
        }

        return items
    }

    private func extractXMLTag(_ tag: String, from xml: String) -> String {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return ""
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchWikipediaSearchResults(query: String, limit: Int = 3) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "srlimit", value: "\(limit)")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(WikipediaSearchResponse.self, from: data),
              let results = decoded.query?.search else {
            return []
        }

        return results.compactMap { $0.title }.filter { !$0.isEmpty }
    }

    private func splitSnippets(_ text: String) -> [String] {
        let chunks = text
            .split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if chunks.count > 1 { return chunks }

        let sentences = text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return sentences
    }

    private func ingestExternalSnippets(text: String, source: String, query: String) {
        let snippets = splitSnippets(text)
        memoryService.ingestExternalSnippets(snippets, source: source, query: query)
    }

    private func normalizeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), isAllowedWebURL(direct) {
            return direct
        }
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://"),
           let prefixed = URL(string: "https://\(trimmed)"), isAllowedWebURL(prefixed) {
            return prefixed
        }
        return nil
    }

    private func isAllowedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func validateReachableWebURL(_ url: URL) async -> Bool {
        let key = url.absoluteString.lowercased()
        if let cached = cachedURLValidation(for: key) {
            return cached
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.httpMethod = "HEAD"
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let ok = (200...399).contains(http.statusCode)
                storeURLValidationCache(ok, key: key)
                if ok { return true }
            }
        } catch {
            // Fall through to a light GET fallback.
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let ok = (200...399).contains(http.statusCode)
                storeURLValidationCache(ok, key: key)
                return ok
            }
        } catch {
            storeURLValidationCache(false, key: key)
            return false
        }

        storeURLValidationCache(false, key: key)
        return false
    }

    private func analyzeURL(_ url: URL) async -> String {
        let key = url.absoluteString.lowercased()
        if let cached = cachedURLAnalysis(for: key) {
            return cached
        }
        guard let html = try? await fetchHTML(url: url) else { return "" }
        let analysis = if isGitHubRepositoryURL(url) {
            analyzeGitHubRepositoryPage(url: url, html: html)
        } else {
            analyzeGenericWebPage(url: url, html: html)
        }
        let output = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            storeURLAnalysisCache(output, key: key)
        }
        return output
    }

    private func analyzeGenericWebPage(url: URL, html: String) -> String {
        let title = bestPageTitle(from: html)
        let description = bestPageDescription(from: html)
        let headings = extractHeadings(from: html, maxCount: 6)
        let mainContent = extractPrimaryPageContent(from: html)

        var parts: [String] = []
        if !title.isEmpty { parts.append("Title: \(title)") }
        if !description.isEmpty { parts.append("Description: \(description)") }
        if !headings.isEmpty {
            parts.append("Key sections: " + headings.joined(separator: " | "))
        }
        if !mainContent.isEmpty {
            parts.append("Main content: \(mainContent)")
        }
        return parts.joined(separator: "\n")
    }

    private func analyzeGitHubRepositoryPage(url: URL, html: String) -> String {
        let repoPath = repositoryPath(from: url)
        let title = bestPageTitle(from: html)
        let description = firstNonEmpty([
            extractMetaContent(in: html, property: "og:description"),
            extractMetaContent(in: html, name: "description"),
            extractFirstMatch(in: html, pattern: #"(?is)<p[^>]*class=["'][^"']*f4[^"']*my-3[^"']*["'][^>]*>(.*?)</p>"#)
                .map { cleanHTMLFragment($0) }
        ])

        let readme = firstNonEmpty([
            extractFirstMatch(in: html, pattern: #"(?is)<article[^>]*markdown-body[^>]*>(.*?)</article>"#)
                .map { cleanHTMLFragment($0) },
            extractFirstMatch(in: html, pattern: #"(?is)<div[^>]*id=["']readme["'][^>]*>.*?<article[^>]*>(.*?)</article>"#)
                .map { cleanHTMLFragment($0) },
            extractFirstMatch(in: html, pattern: #"(?is)<div[^>]*id=["']readme["'][^>]*>(.*?)</div>"#)
                .map { cleanHTMLFragment($0) }
        ])

        let headings = extractHeadings(from: html, maxCount: 8)
        let topics = extractGitHubTopics(from: html)
        let stats = extractGitHubRepoStats(from: html)

        var parts: [String] = []
        if !repoPath.isEmpty { parts.append("Repository: \(repoPath)") }
        if !title.isEmpty { parts.append("Title: \(title)") }
        if !description.isEmpty { parts.append("About: \(description)") }
        if !topics.isEmpty {
            parts.append("Topics: " + topics.joined(separator: ", "))
        }
        if !stats.isEmpty {
            parts.append("Signals: " + stats.joined(separator: " | "))
        }
        if !headings.isEmpty {
            parts.append("Sections: " + headings.joined(separator: " | "))
        }
        if !readme.isEmpty {
            parts.append("README summary: \(readme)")
        }
        return parts.joined(separator: "\n")
    }

    private func bestPageTitle(from html: String) -> String {
        firstNonEmpty([
            extractMetaContent(in: html, property: "og:title"),
            extractFirstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>")
                .map { cleanHTMLFragment($0) }
        ])
    }

    private func bestPageDescription(from html: String) -> String {
        firstNonEmpty([
            extractMetaContent(in: html, property: "og:description"),
            extractMetaContent(in: html, name: "description"),
            extractMetaContent(in: html, name: "twitter:description")
        ])
    }

    private func extractPrimaryPageContent(from html: String) -> String {
        let prioritizedBlocks = [
            extractFirstMatch(in: html, pattern: #"(?is)<main[^>]*>(.*?)</main>"#),
            extractFirstMatch(in: html, pattern: #"(?is)<article[^>]*>(.*?)</article>"#),
            extractFirstMatch(in: html, pattern: #"(?is)<div[^>]*role=["']main["'][^>]*>(.*?)</div>"#)
        ].compactMap { $0 }

        for block in prioritizedBlocks {
            let cleaned = cleanHTMLFragment(block, maxChars: 2600)
            if cleaned.count >= 180 {
                return cleaned
            }
        }

        return cleanHTMLFragment(html, maxChars: 2600)
    }

    private func extractHeadings(from html: String, maxCount: Int) -> [String] {
        let patterns = [
            #"(?is)<h1[^>]*>(.*?)</h1>"#,
            #"(?is)<h2[^>]*>(.*?)</h2>"#,
            #"(?is)<h3[^>]*>(.*?)</h3>"#
        ]

        var headings: [String] = []
        for pattern in patterns {
            headings.append(contentsOf: extractAllMatches(in: html, pattern: pattern).map { cleanHTMLFragment($0, maxChars: 120) })
        }

        return Array(deduplicateQueries(headings.filter { !$0.isEmpty }).prefix(maxCount))
    }

    private func extractGitHubTopics(from html: String) -> [String] {
        let patterns = [
            #"(?is)<a[^>]*data-view-component=["']true["'][^>]*href=["']/topics/[^"']+["'][^>]*>(.*?)</a>"#,
            #"(?is)<a[^>]*class=["'][^"']*topic-tag[^"']*["'][^>]*>(.*?)</a>"#
        ]

        var out: [String] = []
        for pattern in patterns {
            out.append(contentsOf: extractAllMatches(in: html, pattern: pattern).map { cleanHTMLFragment($0, maxChars: 40) })
        }

        return Array(deduplicateQueries(out.filter { !$0.isEmpty }).prefix(8))
    }

    private func extractGitHubRepoStats(from html: String) -> [String] {
        let labels = [
            "stars": #"(?is)href=["']/[^"']*/stargazers["'][^>]*>\s*<span[^>]*>(.*?)</span>"#,
            "forks": #"(?is)href=["']/[^"']*/forks["'][^>]*>\s*<span[^>]*>(.*?)</span>"#,
            "issues": #"(?is)href=["']/[^"']*/issues["'][^>]*>\s*<span[^>]*>(.*?)</span>"#
        ]

        var stats: [String] = []
        for (label, pattern) in labels {
            if let value = extractFirstMatch(in: html, pattern: pattern).map({ cleanHTMLFragment($0) }),
               !value.isEmpty {
                stats.append("\(label): \(value)")
            }
        }
        return stats
    }

    private func repositoryPath(from url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else { return "" }
        return components.prefix(2).joined(separator: "/")
    }

    private func isGitHubRepositoryURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return components.count >= 2
    }

    private func extractMetaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        return extractFirstMatch(
            in: html,
            pattern: #"(?is)<meta[^>]+property=["']\#(escaped)["'][^>]+content=["']([^"']+)["'][^>]*>"#
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractMetaContent(in html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return extractFirstMatch(
            in: html,
            pattern: #"(?is)<meta[^>]+name=["']\#(escaped)["'][^>]+content=["']([^"']+)["'][^>]*>"#
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanHTMLFragment(_ fragment: String, maxChars: Int = 1800) -> String {
        var cleaned = fragment
        cleaned = cleaned.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<svg\\b[^>]*>.*?</svg>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<nav\\b[^>]*>.*?</nav>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<footer\\b[^>]*>.*?</footer>", with: " ", options: .regularExpression)
        cleaned = stripHTML(cleaned)
        cleaned = decodeHTMLEntities(cleaned)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxChars {
            return String(cleaned.prefix(maxChars)) + "…"
        }
        return cleaned
    }

    private func extractAllMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match in
            guard let resultRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[resultRange])
        }
    }

    private func firstNonEmpty(_ candidates: [String?]) -> String {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private func fetchHTML(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return ""
        }
        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let html = String(data: data, encoding: .windowsCP1251) {
            return html
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let resultRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[resultRange])
    }

    private func cachedURLAnalysis(for key: String) -> String? {
        guard let cached = urlAnalysisCache[key] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) > urlCacheTTL {
            urlAnalysisCache.removeValue(forKey: key)
            return nil
        }
        return cached.text
    }

    private func storeURLAnalysisCache(_ text: String, key: String) {
        urlAnalysisCache[key] = (text, Date())
    }

    private func cachedURLValidation(for key: String) -> Bool? {
        guard let cached = urlValidationCache[key] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) > urlCacheTTL {
            urlValidationCache.removeValue(forKey: key)
            return nil
        }
        return cached.isValid
    }

    private func storeURLValidationCache(_ isValid: Bool, key: String) {
        urlValidationCache[key] = (isValid, Date())
    }
}

// MARK: - LocationHelper (CLLocationManager wrapper)

private final class LocationHelper: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: CLLocationManager
    private var didResume = false

    init(manager: CLLocationManager, onLocation: @escaping @Sendable @MainActor (CLLocation) -> Void) {
        self.manager = manager
        self.onLocation = onLocation
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    var onLocation: @Sendable @MainActor (CLLocation) -> Void
    var onFailure: (@Sendable () -> Void)?

    func request() {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            guard !didResume else { return }
            didResume = true
            onFailure?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            guard !didResume else { return }
            didResume = true
            onLocation(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard !didResume else { return }
            didResume = true
            onFailure?()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                guard !didResume else { return }
                didResume = true
                onFailure?()
            default:
                break
            }
        }
    }
}
