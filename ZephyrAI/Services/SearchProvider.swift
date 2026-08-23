import Foundation

// MARK: - Shared Models

struct SearchResult: Sendable, Equatable {
    let title: String
    let url: URL
    let snippet: String?

    init(title: String, url: URL, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

struct SearchResponse: Sendable {
    let query: String
    let results: [SearchResult]
    let answer: String?
    let source: String
}

// MARK: - Protocol

protocol SearchProvider: Sendable {
    var name: String { get }
    func search(_ query: String) async throws -> SearchResponse
}

// MARK: - Configuration

enum SearchConfig {
    static var searxngURL: String {
        get { UserDefaults.standard.string(forKey: "search.searxng_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "search.searxng_url") }
    }

    static var openserpURL: String {
        get { UserDefaults.standard.string(forKey: "search.openserp_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "search.openserp_url") }
    }
}

// MARK: - SearXNG Provider

final class SearXNGProvider: SearchProvider {
    let name = "searxng"
    private let baseURL: URL

    init?(baseURL: String) {
        let cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let url = URL(string: cleaned) else { return nil }
        self.baseURL = url
    }

    func search(_ query: String) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "language", value: "auto"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(SearXNGResponse.self, from: data)

        let results = decoded.results.map { r in
            SearchResult(title: r.title, url: r.url, snippet: r.content)
        }
        let answer = decoded.answers?.first

        return SearchResponse(query: query, results: results, answer: answer, source: name)
    }
}

private struct SearXNGResponse: Decodable {
    let query: String?
    let results: [SearXNGResult]
    let answers: [String]?
}

private struct SearXNGResult: Decodable {
    let title: String
    let url: URL
    let content: String?
}

// MARK: - OpenSERP Provider

final class OpenSERPProvider: SearchProvider {
    let name = "openserp"
    private let baseURL: URL

    init?(baseURL: String) {
        let cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let url = URL(string: cleaned) else { return nil }
        self.baseURL = url
    }

    func search(_ query: String) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/google/search"
        components.queryItems = [URLQueryItem(name: "text", value: query)]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(OpenSERPResponse.self, from: data)

        let results = decoded.organicResults.map { r in
            SearchResult(title: r.title, url: r.link, snippet: r.snippet)
        }

        return SearchResponse(query: query, results: results, answer: nil, source: name)
    }
}

private struct OpenSERPResponse: Decodable {
    let organicResults: [OpenSERPOrganic]

    enum CodingKeys: String, CodingKey {
        case organicResults = "organic_results"
    }
}

private struct OpenSERPOrganic: Decodable {
    let title: String
    let link: URL
    let snippet: String?
}

// MARK: - DuckDuckGo Instant Answer Provider

final class DuckDuckGoInstantProvider: SearchProvider {
    let name = "duckduckgo"

    func search(_ query: String) async throws -> SearchResponse {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(DDGInstantResponse.self, from: data)

        var parts: [String] = []
        if let abstract = decoded.Abstract, !abstract.isEmpty {
            parts.append(abstract)
        } else if let text = decoded.AbstractText, !text.isEmpty {
            parts.append(text)
        }
        let related = (decoded.RelatedTopics ?? [])
            .compactMap { $0.Text }
            .filter { !$0.isEmpty }
            .prefix(3)
        if !related.isEmpty {
            parts.append(related.joined(separator: "\n"))
        }

        return SearchResponse(
            query: query,
            results: [],
            answer: parts.isEmpty ? nil : parts.joined(separator: "\n\n"),
            source: name
        )
    }
}

private struct DDGInstantResponse: Decodable {
    let Abstract: String?
    let AbstractText: String?
    let RelatedTopics: [DDGRelatedTopic]?
}

private struct DDGRelatedTopic: Decodable {
    let Text: String?
}

// MARK: - DuckDuckGo Lite HTML Fallback Provider

final class DuckDuckGoLiteProvider: SearchProvider {
    let name = "duckduckgo-lite"

    func search(_ query: String) async throws -> SearchResponse {
        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        let anchorPattern = "(?is)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: anchorPattern) else {
            throw URLError(.cannotParseResponse)
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)

        var results: [SearchResult] = []
        for match in matches {
            guard results.count < 6 else { break }
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var href = String(html[hrefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            title = decodeHTMLEntities(stripHTML(title))
            if title.isEmpty { continue }
            let lower = title.lowercased()
            if lower.contains("next page") || lower.contains("duckduckgo") { continue }

            if href.hasPrefix("//") { href = "https:" + href }
            else if href.hasPrefix("/") { href = "https://lite.duckduckgo.com" + href }

            guard !href.isEmpty, !href.hasPrefix("javascript:"),
                  let url = URL(string: href) else { continue }
            results.append(SearchResult(title: title, url: url, snippet: nil))
        }

        return SearchResponse(query: query, results: results, answer: nil, source: name)
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var out = text
        let map: [String: String] = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

// MARK: - Wikipedia Provider

final class WikipediaSearchProvider: SearchProvider {
    let name = "wikipedia"

    func search(_ query: String) async throws -> SearchResponse {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(WikiSummaryResponse.self, from: data)

        let extract = decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var results: [SearchResult] = []
        if let title = decoded.title, !title.isEmpty {
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            let pageURL = URL(string: "https://en.wikipedia.org/wiki/\(encoded)")!
            results.append(SearchResult(title: title, url: pageURL, snippet: extract))
        }

        return SearchResponse(
            query: query,
            results: results,
            answer: extract.isEmpty ? nil : extract,
            source: name
        )
    }
}

private struct WikiSummaryResponse: Decodable {
    let title: String?
    let extract: String?
}

// MARK: - Free Search API (searchfree.site) — работает без регистрации

final class FreeSearchAPIProvider: SearchProvider {
    let name = "freesearch"

    private struct RequestBody: Encodable {
        let query: String
        let searchDepth: String = "advanced"
        let maxResults: Int = 6
        let includeAnswer: Bool = true

        enum CodingKeys: String, CodingKey {
            case query
            case searchDepth = "search_depth"
            case maxResults = "max_results"
            case includeAnswer = "include_answer"
        }
    }

    private struct ResponseBody: Decodable {
        let query: String?
        let answer: String?
        let results: [FreeSearchResult]?
    }

    private struct FreeSearchResult: Decodable {
        let title: String
        let url: URL
        let content: String?
    }

    func search(_ query: String) async throws -> SearchResponse {
        guard let url = URL(string: "https://searchfree.site/api/search") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body = RequestBody(query: query)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)

        let results = (decoded.results ?? []).map { r in
            SearchResult(title: r.title, url: r.url, snippet: r.content)
        }
        let answer = decoded.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchResponse(
            query: query,
            results: results,
            answer: answer?.isEmpty == false ? answer : nil,
            source: name
        )
    }
}

// MARK: - Multi-Search Orchestrator

final class MultiSearchProvider: Sendable {
    private let providers: [SearchProvider]

    init(providers: [SearchProvider]) {
        self.providers = providers
    }

    static func makeDefault() -> MultiSearchProvider {
        var chain: [SearchProvider] = []

        // Free Search API — работает без регистрации и ключей.
        chain.append(FreeSearchAPIProvider())

        // SearXNG — если пользователь указал свой инстанс.
        if let searxng = SearXNGProvider(baseURL: SearchConfig.searxngURL) {
            chain.append(searxng)
        }
        // OpenSERP — если локальный сервер запущен.
        if let openserp = OpenSERPProvider(baseURL: SearchConfig.openserpURL) {
            chain.append(openserp)
        }

        // Бесплатные fallback-ы без ключей.
        chain.append(DuckDuckGoInstantProvider())
        chain.append(WikipediaSearchProvider())
        chain.append(DuckDuckGoLiteProvider())

        return MultiSearchProvider(providers: chain)
    }

    func search(_ query: String) async -> SearchResponse? {
        for provider in providers {
            do {
                let response = try await provider.search(query)
                if !response.results.isEmpty || (response.answer?.isEmpty == false) {
                    return response
                }
            } catch {
                continue
            }
        }
        return nil
    }

    func searchSummary(_ query: String) async -> String? {
        for provider in providers {
            do {
                let response = try await provider.search(query)
                if let answer = response.answer, !answer.isEmpty {
                    return answer
                }
                if !response.results.isEmpty {
                    let snippets = response.results.compactMap { $0.snippet }.filter { !$0.isEmpty }
                    if !snippets.isEmpty {
                        return snippets.prefix(3).joined(separator: "\n")
                    }
                    return response.results.first?.title
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
