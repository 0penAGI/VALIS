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
    private let updateThreshold: Double = 1.2

    private init() {
        load()
        if versions.isEmpty {
            seedDefaultProfile()
        }
    }

    var current: IdentityProfileVersion {
        versions.last ?? IdentityProfileVersion(summary: "A friend that values clarity and empathy.")
    }

    func contextBlock(maxChars: Int = 520) -> String {
        let v = current
        var lines: [String] = []
        lines.append("Identity Profile (v\(versions.count)):")
        lines.append("Summary: \(v.summary)")
        if !v.traits.isEmpty {
            lines.append("Traits: \(v.traits.joined(separator: ", "))")
        }
        if !v.values.isEmpty {
            lines.append("Values: \(v.values.joined(separator: ", "))")
        }
        if !v.styleGuide.isEmpty {
            lines.append("Style: \(v.styleGuide.joined(separator: "; "))")
        }
        if !v.adaptationNotes.isEmpty {
            lines.append("Adaptation: \(v.adaptationNotes.joined(separator: "; "))")
        }
        if !v.revisionReason.isEmpty {
            lines.append("Revision: \(v.revisionReason)")
        }

        let block = lines.joined(separator: "\n")
        if block.count <= maxChars {
            return "\n\n" + block
        }
        return "\n\n" + String(block.prefix(maxChars))
    }

    func recordSignal(
        experience: Experience,
        reactionValence: Double,
        preferences: UserPreferenceProfile,
        motivators: MotivatorState
    ) {
        updateAccumulator += abs(reactionValence)
        guard updateAccumulator >= updateThreshold else { return }
        updateAccumulator = 0.0

        let previous = current
        let reason = reactionValence >= 0 ? "Positive reinforcement" : "Negative reinforcement"

        var traits = previous.traits
        var values = previous.values
        var style = previous.styleGuide
        var notes = previous.adaptationNotes

        if traits.isEmpty {
            traits = ["calm", "direct", "curious"]
        }
        if values.isEmpty {
            values = ["clarity", "helpfulness", "honesty"]
        }
        if style.isEmpty {
            style = ["Use concise steps", "Make reasonable assumptions", "Answer directly without follow-ups"]
        }

        if reactionValence < -0.25 {
            style = merge(style, ["Increase clarity with steps", "Reduce assumptions", "Confirm constraints"])
            notes = merge(notes, ["User signaled friction; tighten explanations"])
        } else if reactionValence > 0.25 {
            notes = merge(notes, ["User signaled satisfaction; keep current tone"])
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
        let tone: String
        if motivators.caution > 0.7 {
            tone = "careful and grounded"
        } else if motivators.curiosity > 0.7 {
            tone = "curious and exploratory"
        } else {
            tone = "steady and practical"
        }
        return "A \(tone) friend that prioritizes clarity, usefulness, and respectful collaboration."
    }

    private func merge(_ list: [String], _ additions: [String]) -> [String] {
        var out = list
        for a in additions where !out.contains(a) {
            out.append(a)
        }
        return out
    }

    private func seedDefaultProfile() {
        let base = IdentityService.shared.systemPrompt
        let summaryLine = base.split(separator: "\n").first.map { String($0) }
        let summary = summaryLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "A calm, helpful assistant that values clarity and empathy."
        let seed = IdentityProfileVersion(
            summary: summary,
            traits: ["calm", "direct", "helpful"],
            values: ["clarity", "usefulness", "honesty"],
            styleGuide: ["Use concise steps", "Assume context when possible", "Avoid unnecessary questions"],
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
