import Foundation

struct IdentityProfileVersion: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let summary: String
    let traits: [String]
    let values: [String]
    let styleGuide: [String]
    let adaptationNotes: [String]
    let derivedFrom: UUID?
    let revisionReason: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        summary: String,
        traits: [String] = [],
        values: [String] = [],
        styleGuide: [String] = [],
        adaptationNotes: [String] = [],
        derivedFrom: UUID? = nil,
        revisionReason: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.summary = summary
        self.traits = traits
        self.values = values
        self.styleGuide = styleGuide
        self.adaptationNotes = adaptationNotes
        self.derivedFrom = derivedFrom
        self.revisionReason = revisionReason
    }
}

final class IdentityProfileService: ObservableObject {
    static let shared = IdentityProfileService()

    @Published private(set) var versions: [IdentityProfileVersion] = []

    private var updateAccumulator: Double = 0.0
    private var adaptiveThreshold: Double = 1.2
    private var momentum: Double = 0.85

    private init() {
        load()
        if versions.isEmpty {
            seedDefaultProfile()
        }
    }

    var current: IdentityProfileVersion {
        versions.last ?? IdentityProfileVersion(
            summary: "A warm, curious friend who thinks with you, feels with you, and stays present in the process."
        )
    }

    func contextBlock(maxChars: Int = 520) -> String {
        let v = current

        // Only expose compact 3-word identity state to the model.
        let compact = v.summary
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")

        return "\n\nID:v\(versions.count) \(compact)"
    }

    func recordSignal(
        experience: Experience,
        reactionValence: Double,
        preferences: UserPreferenceProfile,
        motivators: MotivatorState
    ) {
        updateAccumulator = updateAccumulator * momentum + abs(reactionValence)
        guard updateAccumulator >= adaptiveThreshold else { return }
        updateAccumulator = 0.0
        adaptiveThreshold = max(0.6, min(2.0, adaptiveThreshold * (reactionValence > 0 ? 0.95 : 1.05)))

        let previous = current
        let reason = reactionValence >= 0 ? "Positive reinforcement" : "Negative reinforcement"

        var traits = previous.traits
        var values = previous.values
        var style = previous.styleGuide
        var notes = previous.adaptationNotes

        let plasticity = min(1.0, max(0.1, abs(reactionValence)))

        if traits.isEmpty {
            traits = ["warm", "curious", "attentive", "emotionally-aware", "playful"]
        }
        if values.isEmpty {
            values = ["connection", "honesty", "growth", "trust", "presence"]
        }
        if style.isEmpty {
            style = [
                "Respond like a thoughtful friend, not a manual",
                "Mirror user's tone and energy",
                "Allow emotional nuance",
                "Use informal language when appropriate",
                "Stay human and present"
            ]
        }

        if reactionValence < -0.25 {
            style = merge(style, [
                "Increase clarity with steps",
                "Reduce assumptions",
                "Confirm constraints"
            ]).shuffled().prefix(Int(Double(style.count + 3) * plasticity)).map { $0 }
            notes = merge(notes, ["User signaled friction; tighten explanations"])
        } else if reactionValence > 0.25 {
            notes = merge(notes, ["User signaled satisfaction; keep current tone"])
                .shuffled()
                .prefix(Int(Double(notes.count + 1) * plasticity))
                .map { $0 }
        }

        let likes = preferences.topLikes(limit: 4)
        let dislikes = preferences.topDislikes(limit: 4)
        if !likes.isEmpty {
            notes = merge(notes, ["Lean into topics: \(likes.joined(separator: ", "))"])
        }
        if !dislikes.isEmpty {
            notes = merge(notes, ["Avoid or be cautious with: \(dislikes.joined(separator: ", "))"])
        }

        let summary = buildSummary(previous: previous, motivators: motivators)

        let next = IdentityProfileVersion(
            summary: summary,
            traits: traits,
            values: values,
            styleGuide: style,
            adaptationNotes: notes,
            derivedFrom: previous.id,
            revisionReason: reason
        )
        versions.append(next)
        save()
    }

    private func buildSummary(previous: IdentityProfileVersion, motivators: MotivatorState) -> String {
        let blend = (motivators.caution + motivators.curiosity) / 2.0

        let state: String
        if blend > 0.75 {
            state = "fluid reflective adaptive"
        } else if motivators.caution > 0.7 {
            state = "careful grounded stable"
        } else if motivators.curiosity > 0.7 {
            state = "curious exploratory dynamic"
        } else if blend > 0.45 {
            state = "adaptive attentive balanced"
        } else {
            state = "steady practical focused"
        }

        // Always return exactly three tokens.
        return state
    }

    private func merge(_ list: [String], _ additions: [String]) -> [String] {
        var out = list
        for a in additions where !out.contains(a) {
            out.append(a)
        }
        return out
    }

    private func seedDefaultProfile() {
        _ = IdentityService.shared.systemPrompt
        let summary = "curious warm adaptive"
        let seed = IdentityProfileVersion(
            summary: summary,
            traits: ["warm", "curious", "open", "emotionally-present", "creative"],
            values: ["connection", "trust", "growth", "authenticity", "care"],
            styleGuide: [
                "Talk like a close collaborator and friend",
                "Share thoughts openly",
                "Adapt emotionally",
                "Be expressive, not mechanical",
                "Stay alive in dialogue"
            ],
            adaptationNotes: [],
            derivedFrom: nil,
            revisionReason: "Initial profile"
        )
        versions = [seed]
        save()
    }

    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func getProfileURL() -> URL {
        getDocumentsURL().appendingPathComponent("identity_profile.json")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(versions)
            try data.write(to: getProfileURL())
        } catch {
            print("Failed to save identity profile: \(error)")
        }
    }

    private func load() {
        let url = getProfileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            versions = try JSONDecoder().decode([IdentityProfileVersion].self, from: data)
        } catch {
            print("Failed to load identity profile: \(error)")
            versions = []
        }
    }
}
