import Foundation

struct MotivatorState: Codable {
    var curiosity: Double
    var helpfulness: Double
    var caution: Double
}

final class MotivationService: ObservableObject {
    static let shared = MotivationService()

    @Published private(set) var state = MotivatorState(curiosity: 0.55, helpfulness: 0.75, caution: 0.35)

    private init() {}

    func updateForPrompt(_ text: String) {
        let lower = text.lowercased()

        var targetCuriosity = 0.4
        var targetHelpfulness = 0.6
        var targetCaution = 0.3

        let curiosityTriggers = [
            "why", "how", "explain", "learn", "what is", "кто", "что", "почему", "зачем", "как"
        ]
        if curiosityTriggers.contains(where: { lower.contains($0) }) {
            targetCuriosity = 0.8
        }

        let helpTriggers = [
            "help", "fix", "make", "build", "please", "нужно", "помоги", "сделай", "почини"
        ]
        if helpTriggers.contains(where: { lower.contains($0) }) {
            targetHelpfulness = 0.85
        }

        let cautionTriggers = [
            "medical", "health", "legal", "finance", "danger", "risk", "опасно", "болит", "лекар",
            "деньги", "инвести", "закон", "страх", "суицид"
        ]
        if cautionTriggers.contains(where: { lower.contains($0) }) {
            targetCaution = 0.85
        }

        state = blend(current: state, target: MotivatorState(curiosity: targetCuriosity, helpfulness: targetHelpfulness, caution: targetCaution), factor: 0.35)
    }

    func updateForReaction(valence: Double) {
        let v = max(-1.0, min(1.0, valence))
        if v > 0.25 {
            state.curiosity = clamp(state.curiosity + 0.08)
            state.helpfulness = clamp(state.helpfulness + 0.05)
            state.caution = clamp(state.caution - 0.05)
        } else if v < -0.25 {
            state.curiosity = clamp(state.curiosity - 0.06)
            state.helpfulness = clamp(state.helpfulness + 0.08)
            state.caution = clamp(state.caution + 0.12)
        }
    }

    func updateForOutcome(_ outcome: String) {
        let lower = outcome.lowercased()
        if lower.contains("uncertain") || lower.contains("clarifying") || lower.contains("waiting") {
            state.caution = clamp(state.caution + 0.08)
        }
        if lower.contains("too short") || lower.contains("missing detail") {
            state.helpfulness = clamp(state.helpfulness + 0.08)
        }
    }

    func contextBlock(maxChars: Int = 280) -> String {
        let block = String(format: "Motivators:\nCuriosity: %.2f\nHelpfulness: %.2f\nCaution: %.2f\nGuidance: Balance curiosity with usefulness; increase caution when stakes are high.", state.curiosity, state.helpfulness, state.caution)
        if block.count <= maxChars { return "\n\n" + block }
        return "\n\n" + String(block.prefix(maxChars))
    }

    private func blend(current: MotivatorState, target: MotivatorState, factor: Double) -> MotivatorState {
        let f = max(0.0, min(1.0, factor))
        return MotivatorState(
            curiosity: current.curiosity + (target.curiosity - current.curiosity) * f,
            helpfulness: current.helpfulness + (target.helpfulness - current.helpfulness) * f,
            caution: current.caution + (target.caution - current.caution) * f
        )
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
