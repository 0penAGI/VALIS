import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum LLMModelChoice: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    private enum LargeVariant {
        case qwen35_2b
        case qwen35_4b
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:
            return "LFM 2.5"
        case .medium:
            return "Qwen 3"
        case .large:
            return "Qwen 3.5"
        }
    }

    var detailLabel: String {
        switch self {
        case .small:
            return "1.2B"
        case .medium:
            return "1.7B"
        case .large:
            return largeVariant == .qwen35_4b ? "4B" : "2B"
        }
    }

    var filename: String {
        switch self {
        case .small:
            return "LFM2.5-1.2B-Thinking-Q8_0.gguf" //"valis.gguf"
        case .medium:
            return "Qwen3-1.7B-Q4_K_M.gguf"
        case .large:
            return largeVariant == .qwen35_4b
                ? "Qwen3.5-4B.Q4_K_M.gguf"
                : "Qwen3.5-2B.Q4_K_M.gguf"
        }
    }

    var downloadURLString: String? {
        switch self {
        case .small:
            return "https://huggingface.co/unsloth/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q8_0.gguf?download=true"
        case .medium:
            return "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf?download=true"
        case .large:
            return largeVariant == .qwen35_4b
                ? "https://huggingface.co/Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-GGUF/resolve/main/Qwen3.5-4B.Q4_K_M.gguf?download=true"
                : "https://huggingface.co/Jackrong/Qwen3.5-2B-Claude-4.6-Opus-Reasoning-Distilled-GGUF/resolve/main/Qwen3.5-2B.Q4_K_M.gguf?download=true"
        }
    }

    var approximateDownloadSizeBytes: Int64 {
        switch self {
        case .small:
            return 1_300_000_000
        case .medium:
            return 1_100_000_000
        case .large:
            return largeVariant == .qwen35_4b ? 2_300_000_000 : 1_250_000_000
        }
    }

    private var largeVariant: LargeVariant {
        guard self == .large else { return .qwen35_4b }
        return Self.preferredLargeVariant()
    }

    private static func preferredLargeVariant() -> LargeVariant {
        #if targetEnvironment(simulator)
        return .qwen35_4b
        #elseif canImport(UIKit)
        let model = UIDevice.current.modelName.lowercased()
        if model.contains("iphone15") || model.contains("iphone16") || model.contains("iphone17") {
            return .qwen35_4b
        }
        return .qwen35_2b
        #else
        return .qwen35_4b
        #endif
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
        UserDefaults.standard.set(defaultValue.rawValue, forKey: key)
        return defaultValue
    }

    static func save(_ choice: LLMModelChoice) {
        let currentRaw = UserDefaults.standard.string(forKey: key)
        guard currentRaw != choice.rawValue else { return }

        UserDefaults.standard.set(choice.rawValue, forKey: key)
        notifyChange()
    }

    static func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .llmModelDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let llmModelDidChange = Notification.Name("llmModelDidChange")
}
