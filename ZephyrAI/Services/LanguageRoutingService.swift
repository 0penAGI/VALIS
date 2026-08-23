import Foundation
import NaturalLanguage

enum LanguageRoutingService {
    struct DetectionResult: Sendable {
        let code: String
        let confidence: Double
    }
    
    private static let lastDetectedLanguageKey = "lang.lastDetected"
    private static let englishLocale = Locale(identifier: "en_US")

    static func detectLanguage(for text: String) -> DetectionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[lang] ?? 0.0
        let code = lang.rawValue

        // Avoid forcing language on short/noisy prompts.
        if confidence < 0.42, trimmed.count < 28 {
            return nil
        }
        if confidence < 0.28 {
            return nil
        }
        return DetectionResult(code: code, confidence: Double(confidence))
    }

    static func detectedNormalizedCode(for text: String) -> String? {
        guard let detected = detectLanguage(for: text) else { return nil }
        let code = normalize(code: detected.code)
        return code.isEmpty ? nil : code
    }

    static func languageAnchor(for userText: String) -> String {
        if let result = detectLanguage(for: userText) {
            let code = normalize(code: result.code)
            if !code.isEmpty {
                UserDefaults.standard.set(code, forKey: lastDetectedLanguageKey)
            }
            return anchor(forNormalizedCode: code)
        }

        // If the current user prompt is too short/ambiguous, fall back to the last confidently
        // detected language from the session to keep replies consistent.
        if let last = UserDefaults.standard.string(forKey: lastDetectedLanguageKey),
           !last.isEmpty {
            return anchor(forNormalizedCode: normalize(code: last))
        }

        return ""
    }

    static func displayName(forNormalizedCode code: String) -> String? {
        guard !code.isEmpty else { return nil }
        return englishLocale.localizedString(forLanguageCode: code)
    }

    private static func normalize(code: String) -> String {
        // Normalize common variants (NaturalLanguage may return "ru", "fr", "de", etc).
        let lower = code.lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("pt") { return "pt" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("ru") { return "ru" }
        if lower.hasPrefix("fr") { return "fr" }
        if lower.hasPrefix("de") { return "de" }
        if lower.hasPrefix("es") { return "es" }
        if lower.hasPrefix("it") { return "it" }
        if lower.hasPrefix("uk") { return "uk" }
        if lower.hasPrefix("tr") { return "tr" }
        if lower.hasPrefix("id") { return "id" }
        if lower.hasPrefix("th") { return "th" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return lower
    }

    private static func anchor(forNormalizedCode code: String) -> String {
        switch code {
        case "ru":
            return "\n\nLanguage:\n- Reply in Russian.\n- Think in Russian.\n- Keep code as code."
        case "fr":
            return "\n\nLanguage:\n- Réponds en français.\n- Pense en français.\n- Garde le code en code."
        case "de":
            return "\n\nLanguage:\n- Antworte auf Deutsch.\n- Denke auf Deutsch.\n- Code bleibt Code."
        case "es":
            return "\n\nLanguage:\n- Responde en español.\n- Piensa en español.\n- Mantén el código como código."
        case "it":
            return "\n\nLanguage:\n- Rispondi in italiano.\n- Pensa in italiano.\n- Mantieni il codice come codice."
        case "uk":
            return "\n\nLanguage:\n- Відповідай українською.\n- Думай українською.\n- Код залишай кодом."
        case "th":
            return "\n\nLanguage:\n- ตอบเป็นภาษาไทย.\n- คิดเป็นภาษาไทย.\n- โค้ดให้คงรูปแบบโค้ด."
        case "zh":
            return "\n\nLanguage:\n- 用中文回答。\n- 用中文思考。\n- 保持代码原样。"
        case "ja":
            return "\n\nLanguage:\n- 日本語で答えてください。\n- 日本語で考えてください。\n- コードはそのままにしてください。"
        case "ko":
            return "\n\nLanguage:\n- 한국어로 답변하세요.\n- 한국어로 생각하세요.\n- 코드는 그대로 유지하세요."
        default:
            // For English/unknown, rely on the base system prompt ("Answer in the user's language").
            // We only force when we have a strong signal; other languages can be added here.
            return ""
        }
    }
}
