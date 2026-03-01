import Foundation

@MainActor
final class CodeCoachService {
    static let shared = CodeCoachService()

    private init() {}

    func contextBlock(for prompt: String, detail: DetailLevel) -> String {
        guard shouldActivate(for: prompt) else { return "" }

        let languageHint = preferredLanguageHint(for: prompt)
        let strictness = strictnessHint(for: detail)

        return """

Code Coach (active):
- You are writing production-grade code. Prioritize correctness over cleverness.
- Keep changes minimal and compatible with existing architecture and style.
- Validate inputs and fail safely with explicit errors.
- Avoid invented APIs; use only realistic, existing platform/library calls.
- Include a compact test strategy (or concrete test cases) for changed behavior.
- Mention assumptions briefly when they affect correctness.
\(languageHint)
\(strictness)

"""
    }

    private func shouldActivate(for text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [
            "code", "coding", "function", "class", "method", "refactor", "bug", "fix", "compile", "build", "test",
            "swift", "ios", "xcode", "python", "javascript", "typescript", "html", "css", "sql", "api",
            "код", "функц", "класс", "метод", "рефактор", "баг", "ошибк", "исправ", "собери", "компил", "тест"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private func preferredLanguageHint(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("swift") || lower.contains("ios") || lower.contains("xcode") {
            return "- Prefer idiomatic Swift and iOS APIs; keep concurrency and MainActor safety explicit."
        }
        if lower.contains("python") {
            return "- Prefer typed Python where useful and deterministic behavior over shortcuts."
        }
        if lower.contains("javascript") || lower.contains("typescript") || lower.contains("html") || lower.contains("css") {
            return "- Prefer safe browser code, minimal dependencies, and clear separation of HTML/CSS/JS."
        }
        return "- Use idiomatic language patterns for the requested stack."
    }

    private func strictnessHint(for detail: DetailLevel) -> String {
        switch detail {
        case .brief:
            return "- Keep explanations short, but keep code safeguards and tests."
        case .balanced:
            return "- Provide concise explanation and explicit edge-case handling."
        case .detailed:
            return "- Provide robust edge-case coverage and stronger validation."
        }
    }
}
