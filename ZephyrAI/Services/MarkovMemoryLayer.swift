import Foundation

@MainActor
final class MarkovMemoryLayer {
    static let shared = MarkovMemoryLayer()

    private struct Snapshot: Codable {
        var transitions: [String: [String: Double]]
        var lastState: String?
        var updatedAt: Date
    }

    private var transitions: [String: [String: Double]] = [:]
    private var lastState: String?
    private var lastSavedAt: Date?

    private let maxStates = 256
    private let maxOutgoing = 24
    private let saveCooldown: TimeInterval = 12

    private init() {
        load()
    }

    func observeTurn(userText: String) {
        let state = dominantState(from: userText)
        guard !state.isEmpty else { return }

        if let prev = lastState, prev != state {
            transitions[prev, default: [:]][state, default: 0.0] += 1.0
            pruneIfNeeded()
            saveIfNeeded()
        }

        lastState = state
    }

    func predictNextStates(from userText: String, topK: Int = 4) -> [String] {
        let state = dominantState(from: userText)
        return predictNextStates(fromState: state, topK: topK)
    }

    func predictNextStates(fromState state: String, topK: Int = 4) -> [String] {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let next = transitions[trimmed] ?? [:]
        guard !next.isEmpty else { return [] }
        return next
            .sorted { $0.value > $1.value }
            .prefix(max(1, topK))
            .map { $0.key }
    }

    private func dominantState(from text: String) -> String {
        let tokens = tokenize(text: text)
        guard !tokens.isEmpty else { return "" }
        let counts = tokens.reduce(into: [String: Int]()) { acc, token in
            acc[token, default: 0] += 1
        }
        return counts.sorted { (a, b) in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }.first?.key ?? ""
    }

    private func tokenize(text: String) -> [String] {
        let seps = CharacterSet.alphanumerics.inverted
        let raw = text
            .lowercased()
            .components(separatedBy: seps)
            .filter { !$0.isEmpty }

        let stop: Set<String> = [
            "the","and","a","an","to","in","on","for","of","with","at","by","from","or","as",
            "is","are","was","were","be","been","being","it","this","that","these","those",
            "i","you","he","she","we","they","me","my","your","his","her","our","their",
            "что","как","почему","зачем","когда","где","кто","я","ты","вы","мы","они","она","он",
            "это","эта","эти","тот","та","те","в","на","и","или","для","по","от","с","со","к","у"
        ]

        return raw.filter { $0.count > 3 && !stop.contains($0) }
    }

    private func pruneIfNeeded() {
        if transitions.count > maxStates {
            let sorted = transitions.sorted { $0.value.count > $1.value.count }
            transitions = Dictionary(uniqueKeysWithValues: sorted.prefix(maxStates).map { ($0.key, $0.value) })
        }
        for (from, outs) in transitions {
            if outs.count > maxOutgoing {
                let pruned = outs.sorted { $0.value > $1.value }.prefix(maxOutgoing)
                transitions[from] = Dictionary(uniqueKeysWithValues: pruned.map { ($0.key, $0.value) })
            }
        }
    }

    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func getSnapshotURL() -> URL {
        getDocumentsURL().appendingPathComponent("markov_transitions.json")
    }

    private func saveIfNeeded() {
        let now = Date()
        if let lastSavedAt, now.timeIntervalSince(lastSavedAt) < saveCooldown {
            return
        }
        lastSavedAt = now
        save()
    }

    private func save() {
        let snapshot = Snapshot(transitions: transitions, lastState: lastState, updatedAt: Date())
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: getSnapshotURL())
        } catch {
            print("Failed to save Markov transitions: \(error)")
        }
    }

    private func load() {
        let url = getSnapshotURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            transitions = snapshot.transitions
            lastState = snapshot.lastState
        } catch {
            print("Failed to load Markov transitions: \(error)")
            transitions = [:]
            lastState = nil
        }
    }
}
