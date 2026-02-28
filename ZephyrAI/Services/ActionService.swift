import Foundation
import UIKit
import EventKit

@MainActor
final class ActionService {
    static let shared = ActionService()

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

    private let eventStore = EKEventStore()
    private let memoryService = MemoryService.shared

    private init() {}

    // MARK: - Public API

    func buildToolGuidanceBlock(hasTools: Bool) -> String {
        guard hasTools else { return "" }
        return """

Signal results are available below. Use them directly and do not claim you lack internet access.

"""
    }

    func parseCall(from text: String) -> ActionCall? {
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
        case "news", "reddit", "redditnews", "reddit_news":
            return "reddit_news"
        case "search", "web", "websearch", "internet_search", "browse", "web_search":
            return "web_search"
        case "openurl", "open_url", "url", "url_open":
            return "open_url"
        case "calendar", "open_calendar", "calendar_event", "event":
            return "calendar"
        case "date", "time", "today_date":
            return "date"
        default:
            return key
        }
    }

    func context(for call: ActionCall) async -> String {
        switch call.name {
        case "date":
            return buildDateContextBlock()
        case "web_search":
            let q = call.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                return buildToolErrorBlock(toolName: "web_search", message: "Empty query.")
            }
            let webContext = await fetchWebSummaryWithFallback(query: q)
            if !webContext.isEmpty {
                ingestExternalSnippets(text: webContext, source: "duckduckgo", query: q)
                return buildToolContextBlock(from: webContext)
            }
            return buildToolErrorBlock(toolName: "web_search", message: "Web search unavailable (network error).")
        case "reddit_news":
            do {
                let news = try await fetchRedditNews(limit: 6)
                if !news.isEmpty {
                    return buildNewsContextBlock(from: news)
                }
                return buildToolErrorBlock(toolName: "reddit_news", message: "No news items returned.")
            } catch {
                return buildToolErrorBlock(toolName: "reddit_news", message: "Reddit news unavailable (network error).")
            }
        case "open_url", "url":
            return await runOpenURLAction(call: call)
        case "calendar", "open_calendar":
            return await runCalendarAction(call: call)
        default:
            return buildToolErrorBlock(toolName: call.name, message: "Unknown tool.")
        }
    }

    func aggregateRuleBasedContext(for prompt: String) async -> String {
        var blocks: [String] = []

        // Always provide current date/time context so the model does not drift on relative dates.
        let dateContext = buildDateContextBlock()
        if !dateContext.isEmpty {
            blocks.append(dateContext)
        }

        if shouldUseWebSearch(for: prompt) {
            let webContext = await fetchWebSummaryWithFallback(query: prompt)
            if !webContext.isEmpty {
                ingestExternalSnippets(text: webContext, source: "duckduckgo", query: prompt)
                blocks.append(buildToolContextBlock(from: webContext))
            } else {
                blocks.append(buildToolErrorBlock(toolName: "web_search", message: "Web search unavailable (network error)."))
            }
        }

        if shouldUseNewsTool(for: prompt) {
            do {
                let news = try await fetchRedditNews(limit: 6)
                if !news.isEmpty {
                    blocks.append(buildNewsContextBlock(from: news))
                } else {
                    blocks.append(buildToolErrorBlock(toolName: "reddit_news", message: "No news items returned."))
                }
            } catch {
                blocks.append(buildToolErrorBlock(toolName: "reddit_news", message: "Reddit news unavailable (network error)."))
            }
        }

        return blocks.joined(separator: "\n")
    }

    func autonomousContext(for topic: String) async -> String {
        let ddg = await fetchWebSummaryWithFallback(query: topic)
        let wiki = await fetchWikipediaSummary(topic: topic)

        if !ddg.isEmpty {
            ingestExternalSnippets(text: ddg, source: "duckduckgo", query: topic)
        }
        if !wiki.isEmpty {
            ingestExternalSnippets(text: wiki, source: "wikipedia", query: topic)
        }

        var parts: [String] = []
        if !ddg.isEmpty {
            parts.append("DuckDuckGo summary:\n\(ddg)")
        }
        if !wiki.isEmpty {
            parts.append("Wikipedia summary:\n\(wiki)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Parsing / Blocks

    private func parseArgs(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var out: [String: String] = [:]
        let separators = CharacterSet(charactersIn: ";&,")
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

    private func buildToolContextBlock(from webContext: String) -> String {
        guard !webContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return """

Signal context (web):
\(webContext)

"""
    }

    private func buildNewsContextBlock(from newsContext: String) -> String {
        guard !newsContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return """

Signal context (news):
\(newsContext)

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

    private func actionResultBlock(_ title: String, _ message: String) -> String {
        """

Signal action (\(title)):
\(message)

"""
    }

    // MARK: - Rule Triggers

    private func shouldUseWebSearch(for text: String) -> Bool {
        let lowercased = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowercased.isEmpty { return false }

        // Never trigger web search for local action/calendar intents.
        let localActionHints = [
            "calendar", "event", "reminder", "schedule", "appointment",
            "календар", "событ", "напоминан", "встреч", "расписан",
            "action:", "tool: calendar", "op=create", "op=list", "op=open"
        ]
        if localActionHints.contains(where: { lowercased.contains($0) }) {
            return false
        }

        // Explicit search intent.
        let directTriggers = [
            "search", "google", "web", "internet", "look up", "lookup", "find online",
            "найди", "найти", "поиск", "в интернете", "загугли", "поищи", "погугли"
        ]
        if directTriggers.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // Freshness / current-facts intent.
        let freshnessTriggers = [
            "latest", "today", "current", "recent", "up to date", "new update", "breaking",
            "сегодня", "последние", "свежие", "актуаль", "что нового", "новости"
        ]
        if freshnessTriggers.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // Typical factual question forms.
        let factualQuestionStarts = [
            "who ", "what ", "when ", "where ", "which ", "how many ", "how much ",
            "кто ", "что ", "когда ", "где ", "какой ", "какая ", "какие ", "сколько "
        ]
        if factualQuestionStarts.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        // If it's a short factual question with '?', search by default.
        if lowercased.contains("?"), lowercased.count <= 180 {
            return true
        }

        return false
    }

    private func shouldUseDateTool(for text: String) -> Bool {
        let lowercased = text.lowercased()
        let triggers = [
            "какая сегодня дата", "сегодняшняя дата", "какой сегодня день",
            "today's date", "what is today's date", "current date"
        ]
        return triggers.contains { lowercased.contains($0) }
    }

    private func shouldUseNewsTool(for text: String) -> Bool {
        let lowercased = text.lowercased()
        let triggers = [
            "news", "latest", "headlines", "breaking",
            "новости", "свежие новости", "последние новости", "что нового"
        ]
        return triggers.contains { lowercased.contains($0) }
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

        let opened = await openExternalURL(url)
        if opened {
            return actionResultBlock("open_url", "Opened: \(rawURL)")
        }
        return buildToolErrorBlock(toolName: "open_url", message: "Failed to open URL.")
    }

    private func runCalendarAction(call: ActionCall) async -> String {
        let op = call.args["op"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "open"

        switch op {
        case "open":
            return await openCalendarAtDate(call.args["date"])
        case "create", "add", "new":
            return await createCalendarEvent(call: call)
        case "list", "upcoming":
            return await listCalendarEvents(call: call)
        default:
            return buildToolErrorBlock(toolName: "calendar", message: "Unknown op. Use open, create, or list.")
        }
    }

    private func openExternalURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { ok in
                continuation.resume(returning: ok)
            }
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
            guard let parsed = parseCalendarDate(rawStart) else {
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

    private func parseCalendarDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        if lower == "tomorrow" || lower == "завтра" {
            return composeRelativeDate(dayOffset: 1, sourceText: lower)
        }
        if lower == "today" || lower == "сегодня" {
            return composeRelativeDate(dayOffset: 0, sourceText: lower)
        }
        if lower.contains("tomorrow") || lower.contains("завтра") {
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
            "dd.MM.yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: text) { return d }
        }
        return nil
    }

    private func composeRelativeDate(dayOffset: Int, sourceText: String) -> Date? {
        var target = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: target)
        components.timeZone = .current

        if let (h, m) = extractTimeFromText(sourceText) {
            components.hour = h
            components.minute = m
        } else {
            components.hour = 9
            components.minute = 0
        }

        target = Calendar.current.date(from: components) ?? target
        return target
    }

    private func extractTimeFromText(_ text: String) -> (Int, Int)? {
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

    // MARK: - External Fetch

    private struct DuckDuckGoResponse: Decodable {
        let Abstract: String?
        let AbstractText: String?
        let RelatedTopics: [RelatedTopic]?

        struct RelatedTopic: Decodable {
            let Text: String?
        }
    }

    private struct WikipediaSummary: Decodable {
        let title: String?
        let extract: String?
    }

    private struct RedditListing: Decodable {
        let data: RedditListingData

        struct RedditListingData: Decodable {
            let children: [RedditChild]
        }

        struct RedditChild: Decodable {
            let data: RedditPost
        }

        struct RedditPost: Decodable {
            let title: String
            let url: String?
            let score: Int?
            let author: String?
            let createdUtc: TimeInterval?
        }
    }

    private func fetchDuckDuckGoSummary(query: String) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components.url else { return "" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)

        var parts: [String] = []
        if let abstract = decoded.Abstract, !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(abstract.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let abstractText = decoded.AbstractText, !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(abstractText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let relatedTexts = (decoded.RelatedTopics ?? [])
            .compactMap { $0.Text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)

        if !relatedTexts.isEmpty {
            parts.append(relatedTexts.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    private func fetchDuckDuckGoLiteResults(query: String, limit: Int = 4) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { return "" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return "" }

        let anchorPattern = "(?is)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: anchorPattern) else { return "" }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)

        var lines: [String] = []
        for match in matches {
            guard lines.count < limit else { break }
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var href = String(html[hrefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            title = decodeHTMLEntities(stripHTML(title))
            if title.isEmpty { continue }
            if title.lowercased().contains("next page") || title.lowercased().contains("duckduckgo") { continue }

            if href.hasPrefix("//") {
                href = "https:" + href
            } else if href.hasPrefix("/") {
                href = "https://lite.duckduckgo.com" + href
            }

            if href.isEmpty || href.hasPrefix("javascript:") { continue }
            lines.append("- \(title)\n  \(href)")
        }

        return lines.joined(separator: "\n")
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

    private func fetchWebSummaryWithFallback(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let candidates = searchQueryCandidates(from: trimmed)

        for candidate in candidates {
            // Try DDG twice to smooth over transient mobile connection resets.
            for _ in 0..<2 {
                if let ddg = try? await fetchDuckDuckGoSummary(query: candidate),
                   !ddg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ddg
                }
            }

            // Fallback: parse lightweight DDG HTML search results.
            if let lite = try? await fetchDuckDuckGoLiteResults(query: candidate),
               !lite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return lite
            }

            // Fallback: concise Wikipedia summary.
            let wiki = await fetchWikipediaSummary(topic: candidate)
            if !wiki.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return wiki
            }
        }

        return ""
    }

    private func searchQueryCandidates(from raw: String) -> [String] {
        var out: [String] = []
        out.append(raw)

        let lower = raw.lowercased()
        let patterns = [
            "найди информацию в интернете о",
            "найди в интернете",
            "найди информацию о",
            "информация в интернете о",
            "search the internet for",
            "find information about",
            "find info about",
            "look up"
        ]

        var topic = raw
        for p in patterns {
            if let range = lower.range(of: p) {
                // Convert the matched lowercased range into offsets
                let distanceFromStart = lower.distance(from: lower.startIndex, to: range.upperBound)
                if let rawStart = raw.index(raw.startIndex, offsetBy: distanceFromStart, limitedBy: raw.endIndex) {
                    topic = String(raw[rawStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }

        let punctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")
        topic = topic.trimmingCharacters(in: punctuation.union(.whitespacesAndNewlines))

        if !topic.isEmpty, topic.count >= 2, topic != raw {
            out.append(topic)
        }

        return Array(NSOrderedSet(array: out)) as? [String] ?? out
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

    private func fetchRedditNews(limit: Int) async throws -> String {
        let clamped = max(1, min(15, limit))
        var components = URLComponents(string: "https://www.reddit.com/r/news/.json")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(clamped)")
        ]

        guard let url = components.url else { return "" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("ValisAI/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(RedditListing.self, from: data)

        let items = decoded.data.children.map { $0.data }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        let lines: [String] = items.prefix(clamped).map { post in
            let title = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let score = post.score.map { "▲\($0)" } ?? "▲0"
            let age: String
            if let created = post.createdUtc {
                let date = Date(timeIntervalSince1970: created)
                age = formatter.localizedString(for: date, relativeTo: Date())
            } else {
                age = "unknown time"
            }
            let url = post.url ?? ""
            if url.isEmpty {
                return "- \(title) (\(score), \(age))"
            }
            return "- \(title) (\(score), \(age))\n  \(url)"
        }

        return lines.joined(separator: "\n")
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
}
