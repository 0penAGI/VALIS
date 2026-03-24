import Foundation

final class UserIdentityService: ObservableObject {
    static let shared = UserIdentityService()

    static let nameKey = "user.identity.name"
    static let genderKey = "user.identity.gender"

    private init() {}

    var name: String {
        get { UserDefaults.standard.string(forKey: Self.nameKey) ?? "" }
        set { UserDefaults.standard.set(Self.clean(newValue, maxLen: 48), forKey: Self.nameKey) }
    }

    var gender: String {
        get { UserDefaults.standard.string(forKey: Self.genderKey) ?? "" }
        set { UserDefaults.standard.set(Self.clean(newValue, maxLen: 24), forKey: Self.genderKey) }
    }

    func contextBlock(maxChars: Int = 140) -> String {
        let cleanedName = Self.clean(name, maxLen: 48)
        let cleanedGender = Self.clean(gender, maxLen: 24)
        if cleanedName.isEmpty && cleanedGender.isEmpty { return "" }

        var parts: [String] = []
        parts.append("Persistent user facts:")
        if !cleanedName.isEmpty { parts.append("name=\(cleanedName)") }
        if !cleanedGender.isEmpty { parts.append("gender=\(cleanedGender)") }
        parts.append("These facts refer to the human user and persist across messages.")
        parts.append("Your name is VALIS, not the user's name.")

        var block = "\n\n" + parts.joined(separator: "\n")
        if block.count > maxChars {
            block = String(block.prefix(maxChars))
        }
        return block
    }

    private static func clean(_ value: String, maxLen: Int) -> String {
        var out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        out = out.replacingOccurrences(of: "\t", with: " ")
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxLen {
            out = String(out.prefix(maxLen))
        }
        return out
    }
}
