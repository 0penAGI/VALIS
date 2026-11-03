import Foundation

/// VoiceLayerService
/// Transforms assistant prose into a more present, less mechanical voice
/// without changing protected blocks like <think>, <artifact>, code fences,
/// or TOOL/ACTION lines.
@MainActor
struct VoiceLayerService {
    struct Config {
        /// 0.0...1.0, higher means more assertive voice shaping.
        var presenceStrength: Float = 0.82
        /// Insert light rhythmic breaks in low-intensity responses.
        var allowRhythmicBreaks: Bool = true
        /// Remove formulaic assistant openers and closers.
        var stripSycophancy: Bool = true
    }

    var config: Config
    private let emotionService: EmotionService

    init(config: Config = Config(), emotionService: EmotionService) {
        self.config = config
        self.emotionService = emotionService
    }

    func apply(to text: String) -> String {
        apply(to: text, tone: .neutral)
    }

    func apply(to text: String, tone: ToneCluster = .neutral) -> String {
        guard !text.isEmpty else { return text }

        let protected = protectedRanges(in: text)
        guard !protected.isEmpty else {
            return applyVoice(to: text, tone: tone)
        }

        var output = ""
        var cursor = text.startIndex

        for range in protected {
            guard let start = Range(range, in: text) else { continue }
            if cursor < start.lowerBound {
                output += applyVoice(to: String(text[cursor..<start.lowerBound]), tone: tone)
            }
            output += String(text[start])
            cursor = start.upperBound
        }

        if cursor < text.endIndex {
            output += applyVoice(to: String(text[cursor...]), tone: tone)
        }

        return output
    }

    private func applyVoice(to text: String, tone: ToneCluster) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        var result = text
        result = prepareForSpeech(result)

        if config.stripSycophancy {
            result = stripSycophancy(result)
            result = stripAssistantOpeners(result, strength: tone.rawValue)
        }

        result = applyPresence(result, tone: tone)

        if config.allowRhythmicBreaks {
            result = addRhythm(result, emotion: emotionService.state)
        }

        if tone == .collapsed {
            result = dropFirstParagraphIfServile(result)
        }

        result = finalizeForSpeech(result)
        return result
    }

    private func protectedRanges(in text: String) -> [NSRange] {
        let patterns = [
            #"(?is)```.*?(?:```|$)"#,
            #"(?s)`[^`\n]+`"#,
            #"(?s)!?\[[^\]\n]+\]\([^\)\n]+\)"#,
            #"(?s)(?<!\*)\*\*.+?\*\*(?!\*)"#,
            #"(?s)(?<!_)__(?!\s).+?(?<!\s)__(?!_)"#,
            #"(?s)(?<!\*)\*(?!\s)(?!\*)(.+?)(?<!\s)\*(?!\*)"#,
            #"(?s)(?<!_)_(?!\s)(.+?)(?<!\s)_(?!_)"#,
            #"(?is)<think\b[^>]*>.*?(?:</think>|$)"#,
            #"(?is)<artifact\b[^>]*>.*?(?:</artifact>|$)"#,
            #"(?im)^[ \t]*(?:TOOL|ACTION)\s*:[^\n]*$"#
        ]

        var ranges: [NSRange] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            ranges.append(contentsOf: regex.matches(in: text, range: nsRange).map(\.range))
        }

        return mergeRanges(ranges)
    }

    private func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }

        var merged: [NSRange] = []
        for range in sorted {
            guard range.length > 0 else { continue }
            if let last = merged.last,
               last.location + last.length >= range.location {
                let upperBound = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: upperBound - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func stripSycophancy(_ text: String) -> String {
        let patterns = [
            #"(?im)^\s*(?:Конечно|Разумеется|Безусловно|С удовольствием|Рад помочь|С радостью|Of course|Certainly|Absolutely|Sure|Happy to help|I(?:'|’)m happy to help|I(?:'|’)m glad to help)[!,.…\s-]*"#,
            #"(?im)^\s*(?:Если у вас есть ещё вопросы — я здесь!|Если нужна помощь — обращайтесь!|Не стесняйтесь спрашивать!)[\s]*$"#
        ]

        var result = text
        for pattern in patterns {
            result = replacing(pattern: pattern, in: result)
        }
        return result
    }

    private func stripAssistantOpeners(_ text: String, strength: Float) -> String {
        var patterns = [
            #"(?im)^\s*Как\s+(?:ИИ|языковая модель|AI|искусственный интеллект)[^.\n]*[.\n]\s*"#,
            #"(?im)^\s*Позвольте мне\s+"#,
            #"(?im)^\s*Давайте\s+я\s+"#,
            #"(?im)^\s*Я\s+здесь\s+чтобы\s+помочь\s+и\s+поддержать[.\s!]*"#,
            #"(?im)^\s*Я\s+помогу[^.\n]*[.\n]\s*"#,
            #"(?im)^\s*Я\s+постараюсь[^.\n]*[.\n]\s*"#,
        ]

        if strength > 0.5 {
            patterns += [
                #"(?im)^\s*(?:Конечно|Разумеется|Безусловно|С удовольствием|Рад помочь|С радостью)[!,.…\s-]*"#,
                #"(?im)^\s*(?:Of course|Certainly|Absolutely|Sure|Great question|Happy to help|I(?:'|’)m happy to help|I(?:'|’)m glad to help)[!,.…\s-]*"#
            ]
        }

        var result = text
        for pattern in patterns {
            result = replacing(pattern: pattern, in: result)
        }
        return result
    }

    private func applyPresence(_ text: String, tone: ToneCluster) -> String {
        guard config.presenceStrength > 0.15 else { return text }

        var result = text
        result = result.replacingOccurrences(of: "в данном контексте", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "в данной ситуации", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "необходимо отметить, что ", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "следует отметить, что ", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "важно подчеркнуть, что ", with: "", options: .caseInsensitive)

        if config.presenceStrength > 0.5 || tone.rawValue >= ToneCluster.assistant.rawValue {
            result = result.replacingOccurrences(of: "является ", with: "— ", options: .caseInsensitive)
        }

        // Remove weak modal verbs to strengthen delivery
        result = result.replacingOccurrences(of: "может быть ", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "возможно ", with: "", options: .caseInsensitive)

        return result
    }

    private func dropFirstParagraphIfServile(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard paragraphs.count > 1 else { return text }

        let first = paragraphs[0].lowercased()
        let boilerplateSignals = [
            "помочь", "поддержать", "здесь для", "рад", "конечно", "assistant", "help",
            "i'm here", "i am here", "happy to help", "glad to help"
        ]
        let soulSignals = [
            "я думаю", "я чувствую", "мне кажется", "похоже", "вижу",
            "слышу", "образ", "смысл", "тема", "контраст", "неожидан"
        ]
        let isBoilerplate = boilerplateSignals.contains { first.contains($0) }
        let hasSoul = soulSignals.contains { first.contains($0) }
        let isShortEnoughToBeIntro = first.count <= 220

        return isBoilerplate && !hasSoul && isShortEnoughToBeIntro
            ? paragraphs.dropFirst().joined(separator: "\n\n")
            : text
    }

    private func addRhythm(_ text: String, emotion: EmotionState) -> String {
        guard config.presenceStrength > 0.35 else { return text }
        guard emotion.intensity < 0.6 else { return text }

        var result = text

        let doubleAnd = #"(\w+) и (\w+) и (\w+)"#
        if let regex = try? NSRegularExpression(pattern: doubleAnd) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1 и $2 — и $3"
            )
        }

        return result
    }

    private func cleanUp(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        result = result.replacingOccurrences(of: " —  ", with: " — ")
        result = result.replacingOccurrences(of: " -  ", with: " - ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Prepares text BEFORE stylistic shaping for better semantic clarity and TTS stability
    private func prepareForSpeech(_ text: String) -> String {
        var result = text

        // Normalize dashes and quotes
        result = result
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "\"", with: "")

        // Break overly long sentences (improves TTS breathing)
        let longSentence = #"([^.]{120,})\."#
        if let regex = try? NSRegularExpression(pattern: longSentence) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1.\n"
            )
        }



        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Final pass tuned specifically for TTS output
    private func finalizeForSpeech(_ text: String) -> String {
        var result = cleanUp(text)

        // Ensure sentence endings are clear
        result = result.replacingOccurrences(of: " - ", with: " ")

        // Normalize spacing again after transformations
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacing(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
