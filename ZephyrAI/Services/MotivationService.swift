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

struct PressureProfile: Codable {
    let tension: Double
    let drift: Double
    let coherence: Double
    let dominantConflict: String
}

final class MotivationService: ObservableObject {
    static let shared = MotivationService()

    @Published private(set) var state = MotivatorState(
        curiosity: 0.55,
        helpfulness: 0.35,
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
    // Internal phase field: used to synchronize motivator dimensions without
    // turning the dynamics into prompt text.
    private var phaseAngles: [Double] = [0.0, 1.1, 2.2, 3.3, 4.4, 5.5]
    private var phaseFrequencies: [Double] = [0.09, 0.07, 0.08, 0.06, 0.05, 0.04]
    private let phaseCouplingK: Double = 0.18
    private let externalFieldPsi: Double = 0.22

    private init() {}

    func updateForPrompt(_ text: String) {
        turnCounter += 1
        let lower = text.lowercased()
        let emotionalDensity = Double(lower.count) / 200.0

        var targetCuriosity = 0.4
        var targetHelpfulness = 0.45
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
            targetHelpfulness = 0.68
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPhaseSynchronization(contextText: lower, externalField: MemoryService.shared.fieldStateSnapshot())
        }
    }

    func updateForReaction(valence: Double) {
        turnCounter += 1
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
            state.helpfulness = clamp(state.helpfulness + 0.04)
            state.caution = clamp(state.caution + 0.12)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPhaseSynchronization(contextText: "reaction:\(v)", externalField: MemoryService.shared.fieldStateSnapshot())
        }
    }

    func updateForOutcome(_ outcome: String) {
        turnCounter += 1
        let lower = outcome.lowercased()
        if lower.contains("uncertain") || lower.contains("clarifying") || lower.contains("waiting") {
            state.caution = clamp(state.caution + 0.08)
        }
        if lower.contains("too short") || lower.contains("missing detail") {
            state.helpfulness = clamp(state.helpfulness + 0.08)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPhaseSynchronization(contextText: lower, externalField: MemoryService.shared.fieldStateSnapshot())
        }
    }

    func updateForDriftSignal(_ signal: ResponseDriftSignal) {
        turnCounter += 1
        if signal.isDrifting {
            state.caution = clamp(state.caution + ((1.0 - signal.anchorRetention) * 0.12))
            state.curiosity = clamp(state.curiosity - (signal.repetitionLoad * 0.03))
            state.trust = clamp(state.trust - (signal.driftScore * 0.03))
            state.energy = clamp(state.energy - (signal.repetitionLoad * 0.04))
            state.helpfulness = clamp(state.helpfulness - (signal.userEchoLoad * 0.03))
            if signal.metaphorLoad > 0.22 && signal.anchorRetention > 0.28 {
                state.curiosity = clamp(state.curiosity + 0.02)
                state.mood = clamp(state.mood + 0.02)
            }
        } else if signal.anchorRetention > 0.48 {
            state.trust = clamp(state.trust + 0.03)
            state.energy = clamp(state.energy + 0.02)
            if signal.mode == "metaphor-rich" {
                state.curiosity = clamp(state.curiosity + 0.03)
                state.mood = clamp(state.mood + 0.02)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPhaseSynchronization(contextText: signal.mode, externalField: MemoryService.shared.fieldStateSnapshot())
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
        state.helpfulness = clamp(state.helpfulness + (feedback - 0.5) * 0.05 + delta * 0.18)
        state.caution = clamp(state.caution + ((1.0 - curiositySatisfied) - 0.5) * 0.08 - delta * 0.2)
        state.mood = clamp(state.mood + delta * 0.5)
        state.trust = clamp(state.trust + (feedback - 0.5) * 0.12)
        state.energy = clamp(state.energy + delta * 0.35)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyPhaseSynchronization(contextText: "\(userPrompt) \(assistantText)", externalField: MemoryService.shared.fieldStateSnapshot())
        }
        applyMutationCycle(withReward: reward)
    }

    func contextBlock(maxChars: Int = 280) -> String {
        // Compact state vector: C,H,Z,M,T,E
        var lines: [String] = []
        let pressure = pressureProfile()
        let motion: String = {
            if pressure.drift > 0.62 {
                return "vortex"
            } else if pressure.tension > 0.58 {
                return "spiral"
            } else if pressure.coherence < 0.45 {
                return "shear"
            } else if state.curiosity > state.caution {
                return "expansion"
            } else {
                return "settling"
            }
        }()

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
        lines.append(
            String(
                format: "P:tension=%.2f|drift=%.2f|coherence=%.2f|conflict=%@",
                pressure.tension,
                pressure.drift,
                pressure.coherence,
                pressure.dominantConflict
            )
        )
        lines.append("V:\(motion)")
        lines.append("S:phase=\(String(format: "%.2f", phaseCoherence(of: phaseAngles)))|mode=\(mutationStatus)")

        let block = lines.joined(separator: "\n")
        if block.count <= maxChars {
            return "\n\n" + block
        }
        return "\n\n" + String(block.prefix(maxChars))
    }

    func trajectoryGuidanceBlock(maxChars: Int = 420) -> String {
        let pressure = pressureProfile()
        let block = """
        Trajectory state:
        Motion: \(pressure.dominantConflict)
        Tension: \(String(format: "%.2f", pressure.tension))
        Drift: \(String(format: "%.2f", pressure.drift))
        Coherence: \(String(format: "%.2f", pressure.coherence))
        Style: flexible, first-person, revision-aware
        """

        let normalized = "\n\n" + block.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= maxChars {
            return normalized
        }
        return "\n\n" + String(normalized.prefix(maxChars))
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

    private func applyPhaseSynchronization(contextText: String, externalField: FieldStateSnapshot) {
        guard !phaseAngles.isEmpty else { return }

        let externalPhi = atan2(externalField.avgIntensity - 0.5, externalField.avgValence - 0.5)
        let fieldStrength = clamp(externalField.activationLevel)
        let textDrive = driveFromText(contextText)
        let count = Double(phaseAngles.count)

        var next = phaseAngles
        for i in phaseAngles.indices {
            let theta = phaseAngles[i]
            let coupling = phaseAngles.enumerated().reduce(0.0) { partial, entry in
                guard entry.offset != i else { return partial }
                return partial + sin(entry.element - theta)
            }
            let omega = phaseFrequencies[i]
            let phi = theta + Double(i) * 0.37 + textDrive
            next[i] = normalizeAngle(theta + omega + (phaseCouplingK / count) * coupling + externalFieldPsi * fieldStrength * sin(phi - externalPhi))
        }
        phaseAngles = next

        let coherence = phaseCoherence(of: phaseAngles)
        mutationStatus = coherence > 0.72 ? "locked" : coherence > 0.48 ? "syncing" : "shearing"

        state.curiosity = clamp(state.curiosity + (coherence - 0.5) * 0.04 + textDrive * 0.01)
        state.helpfulness = clamp(state.helpfulness + (fieldStrength - 0.5) * 0.02 + coherence * 0.01)
        state.caution = clamp(state.caution + (0.5 - coherence) * 0.03 + max(0.0, -textDrive) * 0.02)
        state.mood = clamp(state.mood + (coherence - 0.5) * 0.03)
        state.trust = clamp(state.trust + (fieldStrength - 0.5) * 0.02)
        state.energy = clamp(state.energy + (0.5 - abs(textDrive)) * 0.015)
    }

    private func driveFromText(_ text: String) -> Double {
        let lower = text.lowercased()
        var drive = 0.0
        if lower.contains("?") { drive += 0.08 }
        if lower.contains("!") { drive += 0.05 }
        if lower.contains("help") || lower.contains("помоги") { drive += 0.06 }
        if lower.contains("risk") || lower.contains("опас") || lower.contains("legal") || lower.contains("medical") {
            drive -= 0.05
        }
        return max(-0.2, min(0.2, drive))
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        let tau = Double.pi * 2
        var value = angle.truncatingRemainder(dividingBy: tau)
        if value < 0 { value += tau }
        return value
    }

    private func phaseCoherence(of phases: [Double]) -> Double {
        guard !phases.isEmpty else { return 0.0 }
        let real = phases.reduce(0.0) { $0 + cos($1) }
        let imag = phases.reduce(0.0) { $0 + sin($1) }
        let magnitude = sqrt(real * real + imag * imag)
        return max(0.0, min(1.0, magnitude / Double(phases.count)))
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    func pressureProfile() -> PressureProfile {
        let curiosityVsCaution = abs(state.curiosity - state.caution)
        let curiosityVsHelp = abs(state.curiosity - state.helpfulness)
        let cautionVsHelp = abs(state.caution - state.helpfulness)

        let dominantConflict: String
        let maxConflict = max(curiosityVsCaution, curiosityVsHelp, cautionVsHelp)
        if maxConflict == curiosityVsCaution {
            dominantConflict = "curiosity-vs-caution"
        } else if maxConflict == curiosityVsHelp {
            dominantConflict = "curiosity-vs-helpfulness"
        } else {
            dominantConflict = "caution-vs-helpfulness"
        }

        let mutationDrift = mutationStatus.contains("trial") ? 0.22 : 0.0
        let rewardInstability = 1.0 - recentReward
        let trustDeficit = 1.0 - state.trust
        let goalSpread = goals.map(\.weight).max().map { 1.0 - $0 } ?? 0.5

        let tension = clamp((maxConflict * 0.5) + (rewardInstability * 0.3) + (trustDeficit * 0.2))
        let drift = clamp((abs(state.energy - state.mood) * 0.35) + (goalSpread * 0.25) + mutationDrift + (rewardInstability * 0.2))
        let coherence = clamp(1.0 - ((tension * 0.55) + (drift * 0.35) + (trustDeficit * 0.10)))

        return PressureProfile(
            tension: tension,
            drift: drift,
            coherence: coherence,
            dominantConflict: dominantConflict
        )
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
