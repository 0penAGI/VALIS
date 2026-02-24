import Foundation
import UIKit

struct Memory: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Date
    let emotion: String
    let emotionValence: Double
    let emotionIntensity: Double
    let embedding: [Double]
    let links: [UUID]
    let importance: Double
    let predictionScore: Double
    let predictionError: Double
    let isIdentity: Bool
    let isPinned: Bool
    let lastAccess: Date
    let isSelfReflection: Bool
    let perspective: String
    
    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = Date(),
        emotion: String = "neutral",
        emotionValence: Double = 0.0,
        emotionIntensity: Double = 0.2,
        embedding: [Double] = [],
        links: [UUID] = [],
        importance: Double = 1.0,
        predictionScore: Double = 0.0,
        predictionError: Double = 0.0,
        isIdentity: Bool = false,
        isPinned: Bool = false,
        lastAccess: Date = Date(),
        isSelfReflection: Bool = false,
        perspective: String = "self"
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.emotion = emotion
        self.emotionValence = emotionValence
        self.emotionIntensity = emotionIntensity
        self.embedding = embedding
        self.links = links
        self.importance = importance
        self.predictionScore = predictionScore
        self.predictionError = predictionError
        self.isIdentity = isIdentity
        self.isPinned = isPinned
        self.lastAccess = lastAccess
        self.isSelfReflection = isSelfReflection
        self.perspective = perspective
    }

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case timestamp
        case emotion
        case emotionValence
        case emotionIntensity
        case embedding
        case links
        case importance
        case predictionScore
        case predictionError
        case isIdentity
        case isPinned
        case lastAccess
        case isSelfReflection
        case perspective
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id: accept UUID or string; fallback to generated UUID
        if let decodedId = try? container.decode(UUID.self, forKey: .id) {
            self.id = decodedId
        } else if let idString = try? container.decode(String.self, forKey: .id),
                  let uuid = UUID(uuidString: idString) {
            self.id = uuid
        } else {
            self.id = UUID()
        }

        self.content = (try? container.decode(String.self, forKey: .content)) ?? ""
        self.emotion = (try? container.decode(String.self, forKey: .emotion)) ?? "neutral"
        self.emotionValence = (try? container.decode(Double.self, forKey: .emotionValence)) ?? 0.0
        self.emotionIntensity = (try? container.decode(Double.self, forKey: .emotionIntensity)) ?? 0.2
        self.embedding = (try? container.decode([Double].self, forKey: .embedding)) ?? []
        self.links = (try? container.decode([UUID].self, forKey: .links)) ?? []
        self.importance = (try? container.decode(Double.self, forKey: .importance)) ?? 1.0
        self.predictionScore = (try? container.decode(Double.self, forKey: .predictionScore)) ?? 0.0
        self.predictionError = (try? container.decode(Double.self, forKey: .predictionError)) ?? 0.0
        self.isIdentity = (try? container.decode(Bool.self, forKey: .isIdentity)) ?? false
        self.isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
        if let lastAccess = try? container.decode(Date.self, forKey: .lastAccess) {
            self.lastAccess = lastAccess
        } else {
            self.lastAccess = Date()
        }
        self.isSelfReflection = (try? container.decode(Bool.self, forKey: .isSelfReflection)) ?? false
        self.perspective = (try? container.decode(String.self, forKey: .perspective)) ?? "self"

        // timestamp: accept Date, or numeric seconds since epoch, or string number
        if let date = try? container.decode(Date.self, forKey: .timestamp) {
            self.timestamp = date
        } else if let seconds = try? container.decode(Double.self, forKey: .timestamp) {
            self.timestamp = Date(timeIntervalSince1970: seconds)
        } else if let secondsInt = try? container.decode(Int.self, forKey: .timestamp) {
            self.timestamp = Date(timeIntervalSince1970: TimeInterval(secondsInt))
        } else if let secondsString = try? container.decode(String.self, forKey: .timestamp),
                  let seconds = Double(secondsString) {
            self.timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            self.timestamp = Date()
        }
    }
}

@MainActor
class MemoryService: ObservableObject {
    static let shared = MemoryService()
    
    @Published var memories: [Memory] = []
    @Published private(set) var graph: MemoryGraph = MemoryGraph()
    @Published private(set) var echoGraph: CognitiveEchoGraph = CognitiveEchoGraph()
    @Published private(set) var conversationSummary: String = ""
    @Published private(set) var userProfile: UserProfile = UserProfile()

    private var spontaneousTask: Task<Void, Never>?
    private var lastAutonomousAt: Date?
    private let maxAutonomousSnippets = 3
    private let autonomousImportance: Double = 0.7

    private let profile: MemoryProfile
    private let autonomousInterval: TimeInterval
    private let echoTickInterval: UInt64
    private let spontaneousTickInterval: UInt64
    private let compressedBudget: Int
    private let rawBudget: Int
    private let contextGateThreshold: Double = 0.28
    private let accessSaveCooldown: TimeInterval = 30
    private var lastAccessSaveAt: Date?
    
    init() {
        let detected = MemoryProfile.detect()
        profile = detected
        autonomousInterval = detected.autonomousInterval
        echoTickInterval = detected.echoTickInterval
        spontaneousTickInterval = detected.spontaneousTickInterval
        compressedBudget = detected.compressedBudget
        rawBudget = detected.rawBudget

        loadMemories()
        loadGraph()
        loadEchoGraph()
        demoteLegacyIdentityMemoriesIfNeeded()
        seedEchoGraphIfNeeded()
        startEchoLoop()
        startSpontaneousLoop()
    }
    
    // MARK: - HyperHolographic Cognitive Layer

    private func buildCognitiveLayer(
        for text: String,
        importanceOverride: Double? = nil,
        isReflection: Bool = false,
        perspective: String = "self"
    ) -> Memory {
        let emotion = detectEmotion(from: text)
        let embedding = generateEmbedding(from: text)
        let links = findRelatedMemories(embedding: embedding)
        let importance = importanceOverride ?? baseImportance(forEmotion: emotion.label)

        return Memory(
            content: text,
            timestamp: Date(),
            emotion: emotion.label,
            emotionValence: emotion.valence,
            emotionIntensity: emotion.intensity,
            embedding: embedding,
            links: links,
            importance: importance,
            isSelfReflection: isReflection,
            perspective: perspective
        )
    }

    private func baseImportance(forEmotion emotion: String) -> Double {
        switch emotion {
        case "positive":
            return 1.2
        case "negative", "fear":
            return 1.1
        default:
            return 1.0
        }
    }

    private func detectEmotion(from text: String) -> EmotionSignal {
        let lower = text.lowercased()

        if lower.contains("love") || lower.contains("happy") || lower.contains("рад") {
            return EmotionSignal(label: "positive", valence: 0.8, intensity: 0.7)
        }
        if lower.contains("hate") || lower.contains("sad") || lower.contains("боль") {
            return EmotionSignal(label: "negative", valence: -0.7, intensity: 0.7)
        }
        if lower.contains("fear") || lower.contains("страх") || lower.contains("panic") {
            return EmotionSignal(label: "fear", valence: -0.6, intensity: 0.8)
        }

        return EmotionSignal(label: "neutral", valence: 0.0, intensity: 0.2)
    }

    private func generateEmbedding(from text: String) -> [Double] {
        let scalars = text.unicodeScalars.map { Double($0.value) }
        let size = 32

        var vector = Array(repeating: 0.0, count: size)

        for (i, v) in scalars.enumerated() {
            vector[i % size] += v
        }

        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }

        return vector
    }

    private func findRelatedMemories(embedding: [Double]) -> [UUID] {
        guard !embedding.isEmpty else { return [] }

        var result: [UUID] = []

        for mem in memories {
            let sim = cosineSimilarity(a: embedding, b: mem.embedding)
            if sim > 0.85 {
                result.append(mem.id)
            }
        }

        return result
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
    
    func addMemory(_ content: String) {
        let enriched = buildCognitiveLayer(for: content)
        memories.append(enriched)
        saveMemories()
        updateGraph(for: enriched)
        echoGraph.activate(memoryId: enriched.id, embedding: enriched.embedding, importance: enriched.importance, isPersistent: enriched.isIdentity)
        saveGraph()
        saveEchoGraph()
    }

    func addAutonomousMemory(_ content: String) {
        let enriched = buildCognitiveLayer(for: content, importanceOverride: autonomousImportance)
        memories.append(enriched)
        saveMemories()
        updateGraph(for: enriched)
        echoGraph.activate(memoryId: enriched.id, embedding: enriched.embedding, importance: enriched.importance, strength: 0.6, isPersistent: enriched.isIdentity)
        saveGraph()
        saveEchoGraph()
    }

    func addExperienceMemory(_ content: String, importanceOverride: Double) {
        let enriched = buildCognitiveLayer(for: content, importanceOverride: importanceOverride)
        memories.append(enriched)
        saveMemories()
        updateGraph(for: enriched)
        echoGraph.activate(
            memoryId: enriched.id,
            embedding: enriched.embedding,
            importance: enriched.importance,
            strength: 0.35,
            isPersistent: enriched.isIdentity
        )
        saveGraph()
        saveEchoGraph()
    }
    
    func updateMemory(id: UUID, content: String) {
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            let updated = buildCognitiveLayer(for: content)
            let existing = memories[idx]

            memories[idx] = Memory(
                id: id,
                content: updated.content,
                timestamp: Date(),
                emotion: updated.emotion,
                emotionValence: updated.emotionValence,
                emotionIntensity: updated.emotionIntensity,
                embedding: updated.embedding,
                links: updated.links,
                importance: updated.importance,
                predictionScore: existing.predictionScore,
                predictionError: existing.predictionError,
                isIdentity: existing.isIdentity,
                isPinned: existing.isPinned,
                lastAccess: existing.lastAccess,
                isSelfReflection: existing.isSelfReflection,
                perspective: existing.perspective
            )

            saveMemories()
            rebuildGraph()
        }
    }

    func togglePinned(id: UUID) {
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            let m = memories[idx]
            memories[idx] = Memory(
                id: m.id,
                content: m.content,
                timestamp: m.timestamp,
                emotion: m.emotion,
                emotionValence: m.emotionValence,
                emotionIntensity: m.emotionIntensity,
                embedding: m.embedding,
                links: m.links,
                importance: m.importance,
                predictionScore: m.predictionScore,
                predictionError: m.predictionError,
                isIdentity: m.isIdentity,
                isPinned: !m.isPinned,
                lastAccess: m.lastAccess,
                isSelfReflection: m.isSelfReflection,
                perspective: m.perspective
            )
            saveMemories()
            rebuildGraph()
        }
    }

    func clearAllMemories(keepIdentity: Bool = true, keepPinned: Bool = true) {
        if keepIdentity || keepPinned {
            memories = memories.filter { mem in
                if keepIdentity, mem.isIdentity { return true }
                if keepPinned, mem.isPinned { return true }
                return false
            }
        } else {
            memories.removeAll()
        }
        saveMemories()
        rebuildGraph()
    }

    func applyReinforcement(fromUserText text: String) {
        guard !memories.isEmpty else { return }
        let emotion = detectEmotion(from: text)
        let delta: Double
        switch emotion.label {
        case "positive":
            delta = 0.2
        case "negative", "fear":
            delta = -0.2
        default:
            delta = 0.0
        }
        guard delta != 0 else { return }
        let lastIndex = memories.indices.last!
        let m = memories[lastIndex]
        let newImportance = max(0.1, m.importance + delta)
        memories[lastIndex] = Memory(
            id: m.id,
            content: m.content,
            timestamp: m.timestamp,
            emotion: m.emotion,
            emotionValence: m.emotionValence,
            emotionIntensity: m.emotionIntensity,
            embedding: m.embedding,
            links: m.links,
            importance: newImportance,
            predictionScore: m.predictionScore,
            predictionError: m.predictionError,
            isIdentity: m.isIdentity,
            isPinned: m.isPinned,
            lastAccess: m.lastAccess,
            isSelfReflection: m.isSelfReflection,
            perspective: m.perspective
        )
        saveMemories()
        rebuildGraph()
    }

    func applyPredictionFeedback(fromUserText text: String) {
        guard !memories.isEmpty else { return }
        let lastIndex = memories.indices.last!
        let m = memories[lastIndex]
        let userEmbedding = generateEmbedding(from: text)
        let score = cosineSimilarity(a: m.embedding, b: userEmbedding)
        let error = max(0.0, 1.0 - score)
        let adjustedImportance = max(0.1, min(2.5, m.importance + (score - 0.5) * 0.1))

        memories[lastIndex] = Memory(
            id: m.id,
            content: m.content,
            timestamp: m.timestamp,
            emotion: m.emotion,
            emotionValence: m.emotionValence,
            emotionIntensity: m.emotionIntensity,
            embedding: m.embedding,
            links: m.links,
            importance: adjustedImportance,
            predictionScore: score,
            predictionError: error,
            isIdentity: m.isIdentity,
            isPinned: m.isPinned,
            lastAccess: m.lastAccess,
            isSelfReflection: m.isSelfReflection,
            perspective: m.perspective
        )
        saveMemories()
        rebuildGraph()
    }
    
    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
        rebuildGraph()
    }
    
    func deleteMemories(at offsets: IndexSet) {
        memories.remove(atOffsets: offsets)
        saveMemories()
        rebuildGraph()
    }
    
    func loadMemories() {
        // 1. Try to load from Documents directory (User generated)
        if let savedMemories = loadFromDocuments() {
            self.memories = savedMemories
            return
        }
        
        // 2. Try to load from Bundle (Pre-seeded "we already have a memories")
        if let bundledMemories = loadFromBundle() {
            self.memories = bundledMemories
            // Also save them to documents so we can edit them later
            saveMemories()
        }
    }
    
    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private func getMemoriesURL() -> URL {
        getDocumentsURL().appendingPathComponent("memories.json")
    }
    
    private func getGraphURL() -> URL {
        getDocumentsURL().appendingPathComponent("memory_graph.json")
    }
    
    private func getEchoGraphURL() -> URL {
        getDocumentsURL().appendingPathComponent("echo_graph.json")
    }
    
    private func saveMemories() {
        do {
            let data = try JSONEncoder().encode(memories)
            try data.write(to: getMemoriesURL())
        } catch {
            print("Failed to save memories: \(error)")
        }
    }
    
    private func saveGraph() {
        do {
            let data = try JSONEncoder().encode(graph)
            try data.write(to: getGraphURL())
        } catch {
            print("Failed to save graph: \(error)")
        }
    }
    
    private func saveEchoGraph() {
        do {
            let snapshot = echoGraph.snapshot()
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: getEchoGraphURL())
        } catch {
            print("Failed to save echo graph: \(error)")
        }
    }
    
    private func loadFromDocuments() -> [Memory]? {
        let url = getMemoriesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Memory].self, from: data)
        } catch {
            print("Failed to load memories from docs: \(error)")
            return nil
        }
    }
    
    private func loadFromBundle() -> [Memory]? {
        // Look for "memories.json" in bundle
        guard let url = Bundle.main.url(forResource: "memories", withExtension: "json") else { return nil }
        
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Memory].self, from: data)
        } catch {
            print("Failed to load memories from bundle: \(error)")
            return nil
        }
    }
    
    private func loadGraph() {
        let url = getGraphURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            graph = MemoryGraph()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            graph = try JSONDecoder().decode(MemoryGraph.self, from: data)
        } catch {
            print("Failed to load graph: \(error)")
            graph = MemoryGraph()
        }
    }
    
    private func loadEchoGraph() {
        let url = getEchoGraphURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            echoGraph = CognitiveEchoGraph()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(CognitiveEchoGraphSnapshot.self, from: data)
            echoGraph.load(from: snapshot)
        } catch {
            print("Failed to load echo graph: \(error)")
            echoGraph = CognitiveEchoGraph()
        }
    }

    private func demoteLegacyIdentityMemoriesIfNeeded() {
        var didChange = false
        for idx in memories.indices {
            let m = memories[idx]
            let looksLegacyIdentity = m.content.contains("[identity:") || m.emotion == "identity"
            guard m.isIdentity || looksLegacyIdentity || m.isPinned else { continue }

            memories[idx] = Memory(
                id: m.id,
                content: m.content,
                timestamp: m.timestamp,
                emotion: m.emotion,
                emotionValence: m.emotionValence,
                emotionIntensity: m.emotionIntensity,
                embedding: m.embedding,
                links: m.links,
                importance: min(1.4, max(1.0, m.importance)),
                predictionScore: m.predictionScore,
                predictionError: m.predictionError,
                isIdentity: false,
                isPinned: false,
                lastAccess: m.lastAccess,
                isSelfReflection: m.isSelfReflection,
                perspective: m.perspective
            )
            didChange = true
        }

        guard didChange else { return }
        saveMemories()
        rebuildGraph()
    }
    
    private func startEchoLoop() {
        Task.detached { [weak self] in
            while true {
                guard let self = self else { return }
                try await Task.sleep(nanoseconds: self.echoTickInterval)
                await MainActor.run {
                    self.echoGraph.decay()
                    self.echoGraph.spontaneousActivation()
                }
            }
        }
    }

    private func startSpontaneousLoop() {
        spontaneousTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: self.spontaneousTickInterval)
                let triggeredId: UUID? = await MainActor.run {
                    self.echoGraph.spontaneousStep()
                }
                if let id = triggeredId {
                    await self.autonomousConsolidate(memoryId: id)
                } else {
                    await self.autonomousConsolidateIfIdle()
                }
                await MainActor.run {
                    self.pruneMemoriesIfNeeded()
                }
            }
        }
    }
    
    private func rebuildGraph() {
        graph = MemoryGraph()
        echoGraph = CognitiveEchoGraph()
        for m in memories {
            updateGraph(for: m)
            echoGraph.register(memoryId: m.id, embedding: m.embedding, importance: m.importance, isPersistent: m.isIdentity)
        }
        saveGraph()
        saveEchoGraph()
    }
    
    private func updateGraph(for memory: Memory) {
        let memId = "mem:\(memory.id.uuidString)"
        graph.ensureNode(id: memId, type: .memory, label: String(memory.content.prefix(120)))
        let concepts = extractConcepts(from: memory.content)
        for c in concepts {
            let cid = "concept:\(c)"
            graph.ensureNode(id: cid, type: .concept, label: c)
            graph.link(from: memId, to: cid, weight: 1.0)
        }
        let emoId = "emotion:\(memory.emotion)"
        graph.ensureNode(id: emoId, type: .emotion, label: memory.emotion)
        graph.link(from: memId, to: emoId, weight: 1.0)
        for linked in memory.links {
            let lid = "mem:\(linked.uuidString)"
            graph.ensureNode(id: lid, type: .memory, label: lid)
            graph.link(from: memId, to: lid, weight: 0.9)
        }
    }
    
    private func extractConcepts(from text: String) -> [String] {
        let seps = CharacterSet.alphanumerics.inverted
        let tokens = text
            .lowercased()
            .components(separatedBy: seps)
            .filter { !$0.isEmpty }
        let stop: Set<String> = [
            "the","and","a","an","to","in","on","for","of","with","at","by","from","or","as",
            "is","are","was","were","be","been","being","it","this","that","these","those",
            "i","you","he","she","we","they","me","my","your","his","her","our","their"
        ]
        let filtered = tokens.filter { $0.count > 3 && !stop.contains($0) }
        return Array(Set(filtered)).prefix(32).map { $0 }
    }

    private func seedEchoGraphIfNeeded() {
        let hasAnyMemoryNodes = memories.contains { echoGraph.hasNode($0.id) }
        if echoGraph.isEmpty || !hasAnyMemoryNodes {
            echoGraph = CognitiveEchoGraph()
            for m in memories {
                echoGraph.register(memoryId: m.id, embedding: m.embedding, importance: m.importance, isPersistent: m.isIdentity)
            }
            saveEchoGraph()
        }
    }

    // Compress memory to reduce context noise
    private func compressMemory(_ text: String, maxWords: Int = 24) -> String {
        let seps = CharacterSet.alphanumerics.inverted
        let tokens = text
            .lowercased()
            .components(separatedBy: seps)
            .filter { !$0.isEmpty }

        // Remove weak filler words
        let stop: Set<String> = [
            "the","and","a","an","to","in","on","for","of","with","at","by","from","or","as",
            "is","are","was","were","be","been","being","it","this","that","these","those",
            "i","you","he","she","we","they","me","my","your","his","her","our","their"
        ]

        let filtered = tokens.filter { $0.count > 3 && !stop.contains($0) }

        // Take most information-dense words
        let important = filtered.prefix(maxWords)

        return important.joined(separator: " ")
    }
    
    func getContextBlock() -> String {
        getContextBlock(maxChars: Int.max)
    }

    func getContextBlock(maxChars: Int) -> String {
        if memories.isEmpty { return "" }
        if maxChars <= 0 { return "" }

        let field = echoGraph.fieldVector()

        func takeLines(_ lines: [String], budget: Int) -> String {
            guard budget > 0 else { return "" }
            var used = 0
            var out: [String] = []
            for line in lines {
                let cost = line.count + 1
                if used + cost > budget { break }
                out.append(line)
                used += cost
            }
            return out.joined(separator: "\n")
        }

        let ranked = memories
            .sorted { lhs, rhs in
                let ls = relevanceScore(for: lhs, field: field)
                let rs = relevanceScore(for: rhs, field: field)
                if ls == rs {
                    return lhs.timestamp > rhs.timestamp
                }
                return ls > rs
            }
            .prefix(5)
        recordAccess(for: ranked.map { $0.id })

        let memoryContent = ranked.map { mem in
            let compressed = compressMemory(mem.content)
            return "- [\(mem.emotion)] \(compressed)"
        }

        let emotionSummary = aggregateEmotions(memories: Array(ranked))
        let sortedEmotions = emotionSummary
            .sorted { $0.value > $1.value }
        let dominantEmotion = sortedEmotions.first?.key ?? "neutral"
        let emotionLine = sortedEmotions
            .map { "\($0.key): \(Int(($0.value * 100).rounded()))%" }
            .joined(separator: ", ")
        let sortedByRecent = memories.sorted { $0.timestamp > $1.timestamp }
        let moodLine = emotionalDynamicsSummary(from: sortedByRecent)
        let summaryBlock = conversationSummary.isEmpty ? "" : "Conversation Summary:\n\(conversationSummary)"
        let profileBlock = userProfile.contextBlock()

        let rawLines = sortedByRecent.map { "- [\($0.emotion)] \($0.content)" }

        // Dynamic budgets based on maxChars and profile defaults
        let baseCompressed = compressedBudget
        let baseRaw = rawBudget
        let dynamicCompressed = min(baseCompressed, max(120, maxChars / 3))
        let dynamicRaw = min(baseRaw, max(200, maxChars / 3))

        let activationLevel = echoGraph.averageActivation(excludingPersistent: true)
        let isContextGated = activationLevel < contextGateThreshold

        var compressedBlock = takeLines(memoryContent, budget: dynamicCompressed)
        let rawRecent = isContextGated ? "" : takeLines(rawLines, budget: dynamicRaw)

        var predictionBlock: String? = nil
        if let last = memories.sorted(by: { $0.timestamp > $1.timestamp }).first {
            predictionBlock = """
            Anticipation Pattern (last memory):
            Score: \(String(format: "%.2f", last.predictionScore))
            Error: \(String(format: "%.2f", last.predictionError))
            """
        }

        let emotionBlock = """
        Affective State (from memories):
        Dominant: \(dominantEmotion)
        Distribution: \(emotionLine)
        Dynamics: \(moodLine)
        Guidance: Treat emotions gently and carefully; validate and respond with steady empathy.
        """

        func buildParts(includeRaw: Bool, includePrediction: Bool, includeEmotion: Bool) -> String {
            var parts: [String] = []
            if !compressedBlock.isEmpty {
                parts.append("""
                Active Memory Field:
                \(compressedBlock)
                """)
            }
            if includePrediction, let predictionBlock {
                parts.append(predictionBlock)
            }
            if includeEmotion {
                parts.append(emotionBlock)
            }
            if !summaryBlock.isEmpty {
                parts.append(summaryBlock)
            }
            if !profileBlock.isEmpty {
                parts.append(profileBlock)
            }
            if includeRaw, !rawRecent.isEmpty {
                parts.append("""
                Recent Internal Experience:
                \(rawRecent)
                """)
            }
            return "\n\n" + parts.joined(separator: "\n\n")
        }

        var includeRaw = !isContextGated
        var includePrediction = true
        var includeEmotion = true
        var result = buildParts(includeRaw: includeRaw, includePrediction: includePrediction, includeEmotion: includeEmotion)

        // If still too long, drop optional parts and shrink compressed further.
        if result.count > maxChars {
            includeRaw = false
            result = buildParts(includeRaw: includeRaw, includePrediction: includePrediction, includeEmotion: includeEmotion)
        }
        if result.count > maxChars {
            includePrediction = false
            result = buildParts(includeRaw: includeRaw, includePrediction: includePrediction, includeEmotion: includeEmotion)
        }
        if result.count > maxChars {
            includeEmotion = false
            result = buildParts(includeRaw: includeRaw, includePrediction: includePrediction, includeEmotion: includeEmotion)
        }
        while result.count > maxChars && !compressedBlock.isEmpty {
            let newBudget = max(40, compressedBlock.count - max(40, compressedBlock.count / 5))
            compressedBlock = takeLines(memoryContent, budget: newBudget)
            result = buildParts(includeRaw: includeRaw, includePrediction: includePrediction, includeEmotion: includeEmotion)
        }

        return result.count > maxChars ? String(result.prefix(maxChars)) : result
    }

    // MARK: - Cognitive Post-Processing

    func applyCognitiveLayer(
        to draft: String,
        userPrompt: String,
        detail: DetailLevel,
        motivators: MotivatorState,
        preferences: UserPreferenceProfile
    ) -> String {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)


        text = normalizeWhitespace(text)
        text = removeDuplicateLines(text)

        if detail != .brief {
            text = ensureReadableParagraphs(text)
        }

        if motivators.caution > 0.7 && !containsCautionHint(in: text) {
            text += "\n\nЕсли тема чувствительная (медицина, финансы, право), уточни контекст и ограничения."
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func needsClarification(text: String, prompt: String, preferences: UserPreferenceProfile) -> Bool {
        let lower = text.lowercased()
        if lower.contains("не знаю") || lower.contains("not sure") || lower.contains("unsure") {
            return true
        }
        if text.count < 80 && prompt.count > 20 {
            return true
        }

        let promptConcepts = Set(extractConcepts(from: prompt))
        let responseConcepts = Set(extractConcepts(from: text))
        if !promptConcepts.isEmpty {
            let overlap = promptConcepts.intersection(responseConcepts).count
            if overlap <= max(1, promptConcepts.count / 3) {
                return true
            }
        }

        let dislikes = preferences.topDislikes(limit: 4)
        if !dislikes.isEmpty {
            let responseLower = text.lowercased()
            if dislikes.contains(where: { responseLower.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func normalizeWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let normalized = lines.map { line -> String in
            var out = line.replacingOccurrences(of: "\t", with: " ")
            while out.contains("  ") {
                out = out.replacingOccurrences(of: "  ", with: " ")
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        return normalized.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeDuplicateLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var lastNonEmpty: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            if let last = lastNonEmpty, last == trimmed {
                continue
            }
            out.append(trimmed)
            lastNonEmpty = trimmed
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureReadableParagraphs(_ text: String) -> String {
        if text.contains("\n") || text.count < 220 {
            return text
        }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            out.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                var j = text.index(after: i)
                var sawSpace = false
                while j < text.endIndex && text[j] == " " {
                    sawSpace = true
                    j = text.index(after: j)
                }
                if sawSpace, j < text.endIndex, text[j].isLetter || text[j].isNumber {
                    out.append("\n")
                }
            }
            i = text.index(after: i)
        }
        return out
    }

    private func containsCautionHint(in text: String) -> Bool {
        let lower = text.lowercased()
        let hints = [
            "не является", "это не", "обратитесь", "проконсультируйтесь",
            "врач", "доктор", "юрист", "финансов", "риск", "осторож"
        ]
        return hints.contains { lower.contains($0) }
    }
    
    private func relevanceScore(for memory: Memory, field: [Double]) -> Double {
        var score = Double(memory.links.count * 2) * memory.importance
        if memory.isPinned { score += 2.0 }
        let preferenceScore = ExperienceService.shared.preferenceScore(for: memory.content)
        score += preferenceScore * 0.6
        if !field.isEmpty,
           !memory.embedding.isEmpty,
           memory.embedding.count == field.count {
            score += cosineSimilarity(a: memory.embedding, b: field)
        }
        return score
    }

    private func recordAccess(for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        var didChange = false

        for id in ids {
            if let idx = memories.firstIndex(where: { $0.id == id }) {
                let m = memories[idx]
                if m.lastAccess < now {
                    memories[idx] = Memory(
                        id: m.id,
                        content: m.content,
                        timestamp: m.timestamp,
                        emotion: m.emotion,
                        emotionValence: m.emotionValence,
                        emotionIntensity: m.emotionIntensity,
                        embedding: m.embedding,
                        links: m.links,
                        importance: m.importance,
                        predictionScore: m.predictionScore,
                        predictionError: m.predictionError,
                        isIdentity: m.isIdentity,
                        isPinned: m.isPinned,
                        lastAccess: now,
                        isSelfReflection: m.isSelfReflection,
                        perspective: m.perspective
                    )
                    didChange = true
                }
            }
        }

        guard didChange else { return }
        let shouldSave: Bool
        if let last = lastAccessSaveAt {
            shouldSave = now.timeIntervalSince(last) >= accessSaveCooldown
        } else {
            shouldSave = true
        }
        if shouldSave {
            lastAccessSaveAt = now
            saveMemories()
        }
    }
    
    private func aggregateEmotions(memories: [Memory]) -> [String: Double] {
        var agg: [String: Double] = [:]
        for m in memories {
            agg[m.emotion, default: 0.0] += 1.0
        }
        let total = max(1.0, agg.values.reduce(0, +))
        for k in agg.keys {
            agg[k] = (agg[k] ?? 0.0) / total
        }
        return agg
    }

    private func emotionalDynamicsSummary(from recent: [Memory]) -> String {
        let sample = recent.prefix(8)
        guard !sample.isEmpty else { return "stable" }
        let avgValence = sample.map { $0.emotionValence }.reduce(0.0, +) / Double(sample.count)
        let avgIntensity = sample.map { $0.emotionIntensity }.reduce(0.0, +) / Double(sample.count)

        let tone: String
        if avgValence > 0.2 { tone = "positive trend" }
        else if avgValence < -0.2 { tone = "negative trend" }
        else { tone = "neutral trend" }

        let intensityTag: String
        if avgIntensity > 0.7 { intensityTag = "high intensity" }
        else if avgIntensity < 0.3 { intensityTag = "low intensity" }
        else { intensityTag = "medium intensity" }

        return "\(tone), \(intensityTag)"
    }

    func updateConversationSummary(fromUserText text: String) {
        Task { @MainActor in
            let compressed = compressMemory(text, maxWords: 18)
            let next = conversationSummary.isEmpty
                ? "U: \(compressed)"
                : conversationSummary + " | U: \(compressed)"
            conversationSummary = trimSummary(next, maxChars: 480)
        }
    }

    func updateUserProfile(fromUserText text: String) {
        Task { @MainActor in
            let tokens = extractConcepts(from: text)
            userProfile.update(with: tokens)
        }
    }

    func preferredDetailLevel(forUserText text: String) -> DetailLevel {
        let lower = text.lowercased()
        if lower.contains("почему") || lower.contains("объясни") || lower.contains("explain") || lower.contains("why") {
            return .detailed
        }
        if lower.count > 140 {
            return .detailed
        }
        if lower.count < 20 {
            return .brief
        }
        return .balanced
    }

    private func trimSummary(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.suffix(maxChars))
    }

    private func autonomousConsolidateIfIdle() async {
        let latestId: UUID? = await MainActor.run {
            let now = Date()
            if let last = lastAutonomousAt, now.timeIntervalSince(last) < autonomousInterval {
                return nil
            }
            return memories.sorted(by: { $0.timestamp > $1.timestamp }).first?.id
        }
        guard let id = latestId else { return }
        await autonomousConsolidate(memoryId: id)
    }

    private func autonomousConsolidate(memoryId: UUID) async {
        let memory: Memory? = await MainActor.run {
            let now = Date()
            if let last = lastAutonomousAt, now.timeIntervalSince(last) < autonomousInterval {
                return nil
            }
            return memories.first(where: { $0.id == memoryId })
        }
        guard let memory = memory else { return }

        let topic = selectAutonomousTopic(from: memory.content)
        guard !topic.isEmpty else { return }

        let snippets = await fetchAutonomousSnippets(for: topic)
        guard !snippets.isEmpty else { return }

        let unique = snippets.prefix(maxAutonomousSnippets)
        let combined = unique.joined(separator: "\n")
        let content = "[autonomous:\(topic)]\n\(combined)"

        await MainActor.run {
            self.addAutonomousMemory(content)
            self.lastAutonomousAt = Date()
        }
        await MainActor.run {
            let reflection = "I noticed a shift in my understanding around: \(topic)"

            let selfMemory = self.buildCognitiveLayer(
                for: reflection,
                importanceOverride: 1.3,
                isReflection: true,
                perspective: "self"
            )

            self.memories.append(selfMemory)
            self.saveMemories()
            self.rebuildGraph()
        }
    }

    private func selectAutonomousTopic(from text: String) -> String {
        let concepts = extractConcepts(from: text)
        if let top = concepts.first {
            return top
        }
        return String(text.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchAutonomousSnippets(for topic: String) async -> [String] {
        let sources: [any AutonomousMemorySource] = [
            WikipediaSource(),
            DuckDuckGoSource()
        ]
        var results: [String] = []
        for source in sources {
            let snippets = await source.fetchSnippets(for: topic)
            results.append(contentsOf: snippets.map { "[\(source.name)] \($0)" })
        }
        let cleaned = results
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned)
    }

    private func pruneMemoriesIfNeeded() {
        guard !memories.isEmpty else { return }
        let now = Date()
        let maxAge: TimeInterval = 60 * 60 * 24 * 30
        let halfLife: TimeInterval = 60 * 60 * 24 * 14
        let importanceFloor = 0.6
        let activationFloor = 0.25

        let originalCount = memories.count
        memories = memories.filter { memory in
            if memory.isIdentity || memory.isPinned { return true }
            let lastUse = max(memory.timestamp, memory.lastAccess)
            let age = now.timeIntervalSince(lastUse)
            let activation = echoGraph.activation(for: memory.id)

            if memory.importance >= 1.4 { return true }
            if activation >= 0.9 { return true }
            if age < maxAge && memory.importance >= importanceFloor && activation >= activationFloor {
                return true
            }

            let ageWeight = 1.0 - exp(-age / max(1.0, halfLife))
            let activationWeight = max(0.0, 1.0 - min(1.0, activation / max(activationFloor, 0.01)))
            let importanceWeight = max(0.0, 1.0 - min(1.0, memory.importance / max(importanceFloor, 0.01)))

            var pruneProbability = (ageWeight * 0.55) + (activationWeight * 0.3) + (importanceWeight * 0.15)
            if age < maxAge {
                pruneProbability *= 0.5
            }

            let roll = Double.random(in: 0...1)
            return roll >= pruneProbability
        }

        if memories.count != originalCount {
            saveMemories()
            rebuildGraph()
        }
    }

    func ingestExternalSnippets(_ snippets: [String], source: String, query: String, maxCount: Int = 2) {
        let cleaned = snippets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return }

        let scored = cleaned.map { snippet -> (snippet: String, confidence: Double, relevance: Double, quality: Double) in
            let rating = rateExternalSnippet(snippet: snippet, query: query)
            let quality = rating.confidence * rating.relevance
            return (snippet, rating.confidence, rating.relevance, quality)
        }
        .sorted { $0.quality > $1.quality }

        for item in scored.prefix(maxCount) {
            if item.quality < 0.25 { continue }
            let importanceOverride = min(1.6, max(0.5, 0.7 + (item.quality * 0.9)))
            addExternalMemory("[external:\(source)] \(item.snippet)", importanceOverride: importanceOverride)
        }
    }

    func rateExternalSnippet(snippet: String, query: String) -> (confidence: Double, relevance: Double) {
        let snippetEmbedding = generateEmbedding(from: snippet)
        let queryEmbedding = generateEmbedding(from: query)
        let relevance = cosineSimilarity(a: snippetEmbedding, b: queryEmbedding)

        let length = Double(snippet.count)
        var confidence = min(1.0, max(0.2, length / 360.0))
        if snippet.count < 40 { confidence *= 0.5 }
        if snippet.contains("...") { confidence *= 0.85 }
        confidence = min(1.0, max(0.0, confidence))

        return (confidence, min(1.0, max(0.0, relevance)))
    }

    private func addExternalMemory(_ content: String, importanceOverride: Double) {
        let enriched = buildCognitiveLayer(for: content, importanceOverride: importanceOverride)
        memories.append(enriched)
        saveMemories()
        updateGraph(for: enriched)
        echoGraph.activate(
            memoryId: enriched.id,
            embedding: enriched.embedding,
            importance: enriched.importance,
            strength: 0.4,
            isPersistent: enriched.isIdentity
        )
        saveGraph()
        saveEchoGraph()
    }
}


private enum MemoryProfile {
    case eco
    case beast
    case godmode

    static func detect() -> MemoryProfile {
        #if targetEnvironment(simulator)
        return .godmode
        #else
        let model = UIDevice.current.modelName.lowercased()
        if model.contains("iphone13") || model.contains("iphone 13") {
            return .eco
        } else if model.contains("iphone15") || model.contains("iphone 15") {
            return .beast
        } else if model.contains("ipad") || model.contains("mac") {
            return .godmode
        } else {
            return .beast
        }
        #endif
    }

    var autonomousInterval: TimeInterval {
        switch self {
        case .eco: return 900
        case .beast: return 600
        case .godmode: return 480
        }
    }

    var echoTickInterval: UInt64 {
        switch self {
        case .eco: return 100_000_000
        case .beast: return 50_000_000
        case .godmode: return 40_000_000
        }
    }

    var spontaneousTickInterval: UInt64 {
        switch self {
        case .eco: return 8_000_000_000
        case .beast: return 5_000_000_000
        case .godmode: return 4_000_000_000
        }
    }

    var compressedBudget: Int {
        switch self {
        case .eco: return 400
        case .beast: return 600
        case .godmode: return 800
        }
    }

    var rawBudget: Int {
        switch self {
        case .eco: return 800
        case .beast: return 1200
        case .godmode: return 1600
        }
    }
}

struct EmotionSignal {
    let label: String
    let valence: Double
    let intensity: Double
}

enum DetailLevel: String, Codable {
    case brief
    case balanced
    case detailed
}

struct UserProfile: Codable {
    private(set) var topTopics: [String] = []
    private(set) var lastUpdated: Date = Date()

    mutating func update(with tokens: [String]) {
        let merged = (topTopics + tokens).reduce(into: [String: Int]()) { acc, token in
            acc[token, default: 0] += 1
        }
        let sorted = merged.sorted { $0.value > $1.value }.map { $0.key }
        topTopics = Array(sorted.prefix(8))
        lastUpdated = Date()
    }

    func contextBlock() -> String {
        guard !topTopics.isEmpty else { return "" }
        let topics = topTopics.joined(separator: ", ")
        return "User Profile:\nTopics: \(topics)"
    }
}

enum MemoryNodeType: String, Codable {
    case memory
    case concept
    case emotion
    case identity
}

struct MemoryNode: Codable, Identifiable {
    let id: String
    let type: MemoryNodeType
    let label: String
}

struct MemoryEdge: Codable {
    let from: String
    let to: String
    let weight: Double
}

struct MemoryGraph: Codable {
    var nodes: [String: MemoryNode] = [:]
    var edges: [MemoryEdge] = []
    
    mutating func ensureNode(id: String, type: MemoryNodeType, label: String) {
        if nodes[id] == nil {
            nodes[id] = MemoryNode(id: id, type: type, label: label)
        }
    }
    
    mutating func link(from: String, to: String, weight: Double) {
        edges.append(MemoryEdge(from: from, to: to, weight: weight))
    }
}

struct CognitiveNode: Identifiable, Codable {
    let id: UUID
    var embedding: [Double]
    var activation: Double
    var lastUpdate: TimeInterval
    var createdAt: TimeInterval
    var importance: Double
    var isPersistent: Bool

    init(
        id: UUID,
        embedding: [Double],
        activation: Double,
        lastUpdate: TimeInterval,
        createdAt: TimeInterval,
        importance: Double,
        isPersistent: Bool = false
    ) {
        self.id = id
        self.embedding = embedding
        self.activation = activation
        self.lastUpdate = lastUpdate
        self.createdAt = createdAt
        self.importance = importance
        self.isPersistent = isPersistent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        embedding = (try? container.decode([Double].self, forKey: .embedding)) ?? []
        activation = (try? container.decode(Double.self, forKey: .activation)) ?? 0.0
        lastUpdate = (try? container.decode(Double.self, forKey: .lastUpdate)) ?? Date().timeIntervalSince1970
        createdAt = (try? container.decode(Double.self, forKey: .createdAt)) ?? lastUpdate
        importance = (try? container.decode(Double.self, forKey: .importance)) ?? 1.0
        isPersistent = (try? container.decode(Bool.self, forKey: .isPersistent)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(activation, forKey: .activation)
        try container.encode(lastUpdate, forKey: .lastUpdate)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(importance, forKey: .importance)
        try container.encode(isPersistent, forKey: .isPersistent)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case embedding
        case activation
        case lastUpdate
        case createdAt
        case importance
        case isPersistent
    }
}

struct CognitiveEdge: Codable {
    let from: UUID
    let to: UUID
    var weight: Double
}

struct CognitiveEchoGraphSnapshot: Codable {
    var nodes: [UUID: CognitiveNode]
    var edges: [CognitiveEdge]
}

final class CognitiveEchoGraph {
    private var nodes: [UUID: CognitiveNode] = [:]
    private var edges: [CognitiveEdge] = []

    var isEmpty: Bool {
        nodes.isEmpty
    }

    func register(memoryId: UUID, embedding: [Double], importance: Double, isPersistent: Bool = false) {
        guard !embedding.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if var existing = nodes[memoryId] {
            existing.embedding = embedding
            existing.importance = importance
            existing.lastUpdate = now
            existing.isPersistent = isPersistent
            nodes[memoryId] = existing
        } else {
            let node = CognitiveNode(
                id: memoryId,
                embedding: embedding,
                activation: 0.2,
                lastUpdate: now,
                createdAt: now,
                importance: importance,
                isPersistent: isPersistent
            )
            nodes[memoryId] = node
        }
        rebuildEdges(from: memoryId)
    }

    func activate(memoryId: UUID, embedding: [Double], importance: Double, strength: Double = 1.0, isPersistent: Bool = false) {
        guard !embedding.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var node = nodes[memoryId] ?? CognitiveNode(
            id: memoryId,
            embedding: embedding,
            activation: 0.0,
            lastUpdate: now,
            createdAt: now,
            importance: importance,
            isPersistent: isPersistent
        )
        node.embedding = embedding
        node.activation = min(2.0, node.activation + strength)
        node.lastUpdate = now
        node.importance = importance
        node.isPersistent = isPersistent
        nodes[memoryId] = node

        rebuildEdges(from: memoryId)
        propagate(from: memoryId, now: now)
    }

    func activate(embedding: [Double]) {
        let memoryId = UUID()
        activate(memoryId: memoryId, embedding: embedding, importance: 1.0, strength: 1.0)
    }
    
    private func propagate(from id: UUID, now: TimeInterval) {
        guard let source = nodes[id] else { return }
        for edge in edges where edge.from == id {
            guard var target = nodes[edge.to] else { continue }
            target.activation += source.activation * edge.weight
            target.lastUpdate = now
            nodes[edge.to] = target
        }
    }

    private func rebuildEdges(from id: UUID) {
        guard let source = nodes[id] else { return }
        edges.removeAll { $0.from == id }
        for (otherId, other) in nodes where otherId != id {
            let w = cosine(source.embedding, other.embedding)
            if w > 0.2 {
                edges.append(CognitiveEdge(from: id, to: otherId, weight: w))
            }
        }
    }
    
    func decay(now: TimeInterval = Date().timeIntervalSince1970) {
        for (id, var node) in nodes {
            if node.isPersistent { continue }
            let dt = now - node.lastUpdate
            let factor = exp(-dt * 0.1)
            node.activation *= factor
            node.lastUpdate = now
            nodes[id] = node
        }
    }
    
    func spontaneousActivation() {
        guard !nodes.isEmpty else { return }
        let values = Array(nodes.values)
        let count = min(3, values.count)
        let shuffled = values.shuffled().prefix(count)
        let now = Date().timeIntervalSince1970
        for var n in shuffled {
            n.activation += 0.1
            n.lastUpdate = now
            nodes[n.id] = n
        }
    }

    func spontaneousStep(now: TimeInterval = Date().timeIntervalSince1970) -> UUID? {
        guard !nodes.isEmpty else { return nil }

        let candidates = nodes.values
            .filter { $0.activation < 0.7 }
            .map { node -> (UUID, Double) in
                let age = now - node.lastUpdate
                let agePenalty = min(age / 3600.0, 1.0)
                let score = (node.activation * 0.6) + (node.importance * 0.6) - agePenalty
                return (node.id, score)
            }
            .sorted { $0.1 > $1.1 }

        guard let (id, _) = candidates.first else { return nil }

        activate(nodeId: id, strength: 0.6, now: now)

        if let node = nodes[id], node.activation > 0.9 {
            NotificationCenter.default.post(
                name: .memoryTriggered,
                object: self,
                userInfo: ["memoryID": id]
            )
            return id
        }

        return nil
    }

    private func activate(nodeId: UUID, strength: Double, now: TimeInterval) {
        guard var node = nodes[nodeId] else { return }
        node.activation = min(2.0, node.activation + strength)
        node.lastUpdate = now
        nodes[nodeId] = node
        propagate(from: nodeId, now: now)
    }
    
    func fieldVector() -> [Double] {
        guard let first = nodes.values.first else { return [] }
        let dim = first.embedding.count
        if dim == 0 { return [] }
        
        var acc = Array(repeating: 0.0, count: dim)
        var total = 0.0

        for node in nodes.values where node.activation > 0 {
            let limit = min(dim, node.embedding.count, acc.count)
            for i in 0..<limit {
                acc[i] += node.embedding[i] * node.activation
            }
            total += node.activation
        }

        if total > 0 {
            let limit = min(dim, acc.count)
            for i in 0..<limit {
                acc[i] /= total
            }
        }

        return acc
    }

    func activation(for memoryId: UUID) -> Double {
        nodes[memoryId]?.activation ?? 0.0
    }

    func averageActivation(excludingPersistent: Bool = false) -> Double {
        let values = nodes.values.filter { node in
            excludingPersistent ? !node.isPersistent : true
        }
        guard !values.isEmpty else { return 0.0 }
        let total = values.reduce(0.0) { $0 + $1.activation }
        return total / Double(values.count)
    }

    func hasNode(_ id: UUID) -> Bool {
        nodes[id] != nil
    }
    
    func snapshot() -> CognitiveEchoGraphSnapshot {
        CognitiveEchoGraphSnapshot(nodes: nodes, edges: edges)
    }
    
    func load(from snapshot: CognitiveEchoGraphSnapshot) {
        nodes = snapshot.nodes
        edges = snapshot.edges
    }
    
    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
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
}
