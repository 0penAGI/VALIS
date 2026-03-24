import Foundation

struct ResponseDriftSignal: Codable, Equatable {
    let anchorRetention: Double
    let metaphorLoad: Double
    let selfFocus: Double
    let abstractionLoad: Double
    let repetitionLoad: Double
    let userEchoLoad: Double
    let driftScore: Double
    let mode: String

    var isDrifting: Bool {
        driftScore >= 0.58 || repetitionLoad > 0.46 || (anchorRetention < 0.26 && metaphorLoad > 0.22)
    }
}

final class ResponseDriftService {
    static let shared = ResponseDriftService()

    private init() {}

    func analyze(userPrompt: String, assistantText: String, previousAssistantText: String? = nil) -> ResponseDriftSignal {
        let userTerms = Set(contentTerms(from: userPrompt))
        let assistantTerms = Set(contentTerms(from: assistantText))
        let overlap = userTerms.intersection(assistantTerms).count
        let anchorRetention = userTerms.isEmpty ? 0.5 : clamp(Double(overlap) / Double(max(1, userTerms.count)))

        let lower = assistantText.lowercased()
        let metaphorMarkers = [
            "as if", "like a", "echo", "shadow", "light", "field", "infinite", "abyss", "pulse", "dream",
            "как будто", "словно", "эхо", "тень", "свет", "поле", "бесконеч", "бездна", "пульсац", "сон"
        ]
        let selfMarkers = [
            " i ", " i'm", " i’m", " my ", " me ", " myself ", " я ", " мне ", " меня ", " мой ", " моя ", " мое ", " моё "
        ]
        let abstractMarkers = [
            "consciousness", "subjectivity", "architecture", "system", "state", "meaning", "coherence",
            "сознани", "субъектив", "архитектур", "система", "состояни", "смысл", "когерент", "мета"
        ]

        let metaphorLoad = markerLoad(in: lower, markers: metaphorMarkers, weight: 0.16)
        let selfFocus = markerLoad(in: " " + lower + " ", markers: selfMarkers, weight: 0.12)
        let abstractionLoad = markerLoad(in: lower, markers: abstractMarkers, weight: 0.11)
        let repetitionLoad = repeatedPhraseLoad(in: assistantText, previousAssistantText: previousAssistantText)
        let userEchoLoad = echoLoad(userPrompt: userPrompt, assistantText: assistantText)
        let driftScore = clamp(
            ((1.0 - anchorRetention) * 0.40) +
            (metaphorLoad * 0.15) +
            (selfFocus * 0.10) +
            (abstractionLoad * 0.10) +
            (repetitionLoad * 0.17) +
            (userEchoLoad * 0.08)
        )

        let mode: String
        if repetitionLoad >= 0.58 {
            mode = "repetition-loop"
        } else if userEchoLoad >= 0.52 {
            mode = "user-echo"
        } else if driftScore >= 0.72 {
            mode = "lost-anchor"
        } else if metaphorLoad >= 0.34 {
            mode = "metaphor-drift"
        } else if selfFocus >= 0.32 {
            mode = "self-absorption"
        } else if abstractionLoad >= 0.32 {
            mode = "abstracted"
        } else {
            mode = "stable"
        }

        return ResponseDriftSignal(
            anchorRetention: anchorRetention,
            metaphorLoad: metaphorLoad,
            selfFocus: selfFocus,
            abstractionLoad: abstractionLoad,
            repetitionLoad: repetitionLoad,
            userEchoLoad: userEchoLoad,
            driftScore: driftScore,
            mode: mode
        )
    }

    func contextBlock(for signal: ResponseDriftSignal, maxChars: Int = 180) -> String {
        let block = String(
            format: "\n\nDrift monitor: anchor=%.2f metaphor=%.2f self_focus=%.2f abstraction=%.2f repetition=%.2f echo=%.2f mode=%@",
            signal.anchorRetention,
            signal.metaphorLoad,
            signal.selfFocus,
            signal.abstractionLoad,
            signal.repetitionLoad,
            signal.userEchoLoad,
            signal.mode
        )
        if block.count <= maxChars {
            return block
        }
        return "\n\n" + String(block.prefix(maxChars))
    }

    func repairRepeatedOutput(userPrompt: String, assistantText: String) -> String {
        let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var kept: [String] = []
        var seen = Set<String>()
        let userNormalized = normalizeForComparison(userPrompt)

        for sentence in splitSentences(trimmed) {
            let normalized = normalizeForComparison(sentence)
            guard normalized.count > 1 else { continue }
            if seen.contains(normalized) { continue }
            if normalized == userNormalized && kept.isEmpty { continue }
            if userNormalized.count > 18 && normalized.hasPrefix(userNormalized) && kept.isEmpty { continue }
            seen.insert(normalized)
            kept.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if kept.isEmpty {
            return trimmed
        }

        let separator = trimmed.contains("\n") ? "\n\n" : " "
        let repaired = kept.joined(separator: separator)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if repaired.isEmpty {
            return trimmed
        }
        return repaired
    }

    private func markerLoad(in text: String, markers: [String], weight: Double) -> Double {
        let hits = markers.reduce(0) { partial, marker in
            partial + (text.contains(marker) ? 1 : 0)
        }
        return clamp(Double(hits) * weight)
    }

    private func repeatedPhraseLoad(in text: String, previousAssistantText: String?) -> Double {
        let sentences = splitSentences(text)
            .map(normalizeForComparison)
            .filter { $0.count > 18 }
        guard !sentences.isEmpty else { return 0.0 }

        var repeated = 0
        var seen = Set<String>()
        for sentence in sentences {
            if seen.contains(sentence) {
                repeated += 1
            } else {
                seen.insert(sentence)
            }
        }

        var score = Double(repeated) / Double(max(1, sentences.count))
        if let previousAssistantText {
            let previous = Set(splitSentences(previousAssistantText).map(normalizeForComparison).filter { $0.count > 18 })
            let overlap = sentences.filter { previous.contains($0) }.count
            score += Double(overlap) / Double(max(1, sentences.count)) * 0.6
        }

        return clamp(score)
    }

    private func echoLoad(userPrompt: String, assistantText: String) -> Double {
        let user = normalizeForComparison(userPrompt)
        let assistant = normalizeForComparison(assistantText)
        guard !user.isEmpty, !assistant.isEmpty else { return 0.0 }
        if assistant == user { return 1.0 }
        if assistant.hasPrefix(user) && user.count > 18 { return 0.88 }

        let userTerms = Set(contentTerms(from: userPrompt))
        let assistantTerms = Set(contentTerms(from: assistantText))
        guard !assistantTerms.isEmpty else { return 0.0 }
        let overlap = userTerms.intersection(assistantTerms).count
        let overlapScore = Double(overlap) / Double(max(1, assistantTerms.count))
        let ratioPenalty = assistantTerms.count <= max(3, userTerms.count / 2) ? 0.18 : 0.0
        return clamp(overlapScore + ratioPenalty)
    }

    private func splitSentences(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count > 1 {
            return paragraphs
        }

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.isEmpty ? [normalized.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } : lines
    }

    private func normalizeForComparison(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contentTerms(from text: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "into", "your", "what", "when", "have",
            "это", "как", "что", "когда", "если", "тогда", "потому", "просто", "здесь", "там", "внутри"
        ]

        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
