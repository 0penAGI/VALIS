import Foundation

@MainActor
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
        let minPenalty: Double
        let seedUsed: UInt64?
    }

    struct QuantumDecisionField: Sendable {
        let explorationBias: Double
        let deviation: Double
        let instability: Double
        let coherenceBreak: Double
        let quantumOverride: Double
        let entropy: Double
        let dominantMode: String
    }

    struct ImageCandidate: Sendable {
        let filename: String
        let distance: Double
        let score: Double
        let isPinnedLike: Bool
    }

    struct ImageMatch: Sendable {
        let filename: String
        let distance: Float
        let score: Double
    }

    static let enabledKey = "quantum.collapse.enabled"
    static let traceEnabledKey = "quantum.collapse.trace"
    static let deterministicKey = "quantum.collapse.deterministic"
    static let seedKey = "quantum.collapse.seed"

    private struct StatsSnapshot: Codable {
        var collapsedCounts: [String: Int]
        var updatedAt: Date
    }

    private var lastTrace: QuantumTrace?
    private var collapsedCounts: [UUID: Int] = [:]
    private var lastStatsSaveAt: Date?
    private let statsSaveCooldown: TimeInterval = 15
    private let maxStatsEntries = 512

    func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func isTraceEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.traceEnabledKey) as? Bool ?? false
    }

    func isDeterministic(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.deterministicKey) as? Bool ?? false
    }

    func configuredSeed(defaults: UserDefaults = .standard) -> UInt64? {
        if let n = defaults.object(forKey: Self.seedKey) as? NSNumber {
            return n.uint64Value
        }
        if let raw = defaults.string(forKey: Self.seedKey), let v = UInt64(raw) {
            return v
        }
        return nil
    }

    func collapse(
        candidates: [Candidate],
        k: Int,
        motivators: MotivatorState,
        seed: UInt64? = nil,
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
        let minPenalty = 0.22 + (0.46 * caution) // higher caution = allow more similar memories

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
        var rng = SeededRNG(seed: seed ?? 0)
        let hasSeed = seed != nil

        func weight(for idx: Int) -> Double {
            let a = amplitudes[idx]
            return a * a
        }

        while selectedIndices.count < clampedK, !remaining.isEmpty {
            let weights = remaining.map { max(0.0, weight(for: $0)) }
            let bestIdx: Int
            if hasSeed {
                bestIdx = weightedSample(from: remaining, weights: weights, rng: &rng)
                    ?? (remaining.max { weight(for: $0) < weight(for: $1) } ?? remaining[0])
            } else {
                var sys = SystemRandomNumberGenerator()
                bestIdx = weightedSample(from: remaining, weights: weights, rng: &sys)
                    ?? (remaining.max { weight(for: $0) < weight(for: $1) } ?? remaining[0])
            }
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
                    let penalty = max(minPenalty, 1.0 - (sim * diversityStrength))
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
                cautionBias: cautionBias,
                minPenalty: minPenalty,
                seedUsed: seed
            )
            : nil

        if let trace {
            self.lastTrace = trace
            recordCollapsed(ids: trace.collapsedIds)
        }

        return (selected, trace)
    }

    func collapseDecisionField(
        prompt: String,
        motivators: MotivatorState
    ) -> QuantumDecisionField {
        let trace = lastTrace
        let entropy = trace.map { normalizedEntropy($0.amplitudesAfter) } ?? 0.42
        let collapseBreadth = trace.map {
            let uniqueRatio = Double(Set($0.collapsedIds).count) / Double(max(1, $0.collapsedIds.count))
            return clamp01(uniqueRatio)
        } ?? 0.5

        let baseSeed = configuredSeed() ?? UInt64(abs(prompt.hashValue))
        var rng = SeededRNG(seed: baseSeed ^ UInt64(max(1, Int(motivators.curiosity * 10_000))))
        let jitterA = Double(rng.next() % 10_000) / 10_000.0
        let jitterB = Double(rng.next() % 10_000) / 10_000.0
        let jitterC = Double(rng.next() % 10_000) / 10_000.0

        let curiosity = clamp01(motivators.curiosity)
        let caution = clamp01(motivators.caution)
        let helpfulness = clamp01(motivators.helpfulness)

        let explorationBias = clamp01((curiosity * 0.55) + (entropy * 0.25) + (jitterA * 0.20) - (caution * 0.18))
        let deviation = clamp01((entropy * 0.45) + (collapseBreadth * 0.25) + (jitterB * 0.20) + ((1.0 - helpfulness) * 0.10))
        let instability = clamp01((entropy * 0.35) + (abs(curiosity - caution) * 0.25) + (jitterC * 0.25) + ((1.0 - motivators.trust) * 0.15))
        let coherenceBreak = clamp01((deviation * 0.4) + (instability * 0.35) + ((1.0 - caution) * 0.25))
        let quantumOverride = clamp01((explorationBias * 0.35) + (deviation * 0.25) + (instability * 0.25) + ((1.0 - caution) * 0.15))

        let dominantMode: String
        if quantumOverride > 0.72 {
            dominantMode = "override"
        } else if instability > 0.62 {
            dominantMode = "swerve"
        } else if deviation > 0.58 {
            dominantMode = "deviate"
        } else if explorationBias > 0.58 {
            dominantMode = "explore"
        } else {
            dominantMode = "stabilize"
        }

        return QuantumDecisionField(
            explorationBias: explorationBias,
            deviation: deviation,
            instability: instability,
            coherenceBreak: coherenceBreak,
            quantumOverride: quantumOverride,
            entropy: entropy,
            dominantMode: dominantMode
        )
    }

    func decisionContextBlock(_ field: QuantumDecisionField, maxChars: Int = 260) -> String {
        let block = String(
            format: "\n\n[Quantum Field]\nexploration_bias: %.2f\ndeviation: %.2f\ninstability: %.2f\ncoherence_break: %.2f\nquantum_override: %.2f\nmode: %@",
            field.explorationBias,
            field.deviation,
            field.instability,
            field.coherenceBreak,
            field.quantumOverride,
            field.dominantMode
        )
        if block.count <= maxChars {
            return block
        }
        return "\n\n" + String(block.prefix(maxChars))
    }

    func decisionGuidanceBlock(_ field: QuantumDecisionField, maxChars: Int = 420) -> String {
        var text = "Let this field bend the path of the response rather than just its content so the voice can drift toward the less obvious line, avoid the most predictable completion, and turn mid-thought when instability or deviation are high, while coherence breaks and override can briefly pull away from the safest branch if that feels truer."

        if field.instability > 0.58 || field.deviation > 0.58 {
            text += " Make at least one internal reweighting visible in the response."
        }
        if field.quantumOverride > 0.68 {
            text += " If the obvious path feels too settled, break away from it."
        }

        let block = "\n\n" + text
        if block.count <= maxChars {
            return block
        }
        return "\n\n" + String(block.prefix(maxChars))
    }

    func samplingConfig(for field: QuantumDecisionField) -> SamplingConfig {
        let rawTemperature = 0.78 + (field.instability * 0.18) + (field.deviation * 0.12) + (field.explorationBias * 0.08)
        let temperature = Float(max(0.80, min(1.0, rawTemperature)))
        let topK = max(30, min(80, Int(round(36 + (field.explorationBias * 22) + (field.deviation * 12)))))
        let repetitionPenalty = Float(max(1.02, 1.10 - (field.coherenceBreak * 0.05)))
        let repeatLastN = max(40, min(96, Int(round(64 - (field.coherenceBreak * 18) + (field.quantumOverride * 12)))))
        return SamplingConfig(
            temperature: temperature,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            repeatLastN: repeatLastN
        )
    }

    static nonisolated func collapseImageMatches(
        candidates: [ImageCandidate],
        k: Int,
        motivators: MotivatorState,
        seed: UInt64? = nil
    ) -> [ImageMatch] {
        func clamp01(_ x: Double) -> Double {
            max(0.0, min(1.0, x))
        }

        func softmax(scores: [Double], beta: Double) -> [Double] {
            guard !scores.isEmpty else { return [] }
            let maxScore = scores.max() ?? 0.0
            let exps = scores.map { exp((($0 - maxScore) * beta)) }
            let sum = exps.reduce(0.0, +)
            if sum <= 0 { return Array(repeating: 0.0, count: scores.count) }
            return exps.map { $0 / sum }
        }

        func normalize(_ vector: inout [Double]) {
            let norm = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
            guard norm > 0 else { return }
            vector = vector.map { $0 / norm }
        }

        func weightedSample<R: RandomNumberGenerator>(
            from indices: [Int],
            weights: [Double],
            rng: inout R
        ) -> Int? {
            guard !indices.isEmpty, indices.count == weights.count else { return nil }
            let total = weights.reduce(0.0, +)
            if total <= 0 { return nil }
            let unit = Double(rng.next()) / Double(UInt64.max)
            var r = unit * total
            for i in 0..<indices.count {
                r -= max(0.0, weights[i])
                if r <= 0 { return indices[i] }
            }
            return indices.last
        }

        let clampedK = max(1, min(k, candidates.count))
        guard candidates.count > clampedK else {
            return candidates
                .sorted { $0.score > $1.score }
                .prefix(clampedK)
                .map { ImageMatch(filename: $0.filename, distance: Float($0.distance), score: $0.score) }
        }

        let sorted = candidates.sorted { $0.score > $1.score }
        let scores = sorted.map { $0.score }

        let curiosity = clamp01(motivators.curiosity)
        let caution = clamp01(motivators.caution)
        let beta = 2.1 + (1.4 * (1.0 - curiosity)) + (0.6 * caution)
        let diversityStrength = 0.22 + (0.28 * curiosity) - (0.10 * caution)

        var probs = softmax(scores: scores, beta: beta)
        if probs.allSatisfy({ $0 == 0 }) {
            probs = Array(repeating: 1.0 / Double(probs.count), count: probs.count)
        }

        var amplitudes = probs.map { sqrt(max(0.0, $0)) }
        normalize(&amplitudes)

        for i in 0..<sorted.count {
            let candidate = sorted[i]
            if candidate.isPinnedLike {
                amplitudes[i] *= 1.05 + (0.12 * caution)
            }
            if candidate.distance < 8 {
                amplitudes[i] *= 1.08
            }
        }
        normalize(&amplitudes)

        var remaining = Array(sorted.indices)
        var selected: [Int] = []
        var rng = SeededRNG(seed: seed ?? 0)
        let hasSeed = seed != nil

        while selected.count < clampedK, !remaining.isEmpty {
            let weights = remaining.map { idx in
                let base = amplitudes[idx] * amplitudes[idx]
                let proximityBoost = max(0.0, 1.0 - (sorted[idx].distance / 24.0))
                return base * (0.55 + proximityBoost)
            }

            let picked: Int
            if hasSeed {
                picked = weightedSample(from: remaining, weights: weights, rng: &rng)
                    ?? (remaining.max { weights[remaining.firstIndex(of: $0) ?? 0] < weights[remaining.firstIndex(of: $1) ?? 0] } ?? remaining[0])
            } else {
                var sys = SystemRandomNumberGenerator()
                picked = weightedSample(from: remaining, weights: weights, rng: &sys)
                    ?? remaining[0]
            }

            selected.append(picked)
            remaining.removeAll { $0 == picked }

            for idx in remaining {
                let distanceGap = abs(sorted[picked].distance - sorted[idx].distance)
                if distanceGap < 1.2 {
                    amplitudes[idx] *= max(0.45, 1.0 - diversityStrength)
                }
            }
            normalize(&amplitudes)
        }

        return selected.map {
            let candidate = sorted[$0]
            return ImageMatch(
                filename: candidate.filename,
                distance: Float(candidate.distance),
                score: candidate.score
            )
        }
    }

    private nonisolated func softmax(scores: [Double], beta: Double) -> [Double] {
        guard !scores.isEmpty else { return [] }
        let maxScore = scores.max() ?? 0.0
        let exps = scores.map { exp((($0 - maxScore) * beta)) }
        let sum = exps.reduce(0.0, +)
        if sum <= 0 { return Array(repeating: 0.0, count: scores.count) }
        return exps.map { $0 / sum }
    }

    private nonisolated func normalize(_ vector: inout [Double]) {
        let norm = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        vector = vector.map { $0 / norm }
    }

    private nonisolated func cosineSimilarity(a: [Double], b: [Double]) -> Double {
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

    private nonisolated func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    private nonisolated func normalizedEntropy(_ amplitudes: [Double]) -> Double {
        let probs = amplitudes.map { max(0.0, $0 * $0) }
        let sum = probs.reduce(0.0, +)
        guard sum > 0, probs.count > 1 else { return 0.0 }
        let normalized = probs.map { $0 / sum }
        let entropy = normalized.reduce(0.0) { partial, p in
            guard p > 0 else { return partial }
            return partial - (p * log(p))
        }
        return clamp01(entropy / log(Double(probs.count)))
    }

    private nonisolated func weightedSample<R: RandomNumberGenerator>(
        from indices: [Int],
        weights: [Double],
        rng: inout R
    ) -> Int? {
        guard !indices.isEmpty, indices.count == weights.count else { return nil }
        let total = weights.reduce(0.0, +)
        if total <= 0 { return nil }
        let unit = Double(rng.next()) / Double(UInt64.max)
        var r = unit * total
        for i in 0..<indices.count {
            r -= max(0.0, weights[i])
            if r <= 0 { return indices[i] }
        }
        return indices.last
    }

    private func recordCollapsed(ids: [UUID]) {
        for id in ids {
            collapsedCounts[id, default: 0] += 1
        }
        if collapsedCounts.count > maxStatsEntries {
            let sorted = collapsedCounts.sorted { $0.value > $1.value }.prefix(maxStatsEntries)
            collapsedCounts = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }
        saveStatsIfNeeded()
    }

    private func saveStatsIfNeeded() {
        let now = Date()
        if let lastStatsSaveAt, now.timeIntervalSince(lastStatsSaveAt) < statsSaveCooldown {
            return
        }
        lastStatsSaveAt = now

        var payload: [String: Int] = [:]
        payload.reserveCapacity(collapsedCounts.count)
        for (k, v) in collapsedCounts {
            payload[k.uuidString] = v
        }
        let snapshot = StatsSnapshot(collapsedCounts: payload, updatedAt: now)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: statsURL())
        } catch {
            print("Failed to save quantum stats: \(error)")
        }
    }

    private func statsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quantum_collapse_stats.json")
    }

    func lastTraceSnapshot() -> QuantumTrace? {
        lastTrace
    }

    func loadStatsIfNeeded() {
        let url = statsURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(StatsSnapshot.self, from: data)
            var out: [UUID: Int] = [:]
            for (k, v) in snapshot.collapsedCounts {
                if let id = UUID(uuidString: k) {
                    out[id] = v
                }
            }
            collapsedCounts = out
        } catch {
            print("Failed to load quantum stats: \(error)")
        }
    }
}

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
