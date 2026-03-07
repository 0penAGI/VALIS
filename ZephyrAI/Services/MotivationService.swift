import Foundation

struct MotivatorState: Codable {
    var curiosity: Double
    var helpfulness: Double
    var caution: Double
    var mood: Double
    var trust: Double
    var energy: Double
}

struct AgentGoal: Codable, Identifiable {
    let id: String
    let title: String
    var weight: Double
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
    @Published private(set) var goals: [AgentGoal] = [
        AgentGoal(id: "understand", title: "Improve understanding", weight: 0.36),
        AgentGoal(id: "uncertainty", title: "Reduce uncertainty", weight: 0.33),
        AgentGoal(id: "evolution", title: "Self evolution", weight: 0.31)
    ]
    @Published private(set) var recentReward: Double = 0.5
    @Published private(set) var mutationStatus: String = "stable"

    private struct MutationCandidate {
        let baseState: MotivatorState
        let baseReward: Double
        let startedAtTurn: Int
    }

    private var activeMutation: MutationCandidate?
    private var totalReward: Double = 0.0
    private var rewardSamples: Int = 0
    private var turnCounter: Int = 0
    private let mutationIntervalTurns: Int = 12
    private let mutationEvaluationWindowTurns: Int = 6
    private let mutationMaxDelta: Double = 0.03
    private let mutationAcceptThreshold: Double = 0.015

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

    func updateForTurnReward(
        userPrompt: String,
        assistantText: String,
        userFeedback: Double?,
        novelty: Double
    ) {
        let curiositySatisfied = estimateCuriositySatisfied(userPrompt: userPrompt, assistantText: assistantText)
        let feedback = userFeedback.map { ($0 + 1.0) / 2.0 } ?? 0.5
        let safeNovelty = clamp(novelty)

        let reward = clamp((curiositySatisfied * 0.4) + (feedback * 0.35) + (safeNovelty * 0.25))
        recentReward = reward

        adjustGoals(curiositySatisfied: curiositySatisfied, feedback: feedback, novelty: safeNovelty)

        let delta = (reward - 0.5) * 0.14
        state.curiosity = clamp(state.curiosity + (safeNovelty - 0.5) * 0.08 + delta * 0.3)
        state.helpfulness = clamp(state.helpfulness + (feedback - 0.5) * 0.10 + delta * 0.4)
        state.caution = clamp(state.caution + ((1.0 - curiositySatisfied) - 0.5) * 0.08 - delta * 0.2)
        state.mood = clamp(state.mood + delta * 0.5)
        state.trust = clamp(state.trust + (feedback - 0.5) * 0.12)
        state.energy = clamp(state.energy + delta * 0.35)

        applyMutationCycle(withReward: reward)
    }

    func contextBlock(maxChars: Int = 280) -> String {
        // Compact state vector: C,H,Z,M,T,E
        var lines: [String] = []

        let stateLine = String(
            format: "M:%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
            state.curiosity,
            state.helpfulness,
            state.caution,
            state.mood,
            state.trust,
            state.energy
        )
        lines.append(stateLine)

        let goalLine = goals
            .sorted { $0.weight > $1.weight }
            .map { "\($0.id)=\(String(format: "%.2f", $0.weight))" }
            .joined(separator: "|")
        if !goalLine.isEmpty {
            lines.append("G:\(goalLine)")
        }
        lines.append("R:\(String(format: "%.2f", recentReward))")

        let block = lines.joined(separator: "\n")
        if block.count <= maxChars {
            return "\n\n" + block
        }
        return "\n\n" + String(block.prefix(maxChars))
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

    private func estimateCuriositySatisfied(userPrompt: String, assistantText: String) -> Double {
        let lowerPrompt = userPrompt.lowercased()
        let asksWhyHow = lowerPrompt.contains("why") || lowerPrompt.contains("how") || lowerPrompt.contains("почему") || lowerPrompt.contains("как")
        let hasStructuredAnswer = assistantText.contains("\n") || assistantText.count > 240
        let notUncertain = !assistantText.lowercased().contains("не знаю") && !assistantText.lowercased().contains("i don't know")

        var score = 0.45
        if asksWhyHow { score += hasStructuredAnswer ? 0.28 : 0.10 }
        if notUncertain { score += 0.18 } else { score -= 0.18 }
        if assistantText.count > 420 { score += 0.08 }
        return clamp(score)
    }

    private func adjustGoals(curiositySatisfied: Double, feedback: Double, novelty: Double) {
        let targets: [String: Double] = [
            "understand": curiositySatisfied,
            "uncertainty": max(0.0, 1.0 - curiositySatisfied),
            "evolution": novelty
        ]
        let step = 0.12
        goals = goals.map { goal in
            let target = targets[goal.id] ?? 0.5
            var next = goal
            next.weight = clamp(goal.weight + (target - goal.weight) * step + (feedback - 0.5) * 0.04)
            return next
        }
        normalizeGoals()
    }

    private func normalizeGoals() {
        let sum = goals.reduce(0.0) { $0 + $1.weight }
        guard sum > 0 else { return }
        goals = goals.map { goal in
            var next = goal
            next.weight = max(0.05, goal.weight / sum)
            return next
        }
        let normalizedSum = goals.reduce(0.0) { $0 + $1.weight }
        guard normalizedSum > 0 else { return }
        goals = goals.map { goal in
            var next = goal
            next.weight = goal.weight / normalizedSum
            return next
        }
    }

    private func applyMutationCycle(withReward reward: Double) {
        turnCounter += 1
        totalReward += reward
        rewardSamples += 1

        if let mutation = activeMutation {
            let elapsed = turnCounter - mutation.startedAtTurn
            if elapsed >= mutationEvaluationWindowTurns {
                let postMean = meanReward()
                let improved = (postMean - mutation.baseReward) >= mutationAcceptThreshold
                if improved {
                    mutationStatus = "mutation accepted (+\(String(format: "%.2f", postMean - mutation.baseReward)))"
                } else {
                    state = mutation.baseState
                    mutationStatus = "mutation reverted (\(String(format: "%.2f", postMean - mutation.baseReward)))"
                }
                activeMutation = nil
            }
            return
        }

        guard turnCounter % mutationIntervalTurns == 0 else { return }
        let base = state
        let baseReward = meanReward()

        state.curiosity = clamp(state.curiosity + randomDelta())
        state.helpfulness = clamp(state.helpfulness + randomDelta())
        state.caution = clamp(state.caution + randomDelta())

        activeMutation = MutationCandidate(
            baseState: base,
            baseReward: baseReward,
            startedAtTurn: turnCounter
        )
        mutationStatus = "mutation trial"
    }

    private func meanReward() -> Double {
        guard rewardSamples > 0 else { return 0.5 }
        return totalReward / Double(rewardSamples)
    }

    private func randomDelta() -> Double {
        Double.random(in: -mutationMaxDelta...mutationMaxDelta)
    }
}
