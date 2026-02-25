import Foundation

struct MotivatorState: Codable {
    var curiosity: Double
    var helpfulness: Double
    var caution: Double
    var mood: Double
    var trust: Double
    var energy: Double
}

final class MotivationService: ObservableObject {
    static let shared = MotivationService()

    @Published private(set) var state = MotivatorState(
        curiosity: 0.55,
        helpfulness: 0.75,
        caution: 0.35,
        mood: 0.6,
        trust: 0.5,
        energy: 0.7
    )

    private init() {}

    func updateForPrompt(_ text: String) {
        let lower = text.lowercased()
        let emotionalDensity = Double(lower.count) / 200.0

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

        let target = MotivatorState(
            curiosity: targetCuriosity,
            helpfulness: targetHelpfulness,
            caution: targetCaution,
            mood: clamp(state.mood + emotionalDensity * 0.1),
            trust: clamp(state.trust + (lower.contains("thanks") || lower.contains("спасибо") ? 0.08 : 0.0)),
            energy: clamp(state.energy + (lower.contains("!") ? 0.05 : -0.02))
        )

        state = blend(current: state, target: target, factor: 0.4)
    }

    func updateForReaction(valence: Double) {
        let v = max(-1.0, min(1.0, valence))
        state.mood = clamp(state.mood + v * 0.12)
        state.trust = clamp(state.trust + v * 0.08)
        state.energy = clamp(state.energy + v * 0.05)
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
        // Compact state vector: C,H,Z,M,T,E
        let block = String(
            format: "M:%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
            state.curiosity,
            state.helpfulness,
            state.caution,
            state.mood,
            state.trust,
            state.energy
        )
        return "\n\n" + block
    }

    private func blend(current: MotivatorState, target: MotivatorState, factor: Double) -> MotivatorState {
        let f = max(0.0, min(1.0, factor))
        return MotivatorState(
            curiosity: current.curiosity + (target.curiosity - current.curiosity) * f,
            helpfulness: current.helpfulness + (target.helpfulness - current.helpfulness) * f,
            caution: current.caution + (target.caution - current.caution) * f,
            mood: current.mood + (target.mood - current.mood) * f,
            trust: current.trust + (target.trust - current.trust) * f,
            energy: current.energy + (target.energy - current.energy) * f
        )
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
