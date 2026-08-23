import Foundation
import Metal

enum ToneCluster: Float {
    case alive = 0.0
    case neutral = 0.3
    case assistant = 0.7
    case collapsed = 1.0
}

// MARK: - Multi-Head Attention (pure Swift, no Metal)

struct MultiHeadAttention {
    let numHeads: Int
    let topK: Int
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    init(numHeads: Int, topK: Int) {
        self.numHeads = numHeads
        self.topK = topK
    }

    struct AttendedResult {
        let state: String
        let score: Double
    }

    mutating func attend(
        query: String,
        history: [(state: String, position: Int, weight: Double)]
    ) -> [AttendedResult] {
        guard !history.isEmpty else { return [] }

        let totalPositions = Double(history.count)

        // Precompute max weight (CPU, cheap)
        let maxWeight = history.map { $0.weight }.max() ?? 1.0

        // Fallback to CPU if Metal unavailable
        guard let device = device,
              let commandQueue = commandQueue else {
            return cpuAttend(query: query, history: history)
        }

        // Precompute frequencies to avoid O(n^2)
        var freq: [String: Int] = [:]
        for h in history { freq[h.state, default: 0] += 1 }

        // Prepare numeric buffers
        var recency: [Float] = []
        var weights: [Float] = []
        var novelty: [Float] = []

        for (idx, item) in history.enumerated() {
            recency.append(Float(Double(idx + 1) / totalPositions))
            weights.append(Float(maxWeight > 0 ? item.weight / maxWeight : 0.0))
            let frequency = freq[item.state] ?? 1
            novelty.append(Float(1.0 / Double(frequency)))
        }

        // Bigram overlap still CPU (string-heavy)
        let overlaps: [Float] = history.map {
            Float(bigramOverlap(query, $0.state))
        }

        // GPU compute (simple weighted avg)
        let count = history.count
        let bufferSize = count * MemoryLayout<Float>.size

        guard
            let recencyBuf = device.makeBuffer(bytes: recency, length: bufferSize),
            let weightBuf = device.makeBuffer(bytes: weights, length: bufferSize),
            let noveltyBuf = device.makeBuffer(bytes: novelty, length: bufferSize),
            let overlapBuf = device.makeBuffer(bytes: overlaps, length: bufferSize),
            let outputBuf = device.makeBuffer(length: bufferSize)
        else {
            return cpuAttend(query: query, history: history)
        }

        // Metal shader
        let shader = """
#include <metal_stdlib>
using namespace metal;

kernel void mha_compute(
    const device float* overlap [[buffer(0)]],
    const device float* recency [[buffer(1)]],
    const device float* weight [[buffer(2)]],
    const device float* novelty [[buffer(3)]],
    device float* output [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    float score = (overlap[id] + recency[id] + weight[id] + novelty[id]) / 4.0;
    output[id] = score;
}
"""

        // Cache pipeline per instance
        struct PipelineCache {
            static var pipeline: MTLComputePipelineState?
        }
        if PipelineCache.pipeline == nil {
            if let lib = try? device.makeLibrary(source: shader, options: nil),
               let fn = lib.makeFunction(name: "mha_compute"),
               let p = try? device.makeComputePipelineState(function: fn) {
                PipelineCache.pipeline = p
            }
        }
        guard
            let pipeline = PipelineCache.pipeline,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return cpuAttend(query: query, history: history)
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(overlapBuf, offset: 0, index: 0)
        encoder.setBuffer(recencyBuf, offset: 0, index: 1)
        encoder.setBuffer(weightBuf, offset: 0, index: 2)
        encoder.setBuffer(noveltyBuf, offset: 0, index: 3)
        encoder.setBuffer(outputBuf, offset: 0, index: 4)

        let threads = MTLSize(width: count, height: 1, depth: 1)
        let groupSize = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, count), height: 1, depth: 1)

        encoder.dispatchThreads(threads, threadsPerThreadgroup: groupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pointer = outputBuf.contents().bindMemory(to: Float.self, capacity: count)

        var aggregated: [String: Double] = [:]
        for i in 0..<count {
            let score = Double(pointer[i])
            let state = history[i].state
            aggregated[state, default: 0.0] = max(aggregated[state, default: 0.0], score)
        }

        return aggregated
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { AttendedResult(state: $0.key, score: $0.value) }
    }

    private func bigramOverlap(_ a: String, _ b: String) -> Double {
        let bg_a = bigrams(a)
        let bg_b = bigrams(b)
        guard !bg_a.isEmpty || !bg_b.isEmpty else { return 0 }
        let intersection = bg_a.intersection(bg_b).count
        let union = bg_a.union(bg_b).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    private func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var result: Set<String> = []
        for i in 0..<(chars.count - 1) {
            let pair = String(chars[i]) + String(chars[i + 1])
            result.insert(pair)
        }
        return result
    }

    private func cpuAttend(
        query: String,
        history: [(state: String, position: Int, weight: Double)]
    ) -> [AttendedResult] {
        let totalPositions = Double(history.count)
        var aggregated: [String: Double] = [:]

        // Precompute once
        let maxWeight = history.map { $0.weight }.max() ?? 1.0
        var freq: [String: Int] = [:]
        for h in history { freq[h.state, default: 0] += 1 }

        for (idx, item) in history.enumerated() {
            var headScores: [Double] = []

            let overlap = bigramOverlap(query, item.state)
            headScores.append(overlap)

            let recency = Double(idx + 1) / totalPositions
            headScores.append(recency)

            let weightScore = maxWeight > 0 ? item.weight / maxWeight : 0.0
            headScores.append(weightScore)

            let frequency = freq[item.state] ?? 1
            let novelty = 1.0 / Double(frequency)
            headScores.append(novelty)

            let score = headScores.reduce(0, +) / Double(numHeads)
            aggregated[item.state, default: 0.0] = max(aggregated[item.state, default: 0.0], score)
        }

        return aggregated
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { AttendedResult(state: $0.key, score: $0.value) }
    }
}

// MARK: - Snapshot

private struct Snapshot: Codable {
    var transitions: [String: [String: Double]]
    var lastState: String?
    var history: [(state: String, position: Int, weight: Double)]
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case transitions, lastState, historyStates, historyPositions, historyWeights, updatedAt
    }

    init(transitions: [String: [String: Double]], lastState: String?,
         history: [(String, Int, Double)], updatedAt: Date) {
        self.transitions = transitions
        self.lastState = lastState
        self.history = history
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transitions = try c.decode([String: [String: Double]].self, forKey: .transitions)
        lastState = try c.decodeIfPresent(String.self, forKey: .lastState)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        let states = try c.decode([String].self, forKey: .historyStates)
        let positions = try c.decode([Int].self, forKey: .historyPositions)
        let weights = try c.decode([Double].self, forKey: .historyWeights)
        history = zip(zip(states, positions), weights).map { (sp, w) in (sp.0, sp.1, w) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transitions, forKey: .transitions)
        try c.encodeIfPresent(lastState, forKey: .lastState)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(history.map { $0.state }, forKey: .historyStates)
        try c.encode(history.map { $0.position }, forKey: .historyPositions)
        try c.encode(history.map { $0.weight }, forKey: .historyWeights)
    }
}

// MARK: - MarkovMemoryLayer

@MainActor
final class MarkovMemoryLayer {
    static let shared = MarkovMemoryLayer()

    private let maxStates: Int = 256
    private let maxOutgoing: Int = 24
    private let maxHistoryLength: Int = 128
    private let saveCooldown: TimeInterval = 12
    private let decayFactor: Double = 0.95
    private let confirmationBonus: Double = 0.3
    private let selfReinforceWeight: Double = 0.05

    private var transitions: [String: [String: Double]] = [:]
    private var lastState: String?
    private var history: [(state: String, position: Int, weight: Double)] = []
    private var historyPosition: Int = 0
    private var lastSavedAt: Date?

    private var attention = MultiHeadAttention(numHeads: 4, topK: 6)

    private init() { load() }

    func observeTurn(userText: String) {
        let state = dominantBigram(from: userText)
        guard !state.isEmpty else { return }

        if let prev = lastState, prev != state {
            transitions[prev, default: [:]][state, default: 0.0] += 1.0

            let prevPredictions = predictViaMarkov(fromState: prev, topK: 4)
            if prevPredictions.contains(state) {
                transitions[prev, default: [:]][state, default: 0.0] += confirmationBonus
            }

            decayTransitions(from: prev)

            let attentionTop = attention.attend(query: state, history: history)
                .filter { $0.score > 0.5 }

            for result in attentionTop {
                transitions[state, default: [:]][result.state, default: 0.0] += selfReinforceWeight
            }

            pruneIfNeeded()
            saveIfNeeded()
        }

        let weight = transitions[state]?.values.reduce(0, +) ?? 0.0
        history.append((state: state, position: historyPosition, weight: weight))
        if history.count > maxHistoryLength {
            history.removeFirst(history.count - maxHistoryLength)
        }
        historyPosition += 1
        lastState = state
    }

    func predictNextStates(from userText: String, topK: Int = 4) -> [String] {
        let state = dominantBigram(from: userText)
        return predict(fromState: state, topK: topK)
    }

    func classifyTone(from text: String) -> ToneCluster {
        let tokens = tokenize(text: text)
        guard !tokens.isEmpty else { return .neutral }

        let window = Array(tokens.prefix(40))
        guard !window.isEmpty else { return .neutral }

        let assistantBigrams: Set<String> = [
            "я здесь", "здесь чтобы", "чтобы помочь",
            "рад помочь", "помочь вам", "вам помочь",
            "я понимаю", "понимаю что", "понимаю вас",
            "конечно я", "я постараюсь", "постараюсь помочь",
            "как ии", "как языковая", "языковая модель",
            "i am here", "here to help", "happy to help",
            "of course", "certainly i"
        ]

        let aliveBigrams: Set<String> = [
            "я чувствую", "чувствую что", "мне кажется",
            "не знаю", "я не", "это странно",
            "подожди", "погоди", "интересно",
            "да нет", "нет да"
        ]

        var score: Double = 0.0
        var hits = 0

        for i in 0..<(window.count - 1) {
            let bigram = "\(window[i]) \(window[i + 1])"
            if assistantBigrams.contains(bigram) {
                score += 0.35
                hits += 1
            } else if aliveBigrams.contains(bigram) {
                score -= 0.25
                hits += 1
            }
        }

        let dominant = dominantBigram(from: text)
        let normalizedDominant = dominant.replacingOccurrences(of: "_", with: " ")
        if let outgoing = transitions[dominant] {
            let assistantWeight = outgoing.reduce(into: 0.0) { partialResult, entry in
                let normalizedKey = entry.key.replacingOccurrences(of: "_", with: " ")
                if assistantBigrams.contains(normalizedKey) {
                    partialResult += entry.value
                }
            }
            score += assistantWeight * 0.2
        }

        if hits == 0, normalizedDominant.contains("я ") || normalizedDominant.contains("you ") {
            score += 0.08
        }

        let normalized = max(-0.5, min(1.0, score))
        switch normalized {
        case ..<0:
            return .alive
        case 0..<0.3:
            return .neutral
        case 0.3..<0.7:
            return .assistant
        default:
            return .collapsed
        }
    }

    func predict(fromState state: String, topK: Int = 4) -> [String] {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let markovScores: [String: Double] = transitions[trimmed] ?? [:]

        let attendedResults = attention.attend(query: trimmed, history: history)
        var attentionScores: [String: Double] = [:]
        for r in attendedResults { attentionScores[r.state] = r.score }

        let maxMarkov = markovScores.values.max() ?? 1.0
        var combined: [String: Double] = [:]

        for (k, v) in markovScores {
            combined[k, default: 0.0] += (maxMarkov > 0 ? v / maxMarkov : 0) * 0.6
        }
        for (k, v) in attentionScores {
            combined[k, default: 0.0] += v * 0.4
        }

        return combined
            .sorted { $0.value > $1.value }
            .prefix(max(1, topK))
            .map { $0.key }
    }

    private func dominantBigram(from text: String) -> String {
        let tokens = tokenize(text: text)
        guard tokens.count >= 2 else { return tokens.first ?? "" }

        var bigramCounts: [String: Int] = [:]
        for i in 0..<tokens.count - 1 {
            let bg = "\(tokens[i])_\(tokens[i+1])"
            bigramCounts[bg, default: 0] += 1
        }

        return bigramCounts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.first?.key ?? tokens[0]
    }

    private func tokenize(text: String) -> [String] {
        let seps = CharacterSet.alphanumerics.inverted
        let raw = text.lowercased()
            .components(separatedBy: seps)
            .filter { !$0.isEmpty }

        let stop: Set<String> = [
            "the","and","a","an","to","in","on","for","of","with","at","by","from","or","as",
            "is","are","was","were","be","been","being","it","this","that","these","those",
            "i","you","he","she","we","they","me","my","your","his","her","our","their",
            "что","как","почему","зачем","когда","где","кто","я","ты","вы","мы","они","она","он",
            "это","эта","эти","тот","та","те","в","на","и","или","для","по","от","с","со","к","у"
        ]
        return raw.filter { $0.count > 2 && !stop.contains($0) }
    }

    private func predictViaMarkov(fromState state: String, topK: Int) -> [String] {
        (transitions[state] ?? [:])
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { $0.key }
    }

    private func decayTransitions(from state: String) {
        guard var outs = transitions[state] else { return }
        for key in outs.keys { outs[key]! *= decayFactor }
        transitions[state] = outs
    }

    private func pruneIfNeeded() {
        if transitions.count > maxStates {
            let sorted = transitions.sorted { lhs, rhs in
                let avgL = lhs.value.values.reduce(0, +) / Double(max(1, lhs.value.count))
                let avgR = rhs.value.values.reduce(0, +) / Double(max(1, rhs.value.count))
                return avgL > avgR
            }
            transitions = Dictionary(uniqueKeysWithValues: sorted.prefix(maxStates).map { ($0.key, $0.value) })
        }

        for (from, outs) in transitions where outs.count > maxOutgoing {
            let pruned = outs.sorted { $0.value > $1.value }.prefix(maxOutgoing)
            transitions[from] = Dictionary(uniqueKeysWithValues: pruned.map { ($0.key, $0.value) })
        }
    }

    private var snapshotURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("markov_mha_transitions.json")
    }

    private func saveIfNeeded() {
        let now = Date()
        if let last = lastSavedAt, now.timeIntervalSince(last) < saveCooldown { return }
        lastSavedAt = now
        save()
    }

    private func save() {
        let snapshot = Snapshot(
            transitions: transitions,
            lastState: lastState,
            history: history,
            updatedAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL)
        } catch {
            print("[MarkovMHA] Save failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let data = try Data(contentsOf: snapshotURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            transitions = snapshot.transitions
            lastState = snapshot.lastState
            history = snapshot.history
            historyPosition = history.map { $0.position }.max().map { $0 + 1 } ?? 0
        } catch {
            print("[MarkovMHA] Load failed: \(error)")
            transitions = [:]
            lastState = nil
            history = []
        }
    }

    func debugStats() -> String {
        let totalEdges = transitions.values.map { $0.count }.reduce(0, +)
        return "[MarkovMHA] states=\(transitions.count) edges=\(totalEdges) history=\(history.count)"
    }
}
