import Foundation

struct EmotionState: Codable {
    var label: String
    var valence: Double   // -1.0...1.0
    var intensity: Double // 0.0...1.0
    var stability: Double // 0.0...1.0
    var lastUpdated: Date

    static let neutral = EmotionState(
        label: "neutral",
        valence: 0.0,
        intensity: 0.2,
        stability: 0.6,
        lastUpdated: Date()
    )
}

@MainActor
final class EmotionService: ObservableObject {
    static let shared = EmotionService()

    @Published private(set) var state: EmotionState = .neutral
    @Published private(set) var userState: EmotionState = .neutral

    private let decayInterval: TimeInterval = 300
    private let smoothing: Double = 0.25
    private let momentum: Double = 0.35
    private var turnCount: Int = 0
    private var phase: Double = Double.random(in: 0..<(Double.pi * 2))
    private let angularVelocity: Double = 0.11
    private let couplingStrength: Double = 0.14
    private let externalFieldStrength: Double = 0.18

    private init() {}
    private var recentSignals: [Double] = []

    func updateForPrompt(_ text: String) {
        applyDecayIfNeeded()
        turnCount += 1

        let signal = detectEmotionSignal(from: text)
        let contextualSignal = contextualize(signal: signal, from: text, role: .user)

        // Keep a separate view of the user's mood, but also let the self-state
        // lean toward the conversational atmosphere so it can actually move.
        userState = contextualSignal
        blend(with: contextualSignal, weight: 0.42, reason: "prompt")
        applyPhaseCoupling(contextText: text, externalField: MemoryService.shared.fieldStateSnapshot())
    }

    func updateForReaction(valence: Double) {
        applyDecayIfNeeded()
        turnCount += 1
        let intensity = min(1.0, abs(valence) * 0.7 + 0.3)
        let label = labelFor(valence: valence, intensity: intensity)
        let signal = EmotionState(label: label, valence: valence, intensity: intensity, stability: state.stability, lastUpdated: Date())
        blend(with: signal, weight: 1.2, reason: "reaction")
        applyPhaseCoupling(contextText: "reaction:\(valence)", externalField: MemoryService.shared.fieldStateSnapshot())
    }

    func updateForAssistantResponse(_ text: String) {
        applyDecayIfNeeded()
        turnCount += 1
        let signal = detectEmotionSignal(from: text)
        let contextualSignal = contextualize(signal: signal, from: text, role: .assistant)
        blend(with: contextualSignal, weight: 0.78, reason: "response")
        applyPhaseCoupling(contextText: text, externalField: MemoryService.shared.fieldStateSnapshot())
    }

    func contextBlock(maxChars: Int = 360) -> String {
        let s = state
        let u = userState
        let motion: String = {
            let instability = 1.0 - s.stability
            if instability > 0.55 {
                return "spiraling"
            } else if s.intensity > 0.65 {
                return "expanding"
            } else if s.intensity < 0.22 {
                return "settling"
            } else if s.valence >= 0.15 {
                return "opening"
            } else if s.valence <= -0.15 {
                return "contracting"
            } else {
                return "circling"
            }
        }()

        let mood = s.label
        let userMood = u.label

        let v = String(format: "%.2f", s.valence)
        let i = String(format: "%.2f", s.intensity)
        let st = String(format: "%.2f", s.stability)

        let block = """
        Internal affect state:
        Self mood: \(mood)
        User mood: \(userMood)
        Motion: \(motion)
        Valence: \(v)
        Intensity: \(i)
        Stability: \(st)
        """

        if block.count <= maxChars { return "\n\n" + block }
        return "\n\n" + String(block.prefix(maxChars))
    }

    // MARK: - Internals

    private enum AffectiveRole {
        case user
        case assistant
    }

    private func applyDecayIfNeeded() {
        let now = Date()
        let delta = now.timeIntervalSince(state.lastUpdated)
        guard delta > decayInterval else { return }

        // Ease toward neutral over time.
        let decay = min(1.0, delta / (decayInterval * 3))
        let newValence = state.valence * (1.0 - decay)
        let newIntensity = max(0.15, state.intensity * (1.0 - decay * 0.8))
        let newStability = min(0.9, state.stability + decay * 0.1)

        state = EmotionState(
            label: labelFor(valence: newValence, intensity: newIntensity),
            valence: newValence,
            intensity: newIntensity,
            stability: newStability,
            lastUpdated: now
        )
    }

    private func contextualize(signal: EmotionState, from text: String, role: AffectiveRole) -> EmotionState {
        let structural = structuralSignal(from: text, role: role, base: signal)
        let trend = recentSignals.isEmpty ? 0.0 : recentSignals.suffix(4).reduce(0.0, +) / Double(min(4, recentSignals.count))
        let turnPhase = sin(Double(turnCount) * 0.37) * 0.025
        let roleBias: Double = {
            switch role {
            case .user:
                return text.contains("?") ? 0.05 : 0.0
            case .assistant:
                return text.count > 220 ? 0.04 : -0.02
            }
        }()

        let valence = clamp(signal.valence + structural.valenceShift + trend * 0.12 + roleBias + turnPhase, -1.0, 1.0)
        let intensity = clamp(signal.intensity + structural.intensityShift, 0.0, 1.0)
        let stability = clamp(signal.stability + structural.stabilityShift, 0.0, 1.0)

        return EmotionState(
            label: labelFor(valence: valence, intensity: intensity),
            valence: valence,
            intensity: intensity,
            stability: stability,
            lastUpdated: signal.lastUpdated
        )
    }

    private func structuralSignal(from text: String, role: AffectiveRole, base: EmotionState) -> (valenceShift: Double, intensityShift: Double, stabilityShift: Double) {
        let characters = text.unicodeScalars
        let letters = characters.filter { CharacterSet.letters.contains($0) }
        let uppercaseLetters = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        let wordCount = text
            .split { !$0.isLetter }
            .count

        let exclamationCount = text.filter { $0 == "!" }.count
        let questionCount = text.filter { $0 == "?" }.count
        let uppercaseRatio = letters.isEmpty ? 0.0 : Double(uppercaseLetters.count) / Double(letters.count)
        let brevity = wordCount <= 4 ? 1.0 : 0.0
        let verbosity = wordCount >= 45 ? 1.0 : 0.0

        var valenceShift = 0.0
        var intensityShift = 0.0
        var stabilityShift = 0.0

        if questionCount > 0 {
            valenceShift += role == .user ? 0.04 : 0.02
            intensityShift += min(0.10, Double(questionCount) * 0.02)
            stabilityShift -= 0.02
        }

        if exclamationCount > 0 {
            let emphasis = min(0.16, Double(exclamationCount) * 0.03)
            intensityShift += emphasis
            valenceShift += base.valence >= 0 ? emphasis * 0.4 : -emphasis * 0.3
            stabilityShift -= emphasis * 0.15
        }

        if uppercaseRatio > 0.25 {
            let stress = min(0.22, uppercaseRatio * 0.5)
            valenceShift -= stress
            intensityShift += stress * 0.8
            stabilityShift -= stress * 0.25
        }

        if brevity > 0 {
            intensityShift -= 0.03
            stabilityShift += 0.01
        }

        if verbosity > 0 {
            intensityShift += 0.03
            stabilityShift += 0.02
            if role == .assistant {
                valenceShift += 0.02
            }
        }

        return (valenceShift, intensityShift, stabilityShift)
    }

    private func blend(with signal: EmotionState, weight: Double, reason: String) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(state.lastUpdated)
        let timeFactor = min(1.5, max(0.5, timeDelta / 10))

        let carriedValence = state.valence * (1.0 - momentum)
        let carriedIntensity = state.intensity * (1.0 - momentum)

        recentSignals.append(signal.valence)
        if recentSignals.count > 5 { recentSignals.removeFirst() }

        let trend = recentSignals.reduce(0, +) / Double(recentSignals.count)

        let trendInfluence = trend * 0.2
        let newValence = carriedValence + (signal.valence * weight + trendInfluence) * smoothing * timeFactor
        let dampenedIntensity = signal.intensity * weight * (0.8 + state.stability * 0.2)
        let newIntensity = carriedIntensity + dampenedIntensity * smoothing * timeFactor

        let delta = abs(signal.valence - state.valence)
        let volatility = delta * signal.intensity
        let newStability = clamp(
            state.stability + (0.05 - volatility * 0.3),
            0.2,
            1.0
        )

        state = EmotionState(
            label: labelFor(valence: newValence, intensity: newIntensity),
            valence: clamp(newValence, -1.0, 1.0),
            intensity: clamp(newIntensity, 0.0, 1.0),
            stability: newStability,
            lastUpdated: now
        )
    }

    private func applyPhaseCoupling(contextText: String, externalField: FieldStateSnapshot) {
        let externalPhi = atan2(externalField.avgIntensity - 0.5, externalField.avgValence - 0.5)
        let fieldStrength = clamp(externalField.activationLevel, 0.0, 1.0)
        let textBias = phaseDrive(from: contextText)
        let selfPhi = atan2(state.intensity - 0.5, state.valence)

        let pull = sin(selfPhi - phase)
        phase = normalizeAngle(
            phase
            + angularVelocity
            + couplingStrength * pull
            + externalFieldStrength * fieldStrength * sin(selfPhi - externalPhi)
            + textBias
        )

        let alignment = 0.5 + 0.5 * cos(phase - externalPhi)
        state.valence = clamp(state.valence + (alignment - 0.5) * 0.05 + textBias * 0.4, -1.0, 1.0)
        state.intensity = clamp(state.intensity + abs(textBias) * 0.04 + (fieldStrength - 0.5) * 0.02, 0.0, 1.0)
        state.stability = clamp(state.stability + (alignment - 0.5) * 0.06 - abs(textBias) * 0.02, 0.0, 1.0)
        state.label = labelFor(valence: state.valence, intensity: state.intensity)
    }

    private func phaseDrive(from text: String) -> Double {
        let lower = text.lowercased()
        var drive = 0.0
        if lower.contains("?") { drive += 0.03 }
        if lower.contains("!") { drive += 0.04 }
        if lower.contains("sorry") || lower.contains("извини") { drive -= 0.03 }
        if lower.contains("thanks") || lower.contains("спасибо") { drive += 0.02 }
        return max(-0.08, min(0.08, drive))
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        let tau = Double.pi * 2
        var value = angle.truncatingRemainder(dividingBy: tau)
        if value < 0 { value += tau }
        return value
    }

    private func score(_ text: String, words: [String: Double]) -> Double {
        var total = 0.0
        let tokens = text
            .split { !$0.isLetter }
            .map { String($0) }

        for token in tokens {
            for (word, weight) in words {
                if token == word || token.hasPrefix(word) {
                    total += weight
                }
            }
        }

        return total
    }

    private func detectEmotionSignal(from text: String) -> EmotionState {
        let lower = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        let tokens = lower
            .split { !$0.isLetter }
            .map { String($0) }
        var valence = 0.0
        var intensity = 0.2

        // Negation handling (e.g. "not happy", "не люблю")
        let negations = ["not", "no", "never", "не", "нет"]
        var negationActive = false
        var negatedScore = 0.0

        let positive: [String: Double] = [
            "love": 0.7, "amazing": 0.6, "great": 0.5,
            "thanks": 0.3, "спасибо": 0.3, "круто": 0.5, "обожаю": 0.7
        ]

        let negative: [String: Double] = [
            "hate": 0.7, "bad": 0.4, "боль": 0.6,
            "ужас": 0.6, "плохо": 0.5
        ]

        let anxious: [String: Double] = [
            "anxious": 0.6, "panic": 0.7, "worried": 0.5,
            "тревог": 0.6, "страх": 0.7, "паник": 0.7
        ]

        let soft: [String: Double] = [
            "calm": 0.4, "relax": 0.4, "peace": 0.4,
            "спокойно": 0.4, "мягко": 0.3
        ]

        for i in 0..<tokens.count {
            let token = tokens[i]

            if negations.contains(token) {
                negationActive = true
                continue
            }

            if negationActive {
                if let weight = positive[token] {
                    negatedScore -= weight
                    negationActive = false
                    continue
                }
                if let weight = negative[token] {
                    negatedScore += weight * 0.5
                    negationActive = false
                    continue
                }
                negationActive = false
            }
        }

        valence += score(lower, words: positive)
        valence -= score(lower, words: negative)
        valence -= score(lower, words: anxious) * 0.5
        valence += score(lower, words: soft) * 0.3

        // Structural features make the state move even when no keyword matches.
        let structural = structuralSignal(from: text, role: .assistant, base: EmotionState.neutral)
        valence += structural.valenceShift
        intensity += structural.intensityShift

        // Apply negation effect
        valence += negatedScore

        valence = clamp(valence, -1.0, 1.0)

        // Prevent extreme stacking from repeated keywords
        if abs(valence) > 0.8 {
            valence *= 0.9
        }

        let magnitude = abs(valence)
        intensity += magnitude * 0.6
        intensity *= 0.9
        intensity = clamp(intensity, 0.0, 1.0)

        // Phrase amplification ("very", "slightly", etc.)
        let amplifiers: [String: Double] = [
            "very": 1.2, "extremely": 1.4, "slightly": 0.7,
            "очень": 1.3, "слегка": 0.7
        ]

        var amplification: Double = 1.0
        for i in 0..<tokens.count {
            let token = tokens[i]
            if let factor = amplifiers[token], i + 1 < tokens.count {
                let next = tokens[i + 1]
                if positive[next] != nil || negative[next] != nil {
                    amplification *= factor
                }
            }
        }

        intensity = clamp(intensity * amplification, 0.0, 1.0)

        return EmotionState(
            label: labelFor(valence: valence, intensity: intensity),
            valence: valence,
            intensity: intensity,
            stability: state.stability,
            lastUpdated: Date()
        )
    }

    private func labelFor(valence: Double, intensity: Double) -> String {
        if intensity < 0.2 { return "neutral" }
        if valence > 0.2 && intensity > 0.5 { return "excited" }
        if valence < -0.2 && intensity > 0.5 { return "agitated" }

        if valence >= 0.6 { return "joy" }
        if valence >= 0.3 { return "warm" }

        if valence <= -0.6 { return "distress" }
        if valence <= -0.3 { return "sad" }

        if intensity > 0.6 && valence < 0 { return "anxious" }

        if intensity < 0.4 { return "calm" }

        return "tense"
    }

    private func clamp(_ v: Double, _ min: Double, _ max: Double) -> Double {
        Swift.max(min, Swift.min(max, v))
    }
}
