import Foundation

enum LLMModelChoice: String, CaseIterable, Identifiable {
    case small
    case medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:
            return "LFM 2.5"
        case .medium:
            return "Qwen 3"
        }
    }

    var detailLabel: String {
        switch self {
        case .small:
            return "1.2B"
        case .medium:
            return "1.7B"
        }
    }

    var filename: String {
        switch self {
        case .small:
            return "LFM2.5-1.2B-Thinking-Q8_0.gguf"
        case .medium:
            return "Qwen3-1.7B-Q4_K_M.gguf"
        }
    }

    var downloadURLString: String? {
        switch self {
        case .small:
            return "https://huggingface.co/unsloth/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q8_0.gguf?download=true"
        case .medium:
            return "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf?download=true"
        }
    }
}

enum LLMModelStorage {
    static let key = "llm.selectedModel"
    static let defaultValue: LLMModelChoice = .medium

    static func load() -> LLMModelChoice {
        if let raw = UserDefaults.standard.string(forKey: key),
           let choice = LLMModelChoice(rawValue: raw) {
            return choice
        }
        return defaultValue
    }

    static func save(_ choice: LLMModelChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: key)
        NotificationCenter.default.post(name: .llmModelDidChange, object: nil)
    }
}

extension Notification.Name {
    static let llmModelDidChange = Notification.Name("llmModelDidChange")
}
