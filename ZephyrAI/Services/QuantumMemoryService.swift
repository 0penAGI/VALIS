import Foundation

final class QuantumMemoryService {
    static let shared = QuantumMemoryService()

    private init() {}

    struct Candidate: Sendable {
        let memory: Memory
        let activation: Double
        let score: Double
    }

    struct QuantumTrace: Sendable {
        let candidateIds: [UUID]
        let amplitudesBefore: [Double]
        let amplitudesAfter: [Double]
        let collapsedIds: [UUID]
        let markCount: Int
        let beta: Double
        let diversityStrength: Double
        let cautionBias: Double
    }

    static let enabledKey = "quantum.collapse.enabled"
    static let traceEnabledKey = "quantum.collapse.trace"

    func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func isTraceEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.traceEnabledKey) as? Bool ?? false
    }

    func collapse(
        candidates: [Candidate],
        k: Int,
        motivators: MotivatorState,
        enableTrace: Bool = false
    ) -> (selected: [Candidate], trace: QuantumTrace?) {
        let clampedK = max(1, min(k, candidates.count))
        guard candidates.count > clampedK else {
            return (candidates.sorted { $0.score > $1.score }, nil)
        }

        let sorted = candidates.sorted { $0.score > $1.score }
        let scores = sorted.map { $0.score }

        // Motivation → quantum knobs.
        // curiosity: expands exploration (more marks + stronger diversity)
        // caution: collapses to stable/persistent and reduces exploration
        let curiosity = clamp01(motivators.curiosity)
        let caution = clamp01(motivators.caution)

        let beta = 2.6 + (1.6 * (1.0 - curiosity)) + (0.8 * caution)
        let diversityStrength = 0.28 + (0.34 * curiosity) - (0.12 * caution)
        let cautionBias = 0.25 + (0.65 * caution)

        var probs = softmax(scores: scores, beta: beta)
        if probs.allSatisfy({ $0 == 0 }) {
            probs = Array(repeating: 1.0 / Double(probs.count), count: probs.count)
        }

        // Amplitudes^2 ≈ probability. Start normalized.
        var amplitudes = probs.map { sqrt(max(0.0, $0)) }
        normalize(&amplitudes)
        let amplitudesBefore = amplitudes

        // Grover-like marking: size depends on curiosity/caution.
        let fraction = 0.18 + (0.22 * curiosity) - (0.10 * caution)
        let markCount = max(2, min(10, Int(ceil(Double(sorted.count) * fraction))))
        for i in 0..<amplitudes.count {
            if i < markCount {
                amplitudes[i] *= 1.15 + (0.12 * curiosity)
            } else {
                amplitudes[i] *= 0.98 - (0.06 * caution)
            }
        }

        // Caution bias: prefer pinned/identity memories to stabilize collapse.
        if cautionBias > 0 {
            for i in 0..<sorted.count {
                let m = sorted[i].memory
                if m.isPinned || m.isIdentity {
                    amplitudes[i] *= 1.0 + (0.22 * cautionBias)
                }
            }
        }

        normalize(&amplitudes)

        var remaining = Array(sorted.indices)
        var selectedIndices: [Int] = []

        func weight(for idx: Int) -> Double {
            let a = amplitudes[idx]
            return a * a
        }

        while selectedIndices.count < clampedK, !remaining.isEmpty {
            let bestIdx = remaining.max { weight(for: $0) < weight(for: $1) } ?? remaining[0]
            selectedIndices.append(bestIdx)
            remaining.removeAll { $0 == bestIdx }

            // Interference: penalize near-duplicates (diversity).
            // Stronger when curiosity is high; weaker when caution is high.
            let picked = sorted[bestIdx].memory
            if diversityStrength > 0 {
                for idx in remaining {
                    guard !picked.embedding.isEmpty,
                          !sorted[idx].memory.embedding.isEmpty,
                          picked.embedding.count == sorted[idx].memory.embedding.count else { continue }
                    let sim = cosineSimilarity(a: picked.embedding, b: sorted[idx].memory.embedding)
                    if sim <= 0 { continue }
                    let penalty = max(0.35, 1.0 - (sim * diversityStrength))
                    amplitudes[idx] *= penalty
                }
            }

            normalize(&amplitudes)
        }

        let selected = selectedIndices.map { sorted[$0] }
        let trace: QuantumTrace? = enableTrace
            ? QuantumTrace(
                candidateIds: sorted.map { $0.memory.id },
                amplitudesBefore: amplitudesBefore,
                amplitudesAfter: amplitudes,
                collapsedIds: selected.map { $0.memory.id },
                markCount: markCount,
                beta: beta,
                diversityStrength: diversityStrength,
                cautionBias: cautionBias
            )
            : nil

        return (selected, trace)
    }

    private func softmax(scores: [Double], beta: Double) -> [Double] {
        guard !scores.isEmpty else { return [] }
        let maxScore = scores.max() ?? 0.0
        let exps = scores.map { exp((($0 - maxScore) * beta)) }
        let sum = exps.reduce(0.0, +)
        if sum <= 0 { return Array(repeating: 0.0, count: scores.count) }
        return exps.map { $0 / sum }
    }

    private func normalize(_ vector: inout [Double]) {
        let norm = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        vector = vector.map { $0 / norm }
    }

    private func cosineSimilarity(a: [Double], b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        if na == 0 || nb == 0 { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }
}

