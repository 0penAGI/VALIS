import Foundation

protocol AutonomousMemorySource {
    var name: String { get }
    func fetchSnippets(for topic: String) async -> [String]
}

struct WikipediaSource: AutonomousMemorySource {
    let name = "wikipedia"

    func fetchSnippets(for topic: String) async -> [String] {
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let escaped = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleaned
        let urlString = "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)"
        guard let url = URL(string: urlString) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("VALISAI/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }

            let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            let summary = decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if summary.isEmpty { return [] }
            return [summary]
        } catch {
            print("❌ \(name) fetch error:", error)
            return []
        }
    }

    private struct WikipediaSummary: Decodable {
        let title: String?
        let extract: String?
    }
}

struct DuckDuckGoSource: AutonomousMemorySource {
    let name = "duckduckgo"

    func fetchSnippets(for topic: String) async -> [String] {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("VALISAI/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }

            let decoded = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)

            var parts: [String] = []
            if let abstract = decoded.Abstract, !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(abstract.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let abstractText = decoded.AbstractText, !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(abstractText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let relatedTexts = (decoded.RelatedTopics ?? [])
                .flatMap { topic -> [String] in
                    if let text = topic.Text {
                        return [text]
                    }
                    return topic.Topics?.compactMap { $0.Text } ?? []
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(2)

            if !relatedTexts.isEmpty {
                parts.append(relatedTexts.joined(separator: "\n"))
            }

            return parts
        } catch {
            print("❌ \(name) fetch error:", error)
            return []
        }
    }

    private struct DuckDuckGoResponse: Decodable {
        let Abstract: String?
        let AbstractText: String?
        let RelatedTopics: [RelatedTopic]?

        struct RelatedTopic: Decodable {
            let Text: String?
            let Topics: [RelatedTopic]?
        }
    }
}
