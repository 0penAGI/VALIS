import Foundation

struct ToolPrediction {
    let search: Bool
    let news: Bool
    let weather: Bool
    let health: Bool
    let system: Bool
    let calendar: CalendarIntent
    let wiki: Bool
    let urlAnalysis: [String]

    enum CalendarIntent {
        case none
        case list
        case open
        case create
    }

    static let none = ToolPrediction(
        search: false, news: false, weather: false, health: false, system: false,
        calendar: .none, wiki: false, urlAnalysis: []
    )
}

struct IntentRouter {
    static func classify(_ prompt: String) -> ToolPrediction {
        let text = normalizedText(prompt)
        let lower = text.lowercased()

        let search = detectSearch(lower)
        let news = detectNews(lower)
        let weather = detectWeather(lower)
        let health = detectHealth(lower)
        let system = detectSystem(lower)
        let calendar = detectCalendar(lower)
        let wiki = detectWiki(lower)
        let urls = extractURLs(from: text)

        return ToolPrediction(
            search: search,
            news: news,
            weather: weather,
            health: health,
            system: system,
            calendar: calendar,
            wiki: wiki,
            urlAnalysis: urls
        )
    }

    // MARK: - Search

    private static func detectSearch(_ lower: String) -> Bool {
        let localHints = [
            "calendar", "event", "reminder", "schedule", "appointment",
            "календар", "событ", "напоминан", "встреч", "расписан"
        ]
        if localHints.contains(where: { lower.contains($0) }) { return false }
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") { return false }

        let direct = [
            "search", "google", "web", "internet", "look up", "lookup", "find online",
            "find info", "research", "info", "details", "learn more",
            "найди", "найти", "узнай", "инфу", "информация", "поиск", "в интернете", "загугли", "поищи", "погугли"
        ]
        if direct.contains(where: { lower.contains($0) }) { return true }

        let freshness = [
            "latest", "today", "current", "recent", "up to date", "new update", "breaking",
            "сегодня", "последние", "свежие", "актуаль", "что нового", "новости"
        ]
        if freshness.contains(where: { lower.contains($0) }) { return true }

        return false
    }

    // MARK: - News

    private static func detectNews(_ lower: String) -> Bool {
        let triggers = [
            "news", "latest", "headlines", "breaking",
            "новости", "свежие новости", "последние новости", "что нового"
        ]
        return triggers.contains { lower.contains($0) }
    }

    // MARK: - Weather

    private static func detectWeather(_ lower: String) -> Bool {
        let triggers = [
            "weather", "forecast", "temperature", "rain", "sunny", "cloudy", "snow",
            "погода", "прогноз", "температура", "дождь", "снег", "облачно", "солнечно"
        ]
        return triggers.contains { lower.contains($0) }
    }

    // MARK: - Health / System

    private static func detectHealth(_ lower: String) -> Bool {
        let triggers = [
            "steps", "step count", "activity", "health", "workout", "fitness",
            "шаги", "активность", "здоров", "трениров", "пульс"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private static func detectSystem(_ lower: String) -> Bool {
        let triggers = [
            "battery", "storage", "memory", "thermal", "device", "system info",
            "заряд", "батаре", "память", "памяти", "хранилищ", "устройств", "система"
        ]
        return triggers.contains { lower.contains($0) }
    }

    // MARK: - Calendar

    private static func detectCalendar(_ lower: String) -> ToolPrediction.CalendarIntent {
        let hasCalendarSignal = lower.contains("calendar") || lower.contains("event") ||
            lower.contains("reminder") || lower.contains("meeting") ||
            lower.contains("schedule") || lower.contains("appointment") ||
            lower.contains("календар") || lower.contains("событ") ||
            lower.contains("напомин") || lower.contains("встреч") ||
            lower.contains("расписан")

        guard hasCalendarSignal else { return .none }

        let createSignals = [
            "create", "make", "add", "set", "schedule", "book", "plan", "arrange",
            "создай", "добавь", "поставь", "запланируй", "назначь"
        ]
        if createSignals.contains(where: { lower.contains($0) }) { return .create }

        let reminderSignals = ["reminder", "remind", "напомин", "напомни"]
        if reminderSignals.contains(where: { lower.contains($0) }) { return .create }

        let listSignals = [
            "show", "list", "upcoming", "agenda", "what's on",
            "покажи", "список", "какие события", "что в календаре"
        ]
        if listSignals.contains(where: { lower.contains($0) }) { return .list }

        let openSignals = [
            "open", "открой", "покажи календарь"
        ]
        if openSignals.contains(where: { lower.contains($0) }) { return .open }

        return .none
    }

    // MARK: - Wiki

    private static func detectWiki(_ lower: String) -> Bool {
        let triggers = [
            "who is", "who was", "what is", "what was",
            "tell me about", "tell me more about", "tell me about",
            "explain", "define", " biography",
            "кто такой", "кто такая", "кто такие",
            "что такое", "что за",
            "расскажи подробнее", "расскажи мне", "расскажи про", "расскажи о",
            "объясни", "опиши"
        ]
        return triggers.contains { lower.contains($0) }
    }

    // MARK: - Helpers

    private static func normalizedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return trimmed }
        let prefixes = [
            "user question:", "question:", "user prompt:", "prompt:", "query:"
        ]
        let lowerFirst = first.lowercased()
        guard let prefix = prefixes.first(where: { lowerFirst.hasPrefix($0) }) else {
            return trimmed
        }
        let remainder = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = lines.dropFirst()
        return ([remainder] + tail).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, range: range)
        var results: [String] = []
        for match in matches {
            guard let urlRange = Range(match.range, in: text) else { continue }
            let urlString = String(text[urlRange])
            guard let url = URL(string: urlString),
                  let scheme = url.scheme,
                  scheme == "http" || scheme == "https" else { continue }
            results.append(url.absoluteString)
            if results.count >= 2 { break }
        }
        return results
    }
}
