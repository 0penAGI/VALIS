import Foundation

enum Role: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    var thinkContent: String?
    let timestamp: Date
    
    init(id: UUID = UUID(), role: Role, content: String, thinkContent: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.thinkContent = thinkContent
        self.timestamp = timestamp
    }
}
