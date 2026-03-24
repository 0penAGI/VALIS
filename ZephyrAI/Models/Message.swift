import Foundation

enum Role: String, Codable {
    case user
    case assistant
    case system
}

struct MessageImageAttachment: Codable, Equatable {
    let id: UUID
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }

    var displayName: String {
        filename
    }
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    var thinkContent: String?
    var imageAttachment: MessageImageAttachment?
    let timestamp: Date
    
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        thinkContent: String? = nil,
        imageAttachment: MessageImageAttachment? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinkContent = thinkContent
        self.imageAttachment = imageAttachment
        self.timestamp = timestamp
    }
}
