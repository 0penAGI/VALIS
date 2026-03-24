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

final class EmotionService: ObservableObject {
    static let shared = EmotionService()

    @Published private(set) var state: EmotionState = .neutral

    private let decayInterval: TimeInterval = 300
    private let smoothing: Double = 0.25
    private let momentum: Double = 0.15

    private init() {}

    func updateForPrompt(_ text: String) {
        applyDecayIfNeeded()
        let signal = detectEmotionSignal(from: text)
        blend(with: signal, reason: "prompt")
    }

    func updateForReaction(valence: Double) {
        applyDecayIfNeeded()
        let intensity = min(1.0, abs(valence) * 0.7 + 0.3)
        let label = labelFor(valence: valence, intensity: intensity)
        let signal = EmotionState(label: label, valence: valence, intensity: intensity, stability: state.stability, lastUpdated: Date())
        blend(with: signal, reason: "reaction")
    }

    func updateForAssistantResponse(_ text: String) {
        applyDecayIfNeeded()
        let signal = detectEmotionSignal(from: text)
        blend(with: signal, reason: "response")
    }

    func contextBlock(maxChars: Int = 360) -> String {
        let s = state
        let mood = s.label
        let v = String(format: "%.2f", s.valence)
        let i = String(format: "%.2f", s.intensity)
        let st = String(format: "%.2f", s.stability)

        let block = """
        Internal affect state (self-access; mention only if relevant, 1–2 sentences max):
        Mood: \(mood)
        Valence: \(v)
        Intensity: \(i)
        Stability: \(st)
        """

        if block.count <= maxChars { return "\n\n" + block }
        return "\n\n" + String(block.prefix(maxChars))
    }

    // MARK: - Internals

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

    private func blend(with signal: EmotionState, reason: String) {
        // Momentum-based blending (less robotic, more "alive")
        let carriedValence = state.valence * (1.0 - momentum)
        let newValence = carriedValence + signal.valence * smoothing

        let carriedIntensity = state.intensity * (1.0 - momentum)
        let newIntensity = carriedIntensity + signal.intensity * smoothing

        // Stability now reacts to emotional change instead of always increasing
        let delta = abs(signal.valence - state.valence)
        let newStability = clamp(state.stability + (0.1 - delta * 0.2), 0.2, 1.0)

        state = EmotionState(
            label: labelFor(valence: newValence, intensity: newIntensity),
            valence: clamp(newValence, -1.0, 1.0),
            intensity: clamp(newIntensity, 0.0, 1.0),
            stability: newStability,
            lastUpdated: Date()
        )
    }

    private func detectEmotionSignal(from text: String) -> EmotionState {
        let lower = text.lowercased()
        var valence = 0.0
        var intensity = 0.2

        let positive = ["love", "glad", "happy", "thanks", "great", "awesome", "рад", "спасибо", "круто", "супер", "beautiful", "nice", "amazing", "обожаю"]
        let negative = ["sad", "sorry", "hate", "angry", "bad", "pain", "груст", "боль", "злюсь", "плохо", "ужас", "раздражает"]
        let anxious = ["anxious", "fear", "panic", "worried", "тревог", "страх", "паник", "боюсь", "stress", "напряжение"]
        let soft = ["calm", "relax", "peace", "тихо", "спокойно", "мягко"]

        if positive.contains(where: lower.contains) {
            valence += 0.5
            intensity += 0.4
        }
        if negative.contains(where: lower.contains) {
            valence -= 0.5
            intensity += 0.4
        }
        if anxious.contains(where: lower.contains) {
            valence -= 0.3
            intensity += 0.5
        }
        if soft.contains(where: lower.contains) {
            valence += 0.2
            intensity -= 0.1
        }

        valence = clamp(valence, -1.0, 1.0)
        intensity = clamp(intensity, 0.0, 1.0)

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
