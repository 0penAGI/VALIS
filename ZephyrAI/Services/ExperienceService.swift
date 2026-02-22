import Foundation

struct Experience: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let userMessageId: UUID?
    let assistantMessageId: UUID?
    let userText: String
    let assistantText: String
    let outcome: String
    let reflection: String
    let userReaction: String?
    let reactionValence: Double

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        userMessageId: UUID? = nil,
        assistantMessageId: UUID? = nil,
        userText: String,
        assistantText: String,
        outcome: String,
        reflection: String,
        userReaction: String? = nil,
        reactionValence: Double = 0.0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userMessageId = userMessageId
        self.assistantMessageId = assistantMessageId
        self.userText = userText
        self.assistantText = assistantText
        self.outcome = outcome
        self.reflection = reflection
        self.userReaction = userReaction
        self.reactionValence = reactionValence
    }
}

struct UserPreferenceProfile: Codable {
    var topicScores: [String: Double] = [:]

    mutating func update(topics: [String], delta: Double) {
        guard !topics.isEmpty, delta != 0 else { return }
        for t in topics {
            let current = topicScores[t] ?? 0.0
            let next = max(-1.0, min(1.0, current + delta))
            topicScores[t] = next
        }
    }

    func topLikes(limit: Int = 5) -> [String] {
        topicScores
            .filter { $0.value > 0.35 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    func topDislikes(limit: Int = 5) -> [String] {
        topicScores
            .filter { $0.value < -0.35 }
            .sorted { $0.value < $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    func contextBlock(maxChars: Int = 420) -> String {
        let likes = topLikes()
        let dislikes = topDislikes()
        if likes.isEmpty && dislikes.isEmpty { return "" }

        var lines: [String] = []
        if !likes.isEmpty {
            lines.append("Likes: " + likes.joined(separator: ", "))
        }
        if !dislikes.isEmpty {
            lines.append("Dislikes: " + dislikes.joined(separator: ", "))
        }
        let block = "User Preferences:\n" + lines.joined(separator: "\n")
        if block.count <= maxChars { return "\n\n" + block }
        return "\n\n" + String(block.prefix(maxChars))
    }
}

final class ExperienceService: ObservableObject {
    static let shared = ExperienceService()

    @Published private(set) var experiences: [Experience] = []
    @Published private(set) var preferences: UserPreferenceProfile = UserPreferenceProfile()
    private var pendingReactionId: UUID?

    private init() {
        loadExperiences()
        loadPreferences()
    }

    func recordExperience(
        userMessageId: UUID?,
        assistantMessageId: UUID?,
        userText: String,
        assistantText: String
    ) {
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { return }

        let outcome = estimateOutcome(userText: trimmedUser, assistantText: trimmedAssistant)
        let reflection = generateReflection(userText: trimmedUser, assistantText: trimmedAssistant, outcome: outcome)

        let exp = Experience(
            userMessageId: userMessageId,
            assistantMessageId: assistantMessageId,
            userText: trimmedUser,
            assistantText: trimmedAssistant,
            outcome: outcome,
            reflection: reflection
        )
        experiences.append(exp)
        pendingReactionId = exp.id
        saveExperiences()
    }

    @discardableResult
    func applyUserReaction(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let id = pendingReactionId,
              let idx = experiences.firstIndex(where: { $0.id == id }) else { return nil }

        let valence = estimateValence(for: trimmed)
        applyReaction(toIndex: idx, reactionText: trimmed, valence: valence)
        pendingReactionId = nil
        return valence
    }

    func applyReaction(forAssistantMessageId messageId: UUID, isLike: Bool) {
        guard let idx = experiences.lastIndex(where: { $0.assistantMessageId == messageId }) else { return }
        let reactionText = isLike ? "like" : "dislike"
        let valence = isLike ? 1.0 : -1.0
        applyReaction(toIndex: idx, reactionText: reactionText, valence: valence)
        if let pending = pendingReactionId, experiences[idx].id == pending {
            pendingReactionId = nil
        }
    }

    func contextBlock(for prompt: String, maxChars: Int = 600) -> String {
        guard !experiences.isEmpty, maxChars > 0 else { return "" }

        let recent = experiences.suffix(6)
        let lessons = recent
            .map { $0.reflection }
            .filter { !$0.isEmpty }
            .suffix(3)

        let outcomes = recent
            .map { $0.outcome }
            .filter { !$0.isEmpty }
            .suffix(2)

        var parts: [String] = []
        if !lessons.isEmpty {
            let lines = lessons.map { "- \($0)" }.joined(separator: "\n")
            parts.append("Experience Lessons:\n\(lines)")
        }
        if !outcomes.isEmpty {
            let lines = outcomes.map { "- \($0)" }.joined(separator: "\n")
            parts.append("Recent Outcomes:\n\(lines)")
        }

        let block = parts.joined(separator: "\n\n")
        if block.count <= maxChars {
            return "\n\n\(block)" + preferences.contextBlock()
        }
        let trimmed = String(block.prefix(maxChars))
        return "\n\n" + trimmed + preferences.contextBlock()
    }

    // MARK: - Heuristics

    private func estimateOutcome(userText: String, assistantText: String) -> String {
        let lower = assistantText.lowercased()
        if lower.contains("i don't know") || lower.contains("не знаю") {
            return "Answer uncertain; needs better grounding"
        }
        if assistantText.count < 60 {
            return "Answer too short; likely missing detail"
        }
        if assistantText.contains("?") {
            return "Asked clarifying question; waiting on user"
        }
        return "Delivered a full response; validate usefulness"
    }

    private func generateReflection(userText: String, assistantText: String, outcome: String) -> String {
        let lower = userText.lowercased()
        if lower.contains("почему") || lower.contains("explain") || lower.contains("why") {
            return "When user asks why, respond with cause + steps + example"
        }
        if assistantText.count < 60 {
            return "Increase detail level if user seems confused"
        }
        if outcome.contains("uncertain") {
            return "If unsure, ask for context or cite limits"
        }
        return "Keep response structured and actionable"
    }

    private func estimateValence(for text: String) -> Double {
        let lower = text.lowercased()
        let positive = ["спасибо", "круто", "ок", "понял", "супер", "nice", "thanks", "good", "great"]
        let negative = ["бесит", "плохо", "не то", "ужас", "ненавижу", "wtf", "bad", "wrong", "awful"]

        var score = 0.0
        for p in positive where lower.contains(p) { score += 0.6 }
        for n in negative where lower.contains(n) { score -= 0.7 }
        return max(-1.0, min(1.0, score))
    }

    private func applyReaction(toIndex idx: Int, reactionText: String, valence: Double) {
        let current = experiences[idx]
        let updated = Experience(
            id: current.id,
            timestamp: current.timestamp,
            userMessageId: current.userMessageId,
            assistantMessageId: current.assistantMessageId,
            userText: current.userText,
            assistantText: current.assistantText,
            outcome: current.outcome,
            reflection: current.reflection,
            userReaction: reactionText,
            reactionValence: valence
        )
        experiences[idx] = updated

        let topics = extractConcepts(from: current.userText + " " + current.assistantText)
        let delta = max(-0.6, min(0.6, valence * 0.4))
        preferences.update(topics: topics, delta: delta)
        MotivationService.shared.updateForReaction(valence: valence)

        saveExperiences()
        savePreferences()
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
            "i","you","he","she","we","they","me","my","your","his","her","our","their",
            "это","как","что","когда","почему","зачем","и","но","а","или","да","нет"
        ]
        let filtered = tokens.filter { $0.count > 3 && !stop.contains($0) }
        return Array(Set(filtered)).prefix(24).map { $0 }
    }

    // MARK: - Persistence

    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func getExperiencesURL() -> URL {
        getDocumentsURL().appendingPathComponent("experiences.json")
    }

    private func getPreferencesURL() -> URL {
        getDocumentsURL().appendingPathComponent("user_preferences.json")
    }

    private func saveExperiences() {
        do {
            let data = try JSONEncoder().encode(experiences)
            try data.write(to: getExperiencesURL())
        } catch {
            print("Failed to save experiences: \(error)")
        }
    }

    private func loadExperiences() {
        let url = getExperiencesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            experiences = try JSONDecoder().decode([Experience].self, from: data)
        } catch {
            print("Failed to load experiences: \(error)")
            experiences = []
        }
    }

    private func savePreferences() {
        do {
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: getPreferencesURL())
        } catch {
            print("Failed to save preferences: \(error)")
        }
    }

    private func loadPreferences() {
        let url = getPreferencesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            preferences = try JSONDecoder().decode(UserPreferenceProfile.self, from: data)
        } catch {
            print("Failed to load preferences: \(error)")
            preferences = UserPreferenceProfile()
        }
    }
}
