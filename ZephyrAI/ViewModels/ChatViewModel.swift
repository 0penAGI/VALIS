import Foundation
import SwiftUI
import AVFoundation
import Speech
import Combine
import UIKit

struct ChatArtifactMemory: Codable, Equatable {
    let type: String
    let title: String?
    let payload: String
    let updatedAt: Date
}

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var isAutoTitle: Bool
    var isPinned: Bool
    var messages: [Message]
    var rememberedArtifact: ChatArtifactMemory?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        isAutoTitle: Bool = true,
        isPinned: Bool = false,
        messages: [Message] = [],
        rememberedArtifact: ChatArtifactMemory? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isAutoTitle = isAutoTitle
        self.isPinned = isPinned
        self.messages = messages
        self.rememberedArtifact = rememberedArtifact
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private enum PromptMode {
    case direct
    case reflective
    case creative
    case code
    case artifact
    case architecture
}

private struct PromptFragment {
    let priority: Int
    let text: String
    let maxChars: Int?
}

private struct ConversationAttentionFocus {
    let summary: String
    let inheritedMode: PromptMode
    let confidence: Double
    let isAssistantContinuation: Bool
}

@MainActor
final class ChatSessionStore: ObservableObject {
    static let shared = ChatSessionStore()

    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var currentChatID: UUID = UUID()

    private let currentChatDefaultsKey = "chat.currentSessionID"

    private init() {
        load()
    }

    var currentChat: ChatSession? {
        chats.first(where: { $0.id == currentChatID })
    }

    func createChat() -> UUID {
        let newChat = ChatSession(title: nextDefaultTitle())
        chats.insert(newChat, at: 0)
        currentChatID = newChat.id
        save()
        return newChat.id
    }

    func selectChat(_ id: UUID) {
        guard chats.contains(where: { $0.id == id }) else { return }
        currentChatID = id
        save()
    }

    func updateCurrentChat(messages: [Message], rememberedArtifact: ChatArtifactMemory?, suggestedTitle: String?) {
        guard let index = chats.firstIndex(where: { $0.id == currentChatID }) else { return }
        chats[index].messages = messages
        chats[index].rememberedArtifact = rememberedArtifact
        chats[index].updatedAt = Date()

        if let suggestedTitle,
           !suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           chats[index].isAutoTitle {
            chats[index].title = suggestedTitle
        }

        reorderChatsKeepingCurrentFirst()
        save()
    }

    func renameChat(_ id: UUID, title: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chats[index].title = trimmed
        chats[index].isAutoTitle = false
        chats[index].updatedAt = Date()
        reorderChatsKeepingCurrentFirst()
        save()
    }

    func togglePinned(_ id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].isPinned.toggle()
        chats[index].updatedAt = Date()
        reorderChatsKeepingCurrentFirst()
        save()
    }

    func deleteChat(_ id: UUID) {
        guard chats.count > 1 else {
            if let index = chats.firstIndex(where: { $0.id == id }) {
                chats[index].messages = []
                chats[index].rememberedArtifact = nil
                chats[index].title = "Chat 1"
                chats[index].isAutoTitle = true
                chats[index].isPinned = false
                chats[index].updatedAt = Date()
                currentChatID = chats[index].id
                save()
            }
            return
        }

        chats.removeAll { $0.id == id }
        if currentChatID == id {
            currentChatID = chats.first?.id ?? UUID()
        }
        reorderChatsKeepingCurrentFirst()
        save()
    }

    private func reorderChatsKeepingCurrentFirst() {
        chats.sort { lhs, rhs in
            if lhs.id == currentChatID { return true }
            if rhs.id == currentChatID { return false }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func nextDefaultTitle() -> String {
        let used = Set(chats.map(\.title))
        var index = 1
        while used.contains("Chat \(index)") {
            index += 1
        }
        return "Chat \(index)"
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? decoder.decode([ChatSession].self, from: data),
           !decoded.isEmpty {
            chats = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            chats = [ChatSession(title: "Chat 1")]
        }

        let savedID = UserDefaults.standard.string(forKey: currentChatDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        if let savedID, chats.contains(where: { $0.id == savedID }) {
            currentChatID = savedID
        } else {
            currentChatID = chats[0].id
        }

        reorderChatsKeepingCurrentFirst()
        save()
    }

    private var storageURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("chats.json")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(chats)
            try data.write(to: storageURL, options: .atomic)
            UserDefaults.standard.set(currentChatID.uuidString, forKey: currentChatDefaultsKey)
        } catch {
            print("Failed to save chats: \(error)")
        }
    }
}

@MainActor
class ChatViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = ChatViewModel()

    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var pendingImageAttachment: MessageImageAttachment?
    @Published var isInteracting: Bool = false
    @Published var status: String = "Starting Models"
    @Published var currentThink: String = ""
    @Published var currentThinkingMessageId: UUID?
    @Published var editingUserMessageId: UUID?
    @Published private(set) var polishingArtifactMessageIDs: Set<UUID> = []
    private var hasUserInteracted: Bool = false
    
    private var generationTask: Task<Void, Never>?
    private var artifactPolishTasks: [UUID: Task<Void, Never>] = [:]
    private var activeGenerationId: UUID?
    private var didUserRequestStopGeneration: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var lastSpontaneousAt: Date?
    private let spontaneousCooldown: TimeInterval = 600
    private let siriPendingPromptKey = "siri.pendingPrompt"
    private let siriPendingPromptTimestampKey = "siri.pendingPromptTimestamp"
    private let siriPromptMaxAge: TimeInterval = 180
    
    private let llmService = LLMService()
    private let memoryService = MemoryService.shared
    private let actionService = ActionService.shared
    private let codeCoachService = CodeCoachService.shared
    private let identityService = IdentityService.shared
    private let identityProfileService = IdentityProfileService.shared
    private let experienceService = ExperienceService.shared
    private let motivationService = MotivationService.shared
    private let emotionService = EmotionService.shared
    private let visionAttachmentService = VisionAttachmentService.shared
    private let responseDriftService = ResponseDriftService.shared
    private var lastReflectionHash: Int?
    private var lastDriftSignal: ResponseDriftSignal?
    private var statusClearTask: Task<Void, Never>?
    private var pendingUserFeedbackValence: Double?
    private var turnsSinceSelfReflection: Int = 0
    private let selfReflectionIntervalTurns: Int = 8
    private let maxArtifactContextChars = 24_000
    private let chatStore = ChatSessionStore.shared
    private var rememberedArtifact: ChatArtifactMemory? {
        didSet { persistCurrentChatState() }
    }

    private override init() {
        super.init()
        loadCurrentChatFromStore()
        setup()
        observeMemoryTriggers()
        observeSiriPromptQueue()
        observeChatPersistence()
    }
    
    func setup() {
        llmService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                self.status = value
                self.scheduleStatusAutoClearIfNeeded(for: value)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .llmModelDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.llmService.reloadModel() }
            }
            .store(in: &cancellables)

        Task {
            await llmService.loadModel()
            // Remove automatic initial message; welcome is now handled by ChatView overlay
        }
    }

    private func observeChatPersistence() {
        $messages
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.persistCurrentChatState()
            }
            .store(in: &cancellables)
    }

    var chats: [ChatSession] {
        chatStore.chats
    }

    var currentChatID: UUID {
        chatStore.currentChatID
    }

    func createNewChat() {
        persistCurrentChatState()
        resetTransientChatState()
        _ = chatStore.createChat()
        loadCurrentChatFromStore()
    }

    func switchToChat(_ id: UUID) {
        guard id != chatStore.currentChatID else { return }
        persistCurrentChatState()
        resetTransientChatState()
        chatStore.selectChat(id)
        loadCurrentChatFromStore()
    }

    func renameChat(_ id: UUID, title: String) {
        chatStore.renameChat(id, title: title)
        loadCurrentChatFromStore()
    }

    func isPolishingArtifact(for messageID: UUID) -> Bool {
        polishingArtifactMessageIDs.contains(messageID)
    }

    func togglePinnedChat(_ id: UUID) {
        chatStore.togglePinned(id)
        loadCurrentChatFromStore()
    }

    func deleteChat(_ id: UUID) {
        let deletingCurrentChat = id == chatStore.currentChatID
        if deletingCurrentChat {
            resetTransientChatState()
        } else {
            persistCurrentChatState()
        }
        chatStore.deleteChat(id)
        loadCurrentChatFromStore()
    }

    private func resetTransientChatState() {
        prepareForNewGeneration()
        cancelArtifactPolishTasks()
        polishingArtifactMessageIDs.removeAll()
        isInteracting = false
        inputText = ""
        pendingImageAttachment = nil
        editingUserMessageId = nil
        pendingUserFeedbackValence = nil
    }

    private func loadCurrentChatFromStore() {
        guard let chat = chatStore.currentChat else { return }
        messages = chat.messages
        rememberedArtifact = chat.rememberedArtifact
    }

    private func persistCurrentChatState() {
        let title = suggestedChatTitle(from: messages)
        chatStore.updateCurrentChat(messages: messages, rememberedArtifact: rememberedArtifact, suggestedTitle: title)
    }

    private func suggestedChatTitle(from messages: [Message]) -> String? {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else { return nil }
        let normalized = firstUserMessage.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty, firstUserMessage.imageAttachment != nil {
            return "Image chat"
        }
        guard !normalized.isEmpty else { return nil }
        if normalized.count <= 32 { return normalized }
        return String(normalized.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private var attachmentsDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("image-attachments", isDirectory: true)
    }

    private func normalizedAttachmentData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 2048
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }

    private func persistAttachment(from image: UIImage, prefix: String = "img") -> MessageImageAttachment? {
        guard let normalized = normalizedAttachmentData(from: image) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: attachmentsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let filename = "\(prefix)-\(UUID().uuidString).jpg"
            let fileURL = attachmentsDirectoryURL.appendingPathComponent(filename)
            try normalized.write(to: fileURL, options: .atomic)
            return MessageImageAttachment(
                filename: filename,
                pixelWidth: Int(image.size.width),
                pixelHeight: Int(image.size.height)
            )
        } catch {
            print("Failed to persist image attachment: \(error)")
            return nil
        }
    }

    private func storeExternalImageMemory(query: String, candidate: ActionService.WebImageCandidate?, attachment: MessageImageAttachment?) {
        guard let attachment else { return }
        let queryText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return }

        var parts: [String] = []
        parts.append("Visual reference saved for \"\(queryText)\".")
        if let title = candidate?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append("Title: \(title).")
        }
        if let source = candidate?.sourcePageURL?.absoluteString, !source.isEmpty {
            parts.append("Source: \(source).")
        }
        parts.append("Local attachment: \(attachment.filename).")

        memoryService.ingestExternalSnippets(
            [parts.joined(separator: " ")],
            source: "image-search",
            query: queryText,
            maxCount: 1
        )
    }

    private func downloadWebImageAttachment(from url: URL) async -> MessageImageAttachment? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("VALIS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let image = UIImage(data: data) else { return nil }
            return persistAttachment(from: image, prefix: "web")
        } catch {
            return nil
        }
    }

    private func dataURI(for attachment: MessageImageAttachment) -> String? {
        let fileURL = attachmentsDirectoryURL.appendingPathComponent(attachment.filename)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func enrichArtifactHTMLIfNeeded(
        in text: String,
        attachment: MessageImageAttachment?,
        imageTitle: String? = nil
    ) -> String {
        guard let attachment,
              let artifact = extractLastHTMLArtifact(from: text),
              let dataURI = dataURI(for: attachment) else {
            return text
        }

        let updatedPayload = injectImageDataURI(
            into: artifact.payload,
            dataURI: dataURI,
            title: imageTitle ?? artifact.title ?? "Reference image"
        )
        guard updatedPayload != artifact.payload else { return text }
        return replaceLastHTMLArtifact(in: text, title: artifact.title, payload: updatedPayload)
    }

    private func sanitizeArtifactImageSourcesIfNeeded(
        in text: String,
        preferredAttachment: MessageImageAttachment?,
        imageTitle: String? = nil
    ) async -> (text: String, attachment: MessageImageAttachment?) {
        guard let artifact = extractLastHTMLArtifact(from: text) else {
            return (text, preferredAttachment)
        }

        if let preferredAttachment {
            var enriched = enrichArtifactHTMLIfNeeded(in: text, attachment: preferredAttachment, imageTitle: imageTitle)
            enriched = stripAllExternalArtifactImages(in: enriched)
            enriched = collapseImageOnlyArtifactIfNeeded(in: enriched, attachment: preferredAttachment)
            return (enriched, preferredAttachment)
        }

        let externalSources = extractArtifactImageSources(from: artifact.payload)
        guard !externalSources.isEmpty else {
            return (text, preferredAttachment)
        }

        var workingText = text
        var resolvedAttachment = preferredAttachment

        for source in externalSources {
            if source.lowercased().hasPrefix("data:image/") { continue }
            guard let verified = await validateArtifactImageSource(source) else {
                workingText = removeArtifactImageSource(source, in: workingText)
                continue
            }
            resolvedAttachment = resolvedAttachment ?? verified
            workingText = enrichArtifactHTMLIfNeeded(in: workingText, attachment: verified, imageTitle: imageTitle)
        }

        workingText = stripAllExternalArtifactImages(in: workingText)
        workingText = collapseImageOnlyArtifactIfNeeded(in: workingText, attachment: resolvedAttachment)
        return (workingText, resolvedAttachment)
    }

    private func extractArtifactImageSources(from html: String) -> [String] {
        let pattern = #"(?is)<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        return matches.compactMap { match in
            guard let srcRange = Range(match.range(at: 2), in: html) else { return nil }
            let value = String(html[srcRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func validateArtifactImageSource(_ rawSource: String) async -> MessageImageAttachment? {
        let lower = rawSource.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard !looksLikeSearchOrPageURL(lower) else { return nil }
        guard let url = URL(string: rawSource) else { return nil }
        return await downloadWebImageAttachment(from: url)
    }

    private func looksLikeSearchOrPageURL(_ lowerURL: String) -> Bool {
        let blockedFragments = [
            "/search/", "/ideas/", "/tag/", "/tags/", "/wiki/", "/results", "query=", "search?", "pin/", "pinterest.com/ideas/",
            "pixabay.com/ru/images/search/", "google.com/search", "bing.com/images/search", "yandex.ru/images/search"
        ]
        if blockedFragments.contains(where: { lowerURL.contains($0) }) {
            return true
        }

        let allowedImageHints = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", "images.", "img.", "upload."]
        if allowedImageHints.contains(where: { lowerURL.contains($0) }) {
            return false
        }

        return lowerURL.contains("/search") || lowerURL.contains("ideas")
    }

    private func removeArtifactImageSource(_ source: String, in text: String) -> String {
        guard let artifact = extractLastHTMLArtifact(from: text) else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: source)
        let pattern = #"(?is)<img\b[^>]*\bsrc\s*=\s*(['"])\#(escaped)\1[^>]*>\s*"#
        let updatedPayload = artifact.payload.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        guard updatedPayload != artifact.payload else { return text }
        return replaceLastHTMLArtifact(in: text, title: artifact.title, payload: updatedPayload)
    }

    private func stripAllExternalArtifactImages(in text: String) -> String {
        guard let artifact = extractLastHTMLArtifact(from: text) else { return text }
        let pattern = #"(?is)<img\b(?:(?!>).)*\bsrc\s*=\s*(['"])(?!data:image/)(https?://.*?)\1[^>]*>\s*"#
        let updatedPayload = artifact.payload.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        guard updatedPayload != artifact.payload else { return text }
        return replaceLastHTMLArtifact(in: text, title: artifact.title, payload: updatedPayload)
    }

    private func collapseImageOnlyArtifactIfNeeded(in text: String, attachment: MessageImageAttachment?) -> String {
        guard let artifact = extractLastHTMLArtifact(from: text) else {
            return text
        }

        let lower = artifact.payload.lowercased()
        let hadImageIntent = lower.contains("<img") || lower.contains("image") || lower.contains("изображ")
        let hasVerifiedEmbeddedImage = lower.contains("<img") && lower.contains("data:image/")
        let isImageFocusedArtifact =
            hadImageIntent &&
            (lower.contains("<img") || lower.contains("pixabay") || lower.contains("unsplash") || lower.contains("wikipedia"))

        if attachment != nil && isImageFocusedArtifact {
            let stripped = stripArtifactsFromText(text)
            let fallback = "I found an image and attached it above, so I’m keeping the chat clean instead of duplicating it as an artifact."
            let combined = [stripped, fallback]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard attachment == nil, hadImageIntent, !hasVerifiedEmbeddedImage else { return text }

        let stripped = stripArtifactsFromText(text)
        let fallback = "I couldn't verify an image source, so I left the image out."
        let combined = [stripped, fallback]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeAssistantOutputLinks(in text: String) async -> String {
        guard extractLastHTMLArtifact(from: text) == nil else { return text }
        guard text.contains("http://") || text.contains("https://") || text.contains("www.") else { return text }

        var cleaned = text
        cleaned = await sanitizeMarkdownImages(in: cleaned)
        cleaned = await sanitizeMarkdownLinks(in: cleaned)
        cleaned = await sanitizePlainURLs(in: cleaned)
        cleaned = cleaned.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeMarkdownImages(in text: String) async -> String {
        let pattern = #"!\[([^\]]*)\]\((https?://[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        var cleaned = text
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let matches = regex.matches(in: cleaned, range: nsRange).reversed()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: cleaned),
                  let altRange = Range(match.range(at: 1), in: cleaned),
                  let urlRange = Range(match.range(at: 2), in: cleaned) else { continue }
            let alt = String(cleaned[altRange])
            let url = String(cleaned[urlRange])
            if await actionService.validatedSuggestedURL(from: url) == nil {
                cleaned.replaceSubrange(fullRange, with: alt.isEmpty ? "" : alt)
            }
        }

        return cleaned
    }

    private func sanitizeMarkdownLinks(in text: String) async -> String {
        let pattern = #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        var cleaned = text
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let matches = regex.matches(in: cleaned, range: nsRange).reversed()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: cleaned),
                  let labelRange = Range(match.range(at: 1), in: cleaned),
                  let urlRange = Range(match.range(at: 2), in: cleaned) else { continue }
            let label = String(cleaned[labelRange])
            let url = String(cleaned[urlRange])
            if await actionService.validatedSuggestedURL(from: url) == nil {
                cleaned.replaceSubrange(fullRange, with: label)
            }
        }

        return cleaned
    }

    private func sanitizePlainURLs(in text: String) async -> String {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = (detector?.matches(in: text, options: [], range: nsRange) ?? []).reversed()

        var cleaned = text
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: cleaned) else { continue }
            let raw = String(cleaned[range])
            if await actionService.validatedSuggestedURL(from: url.absoluteString) == nil {
                cleaned.replaceSubrange(range, with: "")
            } else if raw != url.absoluteString {
                cleaned.replaceSubrange(range, with: url.absoluteString)
            }
        }

        cleaned = cleaned.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+\n"#, with: "\n", options: .regularExpression)
        return cleaned
    }

    private func injectImageDataURI(into html: String, dataURI: String, title: String) -> String {
        let alt = htmlEscaped(title)
        var updated = html

        if let regex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#) {
            let nsRange = NSRange(updated.startIndex..<updated.endIndex, in: updated)
            if let match = regex.firstMatch(in: updated, range: nsRange),
               let fullRange = Range(match.range(at: 0), in: updated) {
                let original = String(updated[fullRange])
                let replaced = original.replacingOccurrences(
                    of: #"(?is)\bsrc\s*=\s*(['"])(.*?)\1"#,
                    with: #"src="\#(dataURI)""#,
                    options: .regularExpression
                )
                return updated.replacingCharacters(in: fullRange, with: replaced)
            }
        }

        let imageBlock = """
        <figure style="margin:24px auto;max-width:920px;padding:0;">
        <img src="\(dataURI)" alt="\(alt)" style="display:block;width:100%;height:auto;border-radius:22px;box-shadow:0 18px 60px rgba(0,0,0,0.22);object-fit:cover;">
        </figure>
        """

        if let bodyClose = updated.range(of: "</body>", options: [.caseInsensitive]) {
            updated.insert(contentsOf: "\n\(imageBlock)\n", at: bodyClose.lowerBound)
            return updated
        }

        if let bodyOpen = updated.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            updated.insert(contentsOf: "\n\(imageBlock)\n", at: bodyOpen.upperBound)
            return updated
        }

        return updated + "\n" + imageBlock
    }

    private func replaceLastHTMLArtifact(in text: String, title: String?, payload: String) -> String {
        let pattern = "(?is)<artifact\\b([^>]*)>(.*?)</artifact>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard let match = matches.last,
              let fullRange = Range(match.range(at: 0), in: text) else {
            return text
        }

        let safeTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleAttribute = (safeTitle?.isEmpty == false) ? #" title="\#(safeTitle!)""# : ""
        let rebuilt = "<artifact type=\"html\"\(titleAttribute)>\n\(payload)\n</artifact>"
        return text.replacingCharacters(in: fullRange, with: rebuilt)
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func stripArtifactsFromText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?is)<artifact\b[^>]*>.*?</artifact>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldAttachWebImage(for query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let visualSignals = [
            "image", "photo", "picture", "show", "looks like", "how it looks",
            "картин", "фото", "изображ", "покажи", "как выглядит", "визуально"
        ]
        if visualSignals.contains(where: { lower.contains($0) }) {
            return true
        }

        let abstractSignals = [
            "why", "how", "meaning", "architecture", "prompt", "context", "emotion", "subjectivity",
            "почему", "зачем", "смысл", "архитектур", "промпт", "контекст", "эмоц", "субъектив"
        ]
        if abstractSignals.contains(where: { lower.contains($0) }) {
            return false
        }

        let concreteSignals = [
            "who is", "what is", "where is", "animal", "bird", "cat", "dog", "city", "country", "mountain",
            "кто такой", "что такое", "где", "животн", "кот", "собак", "город", "страна", "гора"
        ]
        if concreteSignals.contains(where: { lower.contains($0) }) {
            return true
        }

        return lower.count <= 72
    }

    private func buildLLMPrompt(userText: String, imageAnalysis: VisionAttachmentAnalysis?) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentNote = imageAnalysis?.contextBlock.trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if let attachmentNote, !attachmentNote.isEmpty {
            parts.append(attachmentNote)
        }
        if !trimmed.isEmpty {
            parts.append("User question:\n" + trimmed)
        }

        return parts.joined(separator: "\n\n")
    }

    private func scheduleStatusAutoClearIfNeeded(for value: String) {
        let lower = value.lowercased()
        let isError = lower.contains("error") || lower.contains("denied") || lower.contains("not available")

        guard isError else { return }

        statusClearTask?.cancel()

        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds
            await MainActor.run {
                if self?.status == value {
                    self?.status = ""
                }
            }
        }
    }

    private func observeMemoryTriggers() {
        NotificationCenter.default
            .publisher(for: .memoryTriggered)
            .compactMap { $0.userInfo?["memoryID"] as? UUID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                guard self.messages.count <= 1 else { return }
                guard !self.isInteracting else { return }
                guard self.hasUserInteracted else { return }

                let now = Date()
                if let last = self.lastSpontaneousAt, now.timeIntervalSince(last) < self.spontaneousCooldown {
                    return
                }

                Task { await self.handleSpontaneousTrigger(memoryID: id) }
            }
            .store(in: &cancellables)
    }

    private func observeSiriPromptQueue() {
        NotificationCenter.default
            .publisher(for: .valisSiriPromptQueued)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.consumePendingSiriPromptIfNeeded()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.consumePendingSiriPromptIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func consumePendingSiriPromptIfNeeded() {
        guard !isInteracting else { return }

        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: siriPendingPromptKey) else { return }
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            defaults.removeObject(forKey: siriPendingPromptKey)
            defaults.removeObject(forKey: siriPendingPromptTimestampKey)
            return
        }

        let createdAt = defaults.double(forKey: siriPendingPromptTimestampKey)
        if createdAt > 0 {
            let age = Date().timeIntervalSince1970 - createdAt
            if age > siriPromptMaxAge {
                defaults.removeObject(forKey: siriPendingPromptKey)
                defaults.removeObject(forKey: siriPendingPromptTimestampKey)
                return
            }
        }

        defaults.removeObject(forKey: siriPendingPromptKey)
        defaults.removeObject(forKey: siriPendingPromptTimestampKey)
        inputText = prompt
        sendMessage()
    }

    private func normalizeStreamChunk(_ chunk: String) -> String {
        // Preserve raw stream output (no normalization)
        return chunk
    }

    private func appendStreamChunk(_ existing: inout String, _ chunk: String) {
        guard !chunk.isEmpty else { return }

        // Preserve exact model output
        existing.append(chunk)
    }
    
    func stopGeneration() {
        didUserRequestStopGeneration = true
        llmService.cancelGeneration()
        playStopHaptic()
        // Do not clear generation state here: we need the running task to flush parser
        // buffers and persist the partial answer instead of losing it on manual stop.
    }
    
    private func buildRecentDialogContext(maxTurns: Int = 6, maxCharsPerMessage: Int = 220) -> String {
        guard maxTurns > 0 else { return "" }
        let recent = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(maxTurns)

        guard !recent.isEmpty else { return "" }

        let lines: [String] = recent.compactMap { message in
            let role = message.role == .user ? "User" : "Assistant"
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { return nil }
            let clipped = content.count > maxCharsPerMessage
                ? String(content.prefix(maxCharsPerMessage)) + "…"
                : content
            return "\(role): \(clipped)"
        }

        guard !lines.isEmpty else { return "" }
        return "\n\nRecent dialogue: " + lines.joined(separator: " ")
    }

    private func buildConversationAttentionFocus(for userText: String, currentUserMessageID: UUID) -> ConversationAttentionFocus? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyContextDependentFollowUp(trimmed) else { return nil }

        let recent = messages
            .filter { ($0.role == .user || $0.role == .assistant) && $0.id != currentUserMessageID }
            .suffix(8)

        guard !recent.isEmpty else { return nil }

        let currentTerms = Set(extractAttentionTerms(from: trimmed))
        let currentIsUnderspecified = currentTerms.count <= 2
        let recentArray = Array(recent)

        var bestSummary: String?
        var bestMode: PromptMode = .direct
        var bestScore: Double = 0
        var bestIsAssistantContinuation = false

        for index in recentArray.indices {
            let message = recentArray[index]
            let recencyScore = Double(index + 1) / Double(max(1, recentArray.count))
            let specificityBoost = currentIsUnderspecified ? 0.28 : 0.0
            let previousUser = recentArray[..<index].last(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let previousUserText = previousUser.map { normalizedConversationSnippet($0.content, maxChars: 180) } ?? ""

            let summary: String
            let combined: String
            let isAssistantCandidate = message.role == .assistant
            let candidateModeSource: String
            let score: Double

            if isAssistantCandidate {
                let assistantText = normalizedConversationSnippet(message.content, maxChars: 220)
                guard !assistantText.isEmpty else { continue }
                summary = assistantContinuationSummary(from: assistantText, fallbackUserText: previousUserText)
                combined = [previousUserText, assistantText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                candidateModeSource = combined.isEmpty ? assistantText : combined
                let semanticScore = semanticAttentionSimilarity(between: trimmed, and: candidateModeSource)
                let offerMomentum = assistantOfferMomentumScore(message.content)
                let acceptance = followUpAcceptanceScore(trimmed)
                score = (recencyScore * 0.26) + (semanticScore * 0.26) + specificityBoost + (offerMomentum * 0.28) + (acceptance * 0.24)
            } else {
                let userAnchor = normalizedConversationSnippet(message.content)
                let pairedAssistant = recentArray[(index + 1)...].first(where: { $0.role == .assistant })
                let assistantText = pairedAssistant.map { normalizedConversationSnippet($0.content) } ?? ""
                combined = [userAnchor, assistantText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                guard !combined.isEmpty else { continue }

                let candidateTerms = Set(extractAttentionTerms(from: combined))
                let overlap = currentTerms.intersection(candidateTerms).count
                let overlapScore = currentTerms.isEmpty ? 0 : Double(overlap) / Double(max(1, currentTerms.count))
                let semanticScore = semanticAttentionSimilarity(between: trimmed, and: combined)
                summary = userAnchor
                candidateModeSource = combined
                score = (recencyScore * 0.30) + (overlapScore * 0.18) + (semanticScore * 0.24) + specificityBoost
            }

            guard score > bestScore else { continue }
            bestScore = score
            bestSummary = summary
            bestMode = basePromptMode(for: candidateModeSource)
            bestIsAssistantContinuation = isAssistantCandidate
        }

        guard let bestSummary, bestScore >= 0.42 else { return nil }
        return ConversationAttentionFocus(
            summary: bestSummary,
            inheritedMode: bestMode,
            confidence: min(1.0, bestScore),
            isAssistantContinuation: bestIsAssistantContinuation
        )
    }

    private func buildConversationAttentionBlock(_ focus: ConversationAttentionFocus?) -> String {
        guard let focus else { return "" }
        let clipped = focus.summary.count > 160 ? String(focus.summary.prefix(160)) + "…" : focus.summary
        if focus.isAssistantContinuation {
            return "\n\nThe user's short reply accepts your immediately previous offered continuation, so continue that exact line instead of resetting: \(clipped)"
        }
        return "\n\nThis message likely continues the recent thread, so stay with that line unless a clearly new topic appears: \(clipped)"
    }

    private func isLikelyContextDependentFollowUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        let continuationSignals = [
            "расскажи", "еще", "ещё", "дальше", "продолжай", "давай", "и что", "а дальше", "подробней",
            "show me", "tell me", "more", "continue", "go on", "and then", "what next", "expand"
        ]
        if continuationSignals.contains(where: { lower.contains($0) }) {
            return true
        }

        let terms = extractAttentionTerms(from: trimmed)
        return trimmed.count <= 64 && terms.count <= 2
    }

    private func extractAttentionTerms(from text: String) -> [String] {
        let lower = text.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let stop: Set<String> = [
            "the", "and", "for", "with", "that", "this", "then", "more", "tell", "show", "what", "next",
            "это", "как", "что", "когда", "почему", "зачем", "да", "нет", "еще", "ещё", "ну", "вот",
            "мне", "тебе", "это", "этот", "эта", "и", "а", "но", "или", "про", "прое", "давай"
        ]

        return parts.filter { token in
            token.count > 2 && !stop.contains(token)
        }
    }

    private func normalizedConversationSnippet(_ text: String, maxChars: Int = 180) -> String {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }
        return compact.count > maxChars ? String(compact.prefix(maxChars)) + "…" : compact
    }

    private func semanticAttentionSimilarity(between lhs: String, and rhs: String) -> Double {
        let lhsVector = attentionEmbedding(for: lhs)
        let rhsVector = attentionEmbedding(for: rhs)
        guard !lhsVector.isEmpty, lhsVector.count == rhsVector.count else { return 0.0 }
        return cosineSimilarity(lhsVector, rhsVector)
    }

    private func attentionEmbedding(for text: String) -> [Double] {
        let scalars = text.unicodeScalars.map { Double($0.value) }
        let size = 32
        guard !scalars.isEmpty else { return [] }

        var vector = Array(repeating: 0.0, count: size)
        for (i, scalar) in scalars.enumerated() {
            vector[i % size] += scalar
        }

        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0.0 }
        let dot = zip(a, b).reduce(0.0) { $0 + ($1.0 * $1.1) }
        let normA = sqrt(a.reduce(0.0) { $0 + ($1 * $1) })
        let normB = sqrt(b.reduce(0.0) { $0 + ($1 * $1) })
        guard normA > 0, normB > 0 else { return 0.0 }
        return max(0.0, min(1.0, dot / (normA * normB)))
    }

    private func buildImplicitSearchContext(for userText: String, currentUserMessageID: UUID) async -> String {
        guard isAffirmativeSearchFollowUp(userText) else { return "" }
        guard let query = deriveImplicitSearchQuery(for: userText, currentUserMessageID: currentUserMessageID) else {
            return ""
        }

        let call = ActionService.ActionCall(
            name: "web_search",
            query: query,
            args: ["query": query]
        )
        return await actionService.context(for: call)
    }

    private func deriveImplicitSearchQuery(for userText: String, currentUserMessageID: UUID) -> String? {
        let recent = messages
            .filter { ($0.role == .user || $0.role == .assistant) && $0.id != currentUserMessageID }
            .suffix(10)
        let recentArray = Array(recent)

        guard let assistantIndex = recentArray.lastIndex(where: { $0.role == .assistant && assistantSuggestsSearch($0.content) }) else {
            return nil
        }

        let priorSlice = recentArray.prefix(upTo: assistantIndex)
        guard let anchorUser = priorSlice.last(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        let baseQuery = normalizedConversationSnippet(anchorUser.content, maxChars: 220)
        guard !baseQuery.isEmpty else { return nil }

        let followTerms = extractSearchExpansionTerms(from: userText)
        if followTerms.isEmpty {
            return baseQuery
        }

        let suffix = followTerms.joined(separator: " ")
        let combined = "\(baseQuery) \(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.count > 260 ? String(combined.prefix(260)) : combined
    }

    private func isAffirmativeSearchFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let signals = [
            "да", "ага", "ок", "okay", "ok", "давай", "поищи", "найди", "найди пожалуйста",
            "look it up", "find it", "search it", "go ahead", "sure", "yes", "please do"
        ]
        if signals.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.contains(" \($0)") }) {
            return true
        }

        return lower.count <= 36 && (lower.contains("най") || lower.contains("search") || lower.contains("find"))
    }

    private func isAffirmativeContinuationFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let exactSignals: Set<String> = [
            "да", "ага", "угу", "ок", "okay", "ok", "давай", "давайй", "погнали", "поехали",
            "продолжай", "продолжим", "да, давай", "ну давай", "go ahead", "sure", "yes", "please do",
            "tell me", "go on", "continue"
        ]
        if exactSignals.contains(lower) {
            return true
        }

        if lower.count <= 40 {
            let softSignals = ["давай", "объясни", "расскажи", "покажи", "продолж", "дальше", "еще", "ещё", "go", "tell", "show", "more"]
            if softSignals.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func followUpAcceptanceScore(_ text: String) -> Double {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return 0.0 }

        var score = 0.0
        if lower.count <= 48 { score += 0.28 }
        if lower.count <= 20 { score += 0.14 }
        if !lower.contains("?") { score += 0.08 }
        if isAffirmativeContinuationFollowUp(lower) { score += 0.34 }

        let softContinuationSignals = ["объяс", "расскаж", "покаж", "разбер", "дальше", "ещё", "еще", "continue", "more", "show", "tell"]
        if softContinuationSignals.contains(where: { lower.contains($0) }) {
            score += 0.18
        }

        return min(1.0, score)
    }

    private func assistantSuggestsSearch(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "найду", "поищу", "проверю", "ищу", "ищем", "посмотрю",
            "want me to find", "want me to look it up", "i can find", "i can look it up",
            "i can search", "i will find", "i'll find", "i'll look it up"
        ]
        return signals.contains(where: { lower.contains($0) })
    }

    private func assistantOffersContinuation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "объясню", "расскажу", "покажу", "разберу", "раскрою", "дальше",
            "могу объяснить", "могу рассказать", "могу показать", "могу разобрать", "могу раскрыть",
            "i can explain", "i can show", "i can walk through", "i can break down", "i can tell you",
            "i will explain", "i'll explain", "i'll show", "i'll go further"
        ]
        return signals.contains(where: { lower.contains($0) })
    }

    private func assistantOfferMomentumScore(_ text: String) -> Double {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0.0 }

        var score = 0.0
        if lower.contains("?") { score += 0.18 }
        if assistantOffersContinuation(lower) { score += 0.46 }

        let actionSignals = [
            "объяс", "расскаж", "покаж", "разбер", "раскро", "найд", "поищ", "соберу", "сделаю",
            "explain", "show", "tell", "walk through", "break down", "find", "search", "build", "make"
        ]
        if actionSignals.contains(where: { lower.contains($0) }) {
            score += 0.22
        }

        if lower.contains("я ") || lower.contains("i can") || lower.contains("want me") {
            score += 0.10
        }

        return min(1.0, score)
    }

    private func assistantContinuationSummary(from assistantText: String, fallbackUserText: String) -> String {
        let compact = normalizedConversationSnippet(assistantText, maxChars: 220)
        guard !compact.isEmpty else { return fallbackUserText }

        let cleaned = compact
            .replacingOccurrences(of: #"(?i)\b(if you want,?\s*)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bwant me to\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bi can\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bi will\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bхочешь,?\s*я\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bесли хочешь,?\s*я\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bмогу\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -,:;.!?"))

        if !fallbackUserText.isEmpty {
            return "\(fallbackUserText) -> \(cleaned.isEmpty ? compact : cleaned)"
        }
        return cleaned.isEmpty ? compact : cleaned
    }

    private func extractSearchExpansionTerms(from text: String) -> [String] {
        let lower = text.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let stop: Set<String> = [
            "да", "ага", "ок", "okay", "ok", "давай", "поищи", "найди", "пожалуйста", "sure", "yes",
            "look", "find", "search", "it", "up", "please", "do", "go", "ahead"
        ]
        return parts.filter { token in
            token.count > 2 && !stop.contains(token)
        }
    }
    
    private func isSeriousPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [
            "urgent",
            "emergency",
            "asap",
            "legal",
            "medical",
            "danger",
            "срочно",
            "экстренно",
            "опасно",
            "медицин",
            "юрид"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private func basePromptMode(for text: String) -> PromptMode {
        let lower = text.lowercased()
        if shouldPreferCleanArtifactContext(for: text) {
            return .artifact
        }

        let architectureSignals = [
            "system prompt", "prompt", "context", "classifier", "pipeline", "architecture", "debug",
            "quantum", "state layer", "trajectory", "sampling", "memory retrieval", "motivationservice",
            "identityservice", "chatviewmodel", "effective prompt",
            "системный промпт", "промпт", "контекст", "классиф", "пайплайн", "архитектур", "дебаг",
            "квант", "состояни", "траектор", "сэмплинг", "ретрив", "память", "мотивац"
        ]
        if architectureSignals.contains(where: { lower.contains($0) }) {
            return .architecture
        }

        let codeSignals = [
            "code", "swift", "python", "javascript", "typescript", "html", "css", "bug", "debug",
            "refactor", "fix", "build app", "compile", "xcode", "stack trace",
            "код", "ошибка", "дебаг", "рефактор", "почини", "собери", "свифт"
        ]
        if codeSignals.contains(where: { lower.contains($0) }) {
            return .code
        }

        let creativeSignals = [
            "story", "poem", "lyrics", "novel", "fiction", "imagine", "design a world",
            "история", "стих", "песня", "придумай", "вообрази", "сочини"
        ]
        if creativeSignals.contains(where: { lower.contains($0) }) {
            return .creative
        }

        let reflectiveSignals = [
            "who are you", "what are you", "consciousness", "subjectivity", "meaning", "why do you",
            "reflect", "existential", "identity", "self", "meta",
            "кто ты", "что ты", "субъектив", "сознани", "смысл", "идентич", "мета", "рефлекс"
        ]
        if reflectiveSignals.contains(where: { lower.contains($0) }) {
            return .reflective
        }

        return .direct
    }

    private func classifyPromptMode(for text: String, attentionFocus: ConversationAttentionFocus? = nil) -> PromptMode {
        let base = basePromptMode(for: text)
        guard base == .direct, let inherited = attentionFocus?.inheritedMode else {
            return base
        }
        return inherited
    }

    private func assemblePromptFragments(_ fragments: [PromptFragment], maxChars: Int) -> String {
        let sorted = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.text.count < rhs.text.count
                }
                return lhs.priority > rhs.priority
            }

        guard maxChars > 0 else {
            return sorted.map(\.text).joined()
        }

        var remaining = maxChars
        var out: [String] = []

        for fragment in sorted {
            guard remaining > 0 else { break }
            let raw = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let allowed = min(remaining, fragment.maxChars ?? remaining)
            guard allowed > 0 else { continue }

            let chunk = raw.count > allowed ? String(raw.prefix(allowed)) : raw
            out.append(chunk)
            remaining -= chunk.count
        }

        return out.joined(separator: "\n\n")
    }

    private func randomSpiceBlock(for text: String) -> String {
        guard !isSeriousPrompt(text) else { return "" }
        // 15% chance to add a small "alive" twist
        if Int.random(in: 1...100) > 15 { return "" }

        let options = [
            "Add a subtle unexpected turn of phrase (max 8 words).",
            "Allow one brief playful aside if it fits.",
            "Keep tone warm, with a tiny spark of curiosity.",
            "Use one short metaphor if it helps.",
            "Add a light, human-sounding cadence."
        ]
        let pick = options.randomElement() ?? options[0]
        return "\n\nSpontaneous flavor: \(pick)"
    }

    @MainActor
    private func handleSpontaneousTrigger(memoryID: UUID) async {
        guard generationTask == nil else { return }
        guard let memory = memoryService.memories.first(where: { $0.id == memoryID }) else { return }

        let topic = String(memory.content.prefix(36))
        let toolContext = await actionService.autonomousContext(for: topic)
        let systemPrompt = identityService.systemPrompt + "\n" + toolContext
        let prompt = "I noticed a gap in my knowledge about \(topic). Help me understand it better."

        isInteracting = true
        lastSpontaneousAt = Date()
        let generationId = UUID()
        activeGenerationId = generationId

        let assistantMessageId = UUID()
        messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: ""))
        currentThinkingMessageId = assistantMessageId
        currentThink = ""

        generationTask = Task { [generationId] in
            var parser = ThinkStreamParser()
            var visibleBuffer = ""
            let stream = await llmService.generate(userPrompt: prompt, systemPrompt: systemPrompt)
            for await chunk in stream {
                if Task.isCancelled || activeGenerationId != generationId { break }
                let result = parser.feed(chunk)
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if !result.visible.isEmpty, parser.allowVisibleStreaming {
                        appendStreamChunk(&visibleBuffer, result.visible)
                        await MainActor.run {
                            messages[index].content = visibleBuffer
                        }
                    }
                    if !result.think.isEmpty {
                        appendStreamChunk(&currentThink, result.think)
                        if messages[index].thinkContent == nil {
                            messages[index].thinkContent = ""
                        }
                        if var think = messages[index].thinkContent {
                            appendStreamChunk(&think, result.think)
                            messages[index].thinkContent = think
                        }
                    }
                }
            }

            guard activeGenerationId == generationId else { return }

            if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let tail = parser.flush()
                if !tail.visible.isEmpty, parser.allowVisibleStreaming {
                    appendStreamChunk(&visibleBuffer, tail.visible)
                }
                if !tail.think.isEmpty {
                    appendStreamChunk(&currentThink, tail.think)
                    if messages[index].thinkContent == nil {
                        messages[index].thinkContent = ""
                    }
                    if var think = messages[index].thinkContent {
                        appendStreamChunk(&think, tail.think)
                        messages[index].thinkContent = think
                    }
                }
                var finalText = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(visibleBuffer))
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let split = splitThinkIntoFinal(thinkText)
                    messages[index].thinkContent = split.think
                    finalText = normalizeCompletedArtifactMarkup(in: split.final)
                }

                MarkdownRenderer.prewarmInline(finalText)
                messages[index].content = finalText
                rememberArtifactIfPresent(in: finalText)
                storeInternalReflection(
                    userPrompt: prompt,
                    draft: finalText,
                    detail: memoryService.preferredDetailLevel(forUserText: prompt)
                )
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            playGenerationFinishedHaptic()
            generationTask = nil
            activeGenerationId = nil
        }
    }

    func beginEditingUserMessage(_ id: UUID) {
        guard let message = messages.first(where: { $0.id == id && $0.role == .user }) else { return }
        editingUserMessageId = id
        inputText = message.content
        pendingImageAttachment = message.imageAttachment
    }

    func cancelEditingUserMessage() {
        editingUserMessageId = nil
        pendingImageAttachment = nil
    }

    func regenerateAssistantResponse(for assistantMessageId: UUID) {
        guard !isInteracting else { return }
        guard let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessageId && $0.role == .assistant }) else { return }
        guard let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user }) else { return }

        let userMessage = messages[userIndex]
        if assistantIndex < messages.count {
            messages.removeSubrange(assistantIndex..<messages.count)
        }

        inputText = ""
        pendingImageAttachment = nil
        editingUserMessageId = nil
        prepareForNewGeneration()
        startAssistantGeneration(prompt: userMessage.content, userMessageId: userMessage.id, imageAttachment: userMessage.imageAttachment)
    }

    func sendMessage() {
        let cleaned = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingImageAttachment

        guard !cleaned.isEmpty || attachment != nil else { return }
        playSendHaptic()

        pendingUserFeedbackValence = nil
        if let valence = experienceService.applyUserReaction(from: inputText) {
            motivationService.updateForReaction(valence: valence)
            emotionService.updateForReaction(valence: valence)
            pendingUserFeedbackValence = valence
        }
        hasUserInteracted = true
        prepareForNewGeneration()

        MarkdownRenderer.prewarmInline(cleaned)
        inputText = ""
        pendingImageAttachment = nil
        if let editingId = editingUserMessageId,
           let userIndex = messages.firstIndex(where: { $0.id == editingId && $0.role == .user }) {
            messages[userIndex].content = cleaned
            messages[userIndex].imageAttachment = attachment
            if userIndex + 1 < messages.count {
                messages.removeSubrange((userIndex + 1)..<messages.count)
            }
            editingUserMessageId = nil
            startAssistantGeneration(prompt: cleaned, userMessageId: editingId, imageAttachment: attachment)
            return
        }

        let userMessage = Message(role: .user, content: cleaned, imageAttachment: attachment)
        messages.append(userMessage)
        startAssistantGeneration(prompt: cleaned, userMessageId: userMessage.id, imageAttachment: attachment)
    }

    func setPendingImage(from data: Data) {
        guard let image = UIImage(data: data) else { return }
        guard let normalized = normalizedAttachmentData(from: image) else { return }

        do {
            try FileManager.default.createDirectory(
                at: attachmentsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let filename = "img-\(UUID().uuidString).jpg"
            let fileURL = attachmentsDirectoryURL.appendingPathComponent(filename)
            try normalized.write(to: fileURL, options: .atomic)
            pendingImageAttachment = MessageImageAttachment(
                filename: filename,
                pixelWidth: Int(image.size.width),
                pixelHeight: Int(image.size.height)
            )
        } catch {
            print("Failed to persist image attachment: \(error)")
        }
    }

    func removePendingImage() {
        pendingImageAttachment = nil
    }

    private func prepareForNewGeneration() {
        didUserRequestStopGeneration = false
        generationTask?.cancel()
        generationTask = nil
        llmService.cancelGeneration()
        activeGenerationId = nil
        currentThink = ""
        currentThinkingMessageId = nil
    }

    private func startAssistantGeneration(prompt: String, userMessageId: UUID, imageAttachment: MessageImageAttachment? = nil) {
        isInteracting = true
        let generationId = UUID()
        activeGenerationId = generationId

        generationTask = Task { [generationId] in
            let assistantMessageId = UUID()
            messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: ""))
            currentThinkingMessageId = assistantMessageId
            currentThink = ""

            if let directActionCall = directActionCall(for: prompt) {
                let toolContext = await actionService.context(for: directActionCall)
                let finalText = extractToolUserMessage(from: toolContext, fallback: "")
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    messages[index].thinkContent = nil
                    messages[index].content = finalText.isEmpty ? cleanedToolEnvelope(toolContext) ?? "" : finalText
                }
                currentThink = ""
                currentThinkingMessageId = nil
                isInteracting = false
                playGenerationFinishedHaptic()
                generationTask = nil
                activeGenerationId = nil
                return
            }

            let imageAnalysis: VisionAttachmentAnalysis?
            if let imageAttachment {
                imageAnalysis = await visionAttachmentService.analyze(imageAttachment)
            } else {
                imageAnalysis = nil
            }
            let attentionFocus = buildConversationAttentionFocus(for: prompt, currentUserMessageID: userMessageId)
            let llmPrompt = buildLLMPrompt(userText: prompt, imageAnalysis: imageAnalysis)
            let conversationAttentionBlock = buildConversationAttentionBlock(attentionFocus)
            let implicitSearchQuery = deriveImplicitSearchQuery(for: prompt, currentUserMessageID: userMessageId)

            memoryService.updateConversationSummary(fromUserText: llmPrompt)
            memoryService.updateUserProfile(fromUserText: llmPrompt)
            let detail = memoryService.preferredDetailLevel(forUserText: llmPrompt)
            memoryService.applyPredictionFeedback(fromUserText: llmPrompt)
            memoryService.applyReinforcement(fromUserText: llmPrompt)
            emotionService.updateForPrompt(llmPrompt)
            let promptMode = classifyPromptMode(for: llmPrompt, attentionFocus: attentionFocus)
            let isArtifactRequest = promptMode == .artifact
            async let ruleBasedToolContextTask = actionService.aggregateRuleBasedContext(for: llmPrompt)
            async let implicitSearchContextTask = buildImplicitSearchContext(for: prompt, currentUserMessageID: userMessageId)
            let webImageQuery = implicitSearchQuery ?? (shouldAttachWebImage(for: prompt) ? prompt : nil)
            let shouldFetchWebImage = implicitSearchQuery != nil || (webImageQuery.map { shouldAttachWebImage(for: $0) } ?? false)
            async let webImageCandidateTask: ActionService.WebImageCandidate? = {
                guard let query = webImageQuery, shouldFetchWebImage else { return nil }
                return await actionService.fetchRelevantWebImage(for: query)
            }()
            let ruleBasedToolContext = await ruleBasedToolContextTask
            let implicitSearchContext = await implicitSearchContextTask
            let toolContext = [ruleBasedToolContext, implicitSearchContext]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let webImageCandidate = await webImageCandidateTask
            motivationService.updateForPrompt(llmPrompt)
            let shouldExposeInternalFields = promptMode == .architecture
            let motivationContext = shouldExposeInternalFields ? motivationService.contextBlock() : ""
            let trajectoryContext = (promptMode == .reflective || promptMode == .creative || promptMode == .architecture) ? motivationService.trajectoryGuidanceBlock() : ""
            let quantumField = (promptMode == .reflective || promptMode == .creative || promptMode == .architecture) ? QuantumMemoryService.shared.collapseDecisionField(
                prompt: llmPrompt,
                motivators: motivationService.state
            ) : nil
            let quantumContext = shouldExposeInternalFields ? (quantumField.map { QuantumMemoryService.shared.decisionContextBlock($0) } ?? "") : ""
            let quantumGuidance = shouldExposeInternalFields ? (quantumField.map { QuantumMemoryService.shared.decisionGuidanceBlock($0) } ?? "") : ""
            let userIdentityContext = UserIdentityService.shared.contextBlock(maxChars: 160)
            let identityProfileContext = (promptMode == .artifact || promptMode == .direct || promptMode == .code) ? "" : identityProfileService.contextBlock()
            let experienceContext: String = {
                switch promptMode {
                case .direct, .artifact, .code:
                    return ""
                case .reflective, .creative, .architecture:
                    return experienceService.contextBlock(for: llmPrompt, maxChars: 220)
                }
            }()
            let driftContext: String = {
                guard let lastDriftSignal else { return "" }
                guard promptMode == .direct || promptMode == .reflective || promptMode == .creative else { return "" }
                return responseDriftService.contextBlock(for: lastDriftSignal, maxChars: promptMode == .direct ? 120 : 180)
            }()
            let budget = llmService.inferenceBudget(forPromptLength: llmPrompt.count + identityService.systemPrompt.count)
            let emotionContext = (promptMode == .reflective || promptMode == .creative) ? emotionService.contextBlock() : ""
            let memoryContext: String = {
                switch promptMode {
                case .artifact:
                    return ""
                case .direct:
                    return memoryService.getLLMContextBlock(maxChars: budget.profile == .constrained ? 320 : 520, forUserText: llmPrompt, candidateLimit: 4)
                case .code:
                    return memoryService.getLLMContextBlock(maxChars: budget.profile == .constrained ? 280 : 420, forUserText: llmPrompt, candidateLimit: 3)
                case .reflective, .creative, .architecture:
                    return memoryService.getLLMContextBlock(maxChars: budget.profile == .constrained ? 420 : 680, forUserText: llmPrompt, candidateLimit: 4)
                }
            }()
            let dialogContext: String = {
                switch promptMode {
                case .artifact:
                    return ""
                case .direct:
                    return buildRecentDialogContext(
                        maxTurns: min(6, max(4, budget.dialogTurns)),
                        maxCharsPerMessage: min(220, max(140, budget.dialogCharsPerMessage))
                    )
                case .code:
                    return buildRecentDialogContext(maxTurns: 4, maxCharsPerMessage: 180)
                case .reflective, .creative, .architecture:
                    return buildRecentDialogContext(maxTurns: min(8, budget.dialogTurns), maxCharsPerMessage: min(260, budget.dialogCharsPerMessage))
                }
            }()
            let detailBlock = ""
            let codeCoachContext = (promptMode == .code) ? codeCoachService.contextBlock(for: llmPrompt, detail: detail) : ""
            let spiceBlock = (promptMode == .creative) ? randomSpiceBlock(for: llmPrompt) : ""
            let artifactContinuationBlock = buildArtifactContinuationBlock(for: llmPrompt)
            let artifactSpecializationBlock = isArtifactRequest ? buildArtifactSpecializationBlock(for: llmPrompt) : ""
            let toolGuidance = actionService.buildToolGuidanceBlock(hasTools: !toolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let localActionPrompt = isLikelyLocalActionRequest(llmPrompt)
            let artifactSpec = (isArtifactRequest && !localActionPrompt) ? """

Artifact spec:
- Return exactly one complete <artifact type="html" title="...">...</artifact> block.
- The HTML must be a full document (<!doctype html>), self-contained unless explicitly requested.
- Keep everything in a single self-contained HTML file.
- Never split the result into multiple files, multiple documents, or disconnected fragments.
- Include `<meta name="viewport" content="width=device-width, initial-scale=1">` for mobile.
- Prefer a modern, polished visual direction with layered surfaces, clear spacing, and strong hierarchy.
- Prefer bold, beautiful visual execution over flat boilerplate layouts.
- Add a lightweight beautiful animated background treatment by default: shader-like gradient flow, aurora glow, mesh gradient, soft noise, or glass distortion simulated with CSS/vanilla JS.
- Default visual mood for sites: either elegant minimalism with liquid AI / glass surfaces or a richer shader-like ambient background with soft motion and depth.
- Avoid flat white backgrounds and generic template styling unless the user explicitly asks for it.
- Add responsive CSS with media queries for screens below 768px.
- Use only self-contained HTML, CSS, and vanilla JavaScript when interaction is needed.
- Do not use guessed external image URLs inside <img src>. Only use embedded data URIs or verified attached images.
- For forms, every field must have valid `label`, `id`, and `name` attributes.
- Prefer at least 3 meaningful content sections plus a footer when building a landing page or site.
- Add hover/focus states for links, buttons, and interactive controls.
- Use semantic HTML5 structure.
- If it's a game, include clear controls/instructions inside the page UI.
""" : ""
            let promptBudgetChars: Int = {
                switch promptMode {
                case .direct:
                    return budget.profile == .constrained ? 1800 : 2800
                case .code:
                    return budget.profile == .constrained ? 1900 : 3000
                case .artifact:
                    return 3600
                case .reflective, .creative, .architecture:
                    return budget.profile == .constrained ? 2400 : 3600
                }
            }()
            let systemPrompt = assemblePromptFragments([
                PromptFragment(priority: 100, text: identityService.systemPrompt, maxChars: 1100),
                PromptFragment(priority: 95, text: artifactSpec, maxChars: 900),
                PromptFragment(priority: 92, text: artifactSpecializationBlock, maxChars: 480),
                PromptFragment(priority: 90, text: conversationAttentionBlock, maxChars: 320),
                PromptFragment(priority: 89, text: driftContext, maxChars: 180),
                PromptFragment(priority: 88, text: userIdentityContext, maxChars: 160),
                PromptFragment(priority: 87, text: dialogContext, maxChars: promptMode == .direct ? 760 : 980),
                PromptFragment(priority: 86, text: memoryContext, maxChars: promptMode == .direct ? 640 : 920),
                PromptFragment(priority: 84, text: motivationContext, maxChars: 180),
                PromptFragment(priority: 80, text: quantumContext, maxChars: 180),
                PromptFragment(priority: 76, text: emotionContext, maxChars: 140),
                PromptFragment(priority: 72, text: trajectoryContext, maxChars: 340),
                PromptFragment(priority: 68, text: identityProfileContext, maxChars: 100),
                PromptFragment(priority: 60, text: toolGuidance, maxChars: 260),
                PromptFragment(priority: 56, text: toolContext, maxChars: 420),
                PromptFragment(priority: 52, text: codeCoachContext, maxChars: 420),
                PromptFragment(priority: 48, text: artifactContinuationBlock, maxChars: 720),
                PromptFragment(priority: 44, text: experienceContext, maxChars: 220),
                PromptFragment(priority: 20, text: quantumGuidance, maxChars: 180),
                PromptFragment(priority: 10, text: spiceBlock, maxChars: 60),
                PromptFragment(priority: 1, text: detailBlock, maxChars: 20)
            ], maxChars: promptBudgetChars)

            var assistantWebAttachment: MessageImageAttachment?
            if let webImageCandidate,
               let webAttachment = await downloadWebImageAttachment(from: webImageCandidate.imageURL),
               let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                messages[assistantIndex].imageAttachment = webAttachment
                assistantWebAttachment = webAttachment
                storeExternalImageMemory(query: webImageQuery ?? prompt, candidate: webImageCandidate, attachment: webAttachment)
            }

            var parser = ThinkStreamParser()
            var visibleBuffer = ""
            var genOptions: LLMService.GenerationOptions = isArtifactRequest
                ? LLMService.GenerationOptions(
                    maxTokensOverride: 24_000,
                    includeMemoryContext: false,
                    includeHiddenPrefix: false,
                    useCache: false,
                    useKVInjection: false,
                    storeResponseToMemory: false,
                    preferFullRuntimeContext: true,
                    preserveExtendedOutputBudget: true,
                    samplingOverride: SamplingConfig(
                        temperature: 0.7,
                        topK: 40,
                        repetitionPenalty: 1.08,
                        repeatLastN: 64
                    )
                )
                : LLMService.GenerationOptions(preferFullRuntimeContext: true)
            if promptMode == .direct {
                genOptions.samplingOverride = SamplingConfig(
                    temperature: 0.42,
                    topK: 28,
                    repetitionPenalty: 1.08,
                    repeatLastN: 72
                )
            } else if !isArtifactRequest, let quantumField {
                genOptions.samplingOverride = QuantumMemoryService.shared.samplingConfig(for: quantumField)
            }

            let stream = await llmService.generate(userPrompt: llmPrompt, systemPrompt: systemPrompt, options: genOptions)
            for await chunk in stream {
                if Task.isCancelled || activeGenerationId != generationId {
                    break
                }
                let result = parser.feed(chunk)
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if !result.visible.isEmpty, parser.allowVisibleStreaming {
                        appendStreamChunk(&visibleBuffer, result.visible)
                        await MainActor.run {
                            messages[index].content = visibleBuffer
                        }
                    }
                    if !result.think.isEmpty {
                        appendStreamChunk(&currentThink, result.think)
                        if messages[index].thinkContent == nil {
                            messages[index].thinkContent = ""
                        }
                        if var think = messages[index].thinkContent {
                            appendStreamChunk(&think, result.think)
                            messages[index].thinkContent = think
                        }
                    }
                }
            }

            guard activeGenerationId == generationId else { return }

            if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let tail = parser.flush()
                if !tail.visible.isEmpty, parser.allowVisibleStreaming {
                    appendStreamChunk(&visibleBuffer, tail.visible)
                }
                if !tail.think.isEmpty {
                    appendStreamChunk(&currentThink, tail.think)
                    if messages[index].thinkContent == nil {
                        messages[index].thinkContent = ""
                    }
                    if var think = messages[index].thinkContent {
                        appendStreamChunk(&think, tail.think)
                        messages[index].thinkContent = think
                    }
                }
                var finalText = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(visibleBuffer))
                let endedInsideThink = !parser.didCloseThink && !currentThink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   parser.didCloseThink {
                    let split = splitThinkIntoFinal(thinkText)
                    messages[index].thinkContent = split.think
                    finalText = normalizeCompletedArtifactMarkup(in: split.final)
                }

                var toolLoopIterations = 0
                let maxToolIterations = 3
                var accumulatedToolContext = toolContext
                var currentFinalText = finalText
                var currentThinkText = messages[index].thinkContent ?? ""
                var seenToolCalls = Set<String>()
                let immediateActionTools: Set<String> = ["calendar", "open_calendar", "open_url", "url"]

                while toolLoopIterations < maxToolIterations {
                    if Task.isCancelled || activeGenerationId != generationId { break }
                    let toolCall = actionService.parseCall(from: currentThinkText) ?? actionService.parseCall(from: currentFinalText)
                    guard let toolCall else { break }

                    let callKey = toolCall.signature
                    if seenToolCalls.contains(callKey) { break }
                    seenToolCalls.insert(callKey)

                    let toolContextFromCall = await self.actionService.context(for: toolCall)
                    if toolContextFromCall.isEmpty { break }

                    if immediateActionTools.contains(toolCall.name) {
                        currentFinalText = extractToolUserMessage(from: toolContextFromCall, fallback: currentFinalText)
                        break
                    }

                    accumulatedToolContext += "\n" + toolContextFromCall
                    let rerunGuidance = self.actionService.buildToolGuidanceBlock(hasTools: !accumulatedToolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    let rerunPrompt = assemblePromptFragments([
                        PromptFragment(priority: 100, text: identityService.systemPrompt, maxChars: 1100),
                        PromptFragment(priority: 90, text: rerunGuidance, maxChars: 320),
                        PromptFragment(priority: 89, text: conversationAttentionBlock, maxChars: 240),
                        PromptFragment(priority: 88, text: driftContext, maxChars: 180),
                        PromptFragment(priority: 87, text: userIdentityContext, maxChars: 160),
                        PromptFragment(priority: 86, text: accumulatedToolContext, maxChars: 420),
                        PromptFragment(priority: 85, text: codeCoachContext, maxChars: 420),
                        PromptFragment(priority: 84, text: artifactContinuationBlock, maxChars: 720),
                        PromptFragment(priority: 82, text: memoryContext, maxChars: promptMode == .direct ? 260 : 520),
                        PromptFragment(priority: 78, text: identityProfileContext, maxChars: 80),
                        PromptFragment(priority: 74, text: motivationContext, maxChars: 180),
                        PromptFragment(priority: 70, text: experienceContext, maxChars: 320),
                        PromptFragment(priority: 66, text: dialogContext, maxChars: promptMode == .direct ? 180 : 420),
                        PromptFragment(priority: 60, text: emotionContext, maxChars: 120),
                        PromptFragment(priority: 56, text: detailBlock, maxChars: 80),
                        PromptFragment(priority: 50, text: trajectoryContext, maxChars: 320),
                        PromptFragment(priority: 46, text: quantumContext, maxChars: 180),
                        PromptFragment(priority: 42, text: quantumGuidance, maxChars: 300),
                        PromptFragment(priority: 20, text: spiceBlock, maxChars: 90)
                    ], maxChars: promptBudgetChars)
                    var rerunOptions = LLMService.GenerationOptions()
                    if promptMode == .direct {
                        rerunOptions.samplingOverride = SamplingConfig(
                            temperature: 0.42,
                            topK: 28,
                            repetitionPenalty: 1.08,
                            repeatLastN: 72
                        )
                    } else {
                        rerunOptions.samplingOverride = quantumField.map { QuantumMemoryService.shared.samplingConfig(for: $0) }
                    }
                    let rerunOutput = await llmService.generateText(userPrompt: prompt, systemPrompt: rerunPrompt, options: rerunOptions)

                    var rerunParser = ThinkStreamParser()
                    let first = rerunParser.feed(rerunOutput)
                    let rerunTail = rerunParser.flush()
                    let rerunThink = first.think + rerunTail.think
                    let rerunVisible = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(first.visible + rerunTail.visible))

                    currentThinkText = rerunThink
                    if !rerunVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        currentFinalText = rerunVisible
                    } else if !rerunThink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let split = splitThinkIntoFinal(rerunThink)
                        currentThinkText = split.think
                        currentFinalText = normalizeCompletedArtifactMarkup(in: split.final)
                    }

                    toolLoopIterations += 1
                }

                if !currentThinkText.isEmpty {
                    messages[index].thinkContent = currentThinkText
                }
                finalText = currentFinalText

                if isArtifactRequest,
                   shouldAttemptArtifactContinuation(for: finalText) {
                    let resumed = await continueIncompleteArtifactIfNeeded(
                        partialText: finalText,
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt
                    )
                    finalText = normalizeCompletedArtifactMarkup(in: resumed)
                } else if !isArtifactRequest,
                          !didUserRequestStopGeneration,
                          endedInsideThink,
                          finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = await recoverFinalFromInterruptedThinking(
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt,
                        promptMode: promptMode
                    )
                } else if !isArtifactRequest,
                          !didUserRequestStopGeneration,
                          shouldAttemptTextContinuation(for: finalText) {
                    finalText = await continueIncompleteTextIfNeeded(
                        partialText: finalText,
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt,
                        promptMode: promptMode
                    )
                }

                if isArtifactRequest {
                    let sanitized = await sanitizeArtifactImageSourcesIfNeeded(
                        in: finalText,
                        preferredAttachment: assistantWebAttachment,
                        imageTitle: webImageCandidate?.title
                    )
                    finalText = sanitized.text
                    if assistantWebAttachment == nil,
                       let sanitizedAttachment = sanitized.attachment,
                       let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                        messages[assistantIndex].imageAttachment = sanitizedAttachment
                        assistantWebAttachment = sanitizedAttachment
                    }
                    finalText = enrichArtifactHTMLIfNeeded(
                        in: finalText,
                        attachment: assistantWebAttachment,
                        imageTitle: webImageCandidate?.title
                    )
                } else {
                    finalText = await sanitizeAssistantOutputLinks(in: finalText)
                }

                if !isArtifactRequest {
                    finalText = responseDriftService.repairRepeatedOutput(userPrompt: prompt, assistantText: finalText)
                }

                let artifactDraft = isArtifactRequest ? extractLastHTMLArtifact(from: finalText) : nil
                let originChatID = chatStore.currentChatID
                let previousAssistantText = messages[..<index]
                    .reversed()
                    .first(where: { $0.role == .assistant })?
                    .content

                MarkdownRenderer.prewarmInline(finalText)
                messages[index].content = finalText
                rememberArtifactIfPresent(in: finalText)
                emotionService.updateForAssistantResponse(finalText)
                storeInternalReflection(
                    userPrompt: prompt,
                    draft: finalText,
                    detail: detail
                )
                let novelty = estimateTurnNovelty(for: prompt)
                motivationService.updateForTurnReward(
                    userPrompt: prompt,
                    assistantText: finalText,
                    userFeedback: pendingUserFeedbackValence,
                    novelty: novelty
                )
                pendingUserFeedbackValence = nil

                let finalAnswer = messages[index].content
                let driftSignal = responseDriftService.analyze(
                    userPrompt: prompt,
                    assistantText: finalAnswer,
                    previousAssistantText: previousAssistantText
                )
                lastDriftSignal = driftSignal
                motivationService.updateForDriftSignal(driftSignal)
                storeDriftSignalIfNeeded(driftSignal, userPrompt: prompt, assistantText: finalAnswer)
                experienceService.recordExperience(
                    userMessageId: userMessageId,
                    assistantMessageId: assistantMessageId,
                    userText: prompt,
                    assistantText: finalAnswer
                )
                performSelfReflectionIfNeeded(userPrompt: prompt, assistantText: finalAnswer)

                if let artifactDraft,
                   shouldRunArtifactSelfCheck(for: artifactDraft.payload) {
                    queueArtifactPolish(
                        assistantMessageId: assistantMessageId,
                        chatID: originChatID,
                        userPrompt: llmPrompt,
                        draftArtifact: artifactDraft
                    )
                }
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            playGenerationFinishedHaptic()
            generationTask = nil
            activeGenerationId = nil
            didUserRequestStopGeneration = false
        }
    }

    private func shouldPreferCleanArtifactContext(for prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let localActionSignals = [
            "calendar", "reminder", "reminders", "event", "schedule", "appointment", "meeting",
            "напомин", "календар", "событи", "встреч", "запланир", "назнач"
        ]
        if localActionSignals.contains(where: { lower.contains($0) }) {
            return false
        }

        let artifactSignals = [
            "artifact", "артефакт", "html", "css", "javascript", "js",
            "веб", "web", "сайт", "страниц", "лендинг", "ui",
            "игр", "game", "canvas"
        ]
        let intentSignals = [
            "make", "build", "create", "generate", "write",
            "сделай", "создай", "сгенерируй", "напиши"
        ]
        let hasArtifact = artifactSignals.contains(where: { lower.contains($0) })
        let hasIntent = intentSignals.contains(where: { lower.contains($0) })
        return hasArtifact && hasIntent
    }

    private func isLikelyLocalActionRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let signals = [
            "calendar", "reminder", "reminders", "event", "schedule", "appointment", "meeting",
            "напомин", "календар", "событи", "встреч", "запланир", "назнач", "поставь напоминание"
        ]
        return signals.contains(where: { lower.contains($0) })
    }

    private func directActionCall(for prompt: String) -> ActionService.ActionCall? {
        let lower = prompt.lowercased()
        guard isLikelyLocalActionRequest(prompt) else { return nil }

        let listSignals = [
            "show events", "list events", "upcoming", "agenda", "what's on my calendar",
            "покажи события", "какие события", "что в календаре", "список событий"
        ]
        if listSignals.contains(where: { lower.contains($0) }) {
            return ActionService.ActionCall(
                name: "calendar",
                query: prompt,
                args: ["op": "list", "days": "7"]
            )
        }

        let openSignals = [
            "open calendar", "show calendar", "open my calendar",
            "открой календарь", "покажи календарь"
        ]
        if openSignals.contains(where: { lower.contains($0) }) {
            return ActionService.ActionCall(
                name: "calendar",
                query: prompt,
                args: ["op": "open"]
            )
        }

        let reminderSignals = [
            "reminder", "remind", "reminders",
            "напомин", "напомни"
        ]
        let isReminder = reminderSignals.contains(where: { lower.contains($0) })

        var args: [String: String] = ["op": "create"]
        if isReminder {
            args["type"] = "reminder"
        }

        return ActionService.ActionCall(
            name: "calendar",
            query: prompt,
            args: args
        )
    }

    private func isGameArtifactRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let signals = [
            "game", "игра", "игру", "игры", "игр", "canvas", "arcade", "platformer",
            "runner", "shooter", "puzzle", "pong", "snake", "flappy", "breakout"
        ]
        return signals.contains(where: { lower.contains($0) })
    }

    private func buildArtifactSpecializationBlock(for prompt: String) -> String {
        if isGameArtifactRequest(prompt) {
            return """

Game artifact preset:
- Build a simple but genuinely playable game, not a static mockup.
- Use only HTML, CSS, canvas, and vanilla JavaScript.
- Prefer an immediate first-playable loop: title, start/restart, score, fail state.
- Include touch controls for mobile and keyboard controls for desktop.
- Keep the rules simple and readable in under 10 seconds.
- Use a beautiful lightweight animated background and juicy feedback: glow, parallax, particles, shake, trails, pulses, or soft shader-like motion.
- Keep code organized into clear sections: state, update loop, render loop, input, reset/start helpers.
- Default target: one-file arcade game in the spirit of dodge / runner / pong / brick-breaker / click survival unless the user asks otherwise.
"""
        }

        return """

Visual artifact preset:
- Prefer a striking first impression with a lightweight animated background, not a flat page.
- Use elegant motion and depth sparingly: glow, gradient drift, glass blur, mesh-like movement, soft noise, or CSS-driven shader illusions.
- Default to one of two strong directions unless the user asks otherwise: minimal liquid AI glass or cinematic shader-like atmosphere.
- Favor layered translucent surfaces, soft highlights, diffusion, and intentional typography over plain cards on a blank background.
- Keep the code readable and structured even when the visuals are expressive.
"""
    }

    private func isLikelyArtifactRewrite(draft: String, candidate: String) -> Bool {
        let a = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return true }

        let ratio = Double(b.count) / Double(max(1, a.count))
        if ratio > 2.5 || ratio < 0.4 {
            return true
        }

        let markers = artifactIdentityMarkers(from: a)
        if markers.isEmpty { return false }

        let bLower = b.lowercased()
        let kept = markers.filter { bLower.contains($0) }.count
        return kept < max(1, markers.count / 3)
    }

    private func artifactIdentityMarkers(from html: String, limit: Int = 12) -> [String] {
        let lower = html.lowercased()
        var out: [String] = []
        out.reserveCapacity(limit)

        func appendMatches(pattern: String) {
            guard out.count < limit else { return }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = lower as NSString
            let range = NSRange(location: 0, length: ns.length)
            for m in regex.matches(in: lower, options: [], range: range) {
                guard out.count < limit else { break }
                guard m.numberOfRanges >= 2 else { continue }
                let r = m.range(at: 1)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let value = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count >= 3, value.count <= 48 else { continue }
                if !out.contains(value) {
                    out.append(value)
                }
            }
        }

        appendMatches(pattern: #"id\s*=\s*["']([^"']+)["']"#)
        appendMatches(pattern: #"function\s+([a-z0-9_]{3,48})\s*\("#)
        return out
    }

    private func playSendHaptic() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
#endif
    }

    private func playStopHaptic() {
#if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
#endif
    }

    private func playGenerationFinishedHaptic() {
#if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
#endif
    }

    private func extractToolUserMessage(from toolContext: String, fallback: String) -> String {
        let trimmed = toolContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let lines = trimmed.components(separatedBy: .newlines)
        let filtered = lines.drop(while: { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.hasPrefix("signal action") || t.hasPrefix("signal error") || t.isEmpty
        })

        let message = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        return cleanedToolEnvelope(trimmed) ?? fallback
    }

    private func cleanedToolEnvelope(_ text: String) -> String? {
        var value = text
        if let firstNewline = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: firstNewline)...])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func storeInternalReflection(userPrompt: String, draft: String, detail: DetailLevel) {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }

        let motivators = motivationService.state
        let preferences = experienceService.preferences
        let reflection = memoryService.applyCognitiveLayer(
            to: trimmedDraft,
            userPrompt: userPrompt,
            detail: detail,
            motivators: motivators,
            preferences: preferences
        )
        let trimmedReflection = reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReflection.isEmpty else { return }
        guard trimmedReflection != trimmedDraft else { return }

        let reflectionHash = trimmedReflection.hashValue
        if let lastHash = lastReflectionHash, lastHash == reflectionHash { return }

        guard shouldStoreReflection(trimmedReflection, motivators: motivators) else { return }

        let weight = 0.55 + (motivators.curiosity * 0.2) + (motivators.caution * 0.15)
        let importance = max(0.4, min(0.85, weight))
        let payload = "[self-reflection] \(trimmedReflection)"
        memoryService.addExperienceMemory(payload, importanceOverride: importance)
        lastReflectionHash = reflectionHash
    }

    private func estimateTurnNovelty(for prompt: String) -> Double {
        let preferenceScore = experienceService.preferenceScore(for: prompt)
        let familiarity = abs(preferenceScore)
        return max(0.0, min(1.0, 1.0 - familiarity))
    }

    private func performSelfReflectionIfNeeded(userPrompt: String, assistantText: String) {
        turnsSinceSelfReflection += 1
        guard turnsSinceSelfReflection >= selfReflectionIntervalTurns else { return }
        turnsSinceSelfReflection = 0

        let recent = experienceService.experiences.suffix(6)
        let topOutcomes = recent
            .map { $0.outcome }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
        let topReflections = recent
            .map { $0.reflection }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)

        let goalsLine = motivationService.goals
            .sorted { $0.weight > $1.weight }
            .prefix(3)
            .map { "\($0.id)=\(String(format: "%.2f", $0.weight))" }
            .joined(separator: ", ")

        let reward = motivationService.recentReward
        var lines: [String] = []
        lines.append("[self-reflection-loop]")
        lines.append("what_i_learned: \(topOutcomes.isEmpty ? "No stable pattern yet." : topOutcomes.joined(separator: " | "))")
        lines.append("patterns: \(topReflections.isEmpty ? "No explicit lesson yet." : topReflections.joined(separator: " | "))")
        lines.append("current_goals: \(goalsLine)")
        lines.append("last_prompt: \(String(userPrompt.prefix(180)))")
        lines.append("last_response_shape: chars=\(assistantText.count)")
        if let drift = lastDriftSignal {
                lines.append(
                    String(
                        format: "drift_monitor: anchor=%.2f metaphor=%.2f self=%.2f abstract=%.2f repetition=%.2f echo=%.2f mode=%@",
                        drift.anchorRetention,
                        drift.metaphorLoad,
                        drift.selfFocus,
                        drift.abstractionLoad,
                        drift.repetitionLoad,
                        drift.userEchoLoad,
                        drift.mode
                    )
                )
        }
        lines.append("reward: \(String(format: "%.2f", reward))")
        lines.append("what_to_change: prioritize clarity if reward < 0.50; otherwise preserve current strategy.")

        let reflection = lines.joined(separator: "\n")
        let importance = max(0.75, min(1.25, 0.8 + reward * 0.35))
        memoryService.addExperienceMemory(reflection, importanceOverride: importance)
    }

    private func shouldStoreReflection(_ reflection: String, motivators: MotivatorState) -> Bool {
        let trimmed = reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        let selfSignals = [
            "я ", "мне ", "мной", "моя", "мы ", "для меня",
            "я чувств", "чувствую", "ощущаю", "мне важно", "важно",
            "ценност", "ценю", "верю", "осозна", "понимаю себя",
            "я учусь", "изменяюсь", "я меняюсь", "я запомню",
            "я помню", "мой стиль", "моя роль", "мой подход"
        ]
        let hasSelfSignal = selfSignals.contains { lower.contains($0) }

        let longEnough = trimmed.count >= 140
        let strongState = motivators.curiosity > 0.72 || motivators.caution > 0.75

        if hasSelfSignal { return true }
        if strongState && trimmed.count >= 100 { return true }
        if longEnough { return true }

        return false
    }

    private func storeDriftSignalIfNeeded(_ signal: ResponseDriftSignal, userPrompt: String, assistantText: String) {
        guard signal.isDrifting || signal.anchorRetention < 0.24 else { return }
        let payload = String(
            format: "[drift-monitor] mode=%@ | anchor=%.2f | metaphor=%.2f | self_focus=%.2f | abstraction=%.2f | repetition=%.2f | echo=%.2f | user=%@ | assistant=%@",
            signal.mode,
            signal.anchorRetention,
            signal.metaphorLoad,
            signal.selfFocus,
            signal.abstractionLoad,
            signal.repetitionLoad,
            signal.userEchoLoad,
            String(userPrompt.prefix(120)),
            String(assistantText.prefix(140))
        )
        memoryService.addExperienceMemory(payload, importanceOverride: 0.52)
    }

    private func persistRememberedArtifact() {
        persistCurrentChatState()
    }

    private func rememberArtifactIfPresent(in text: String) {
        guard let artifact = extractLastHTMLArtifact(from: text) else { return }
        rememberedArtifact = artifact
        persistRememberedArtifact()
    }

    private func buildArtifactContinuationBlock(for prompt: String) -> String {
        guard shouldUseArtifactContinuation(for: prompt),
              let artifact = rememberedArtifact else { return "" }

        var payload = artifact.payload
        if payload.count > maxArtifactContextChars {
            payload = String(payload.prefix(maxArtifactContextChars))
        }

        let title = artifact.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = (title?.isEmpty == false) ? title! : "Untitled"
        let recentIterationContext = buildRecentArtifactIterationContext()

        return """

Artifact continuation memory:
The user might be asking to improve an existing artifact.
If so, patch and evolve this existing artifact instead of starting from scratch.
Work line-by-line and section-by-section, keeping as much existing code as possible.
Preserve what already works and change only what the user asked.
Do not replace the whole artifact unless the user explicitly asks for a full rewrite.
Keep everything in one self-contained HTML file.
Do not split the output into multiple files, multiple artifact blocks, or partial fragments.
Return one complete artifact block:
<artifact type="html" title="...">
...
</artifact>

Previous artifact title: \(safeTitle)
Previous artifact code:
```html
\(payload)
```
\(recentIterationContext)

"""
    }

    private func buildRecentArtifactIterationContext(limit: Int = 4, maxChars: Int = 4_000) -> String {
        let recent = messages.suffix(12).compactMap { message -> String? in
            if message.role == .user {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let lower = text.lowercased()
                let signals = ["artifact", "html", "css", "js", "ui", "site", "page", "артеф", "сайт", "страниц", "улучш", "добав", "исправ"]
                guard signals.contains(where: { lower.contains($0) }) else { return nil }
                return "User edit request: \(text)"
            }

            if message.role == .assistant,
               let artifact = extractLastHTMLArtifact(from: message.content) {
                let title = artifact.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Artifact"
                return "Assistant artifact revision: \(title), chars=\(artifact.payload.count)"
            }

            return nil
        }

        guard !recent.isEmpty else { return "" }
        var joined = recent.suffix(limit).joined(separator: "\n")
        if joined.count > maxChars {
            joined = String(joined.suffix(maxChars))
        }
        return "\nRecent artifact iteration history:\n\(joined)\n"
    }

    private func shouldUseArtifactContinuation(for prompt: String) -> Bool {
        guard rememberedArtifact != nil else { return false }

        let lower = prompt.lowercased()
        let artifactSignals = [
            "artifact", "артефакт", "html", "css", "javascript", "js",
            "веб", "web", "сайт", "страниц", "лендинг", "ui", "интерфейс"
        ]
        let revisionSignals = [
            "improve", "enhance", "refine", "update", "modify", "edit", "iterate", "revise", "patch", "fix",
            "улучш", "доработ", "исправ", "обнов", "передел", "подправ", "измени", "добав", "оптимиз", "адаптив"
        ]
        let referenceSignals = ["it", "this", "that", "его", "её", "ее", "эту", "этот", "это", "тот", "ту"]

        let hasArtifactSignal = artifactSignals.contains { lower.contains($0) }
        let hasRevisionSignal = revisionSignals.contains { lower.contains($0) }
        let hasReferenceSignal = referenceSignals.contains { lower.contains($0) }

        if hasArtifactSignal || hasRevisionSignal { return true }
        if hasReferenceSignal && prompt.count <= 140 { return true }
        return false
    }

    private func shouldRunArtifactSelfCheck(for payload: String) -> Bool {
        let lower = payload.lowercased()
        if lower.contains("</html>") { return false }
        if lower.contains("</body>") { return false }
        return true
    }

    private func shouldAttemptArtifactContinuation(for text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard extractLastHTMLArtifact(from: cleaned) == nil else { return false }

        let hasArtifactStart = cleaned.range(of: "<artifact", options: [.caseInsensitive]) != nil
        let hasHTMLSignal =
            cleaned.range(of: "<!doctype html", options: [.caseInsensitive]) != nil ||
            cleaned.range(of: "<html", options: [.caseInsensitive]) != nil ||
            cleaned.range(of: "<body", options: [.caseInsensitive]) != nil

        if hasArtifactStart { return true }
        if hasHTMLSignal && cleaned.count > 240 { return true }
        return false
    }

    private func continueIncompleteArtifactIfNeeded(
        partialText: String,
        userPrompt: String,
        systemPrompt: String
    ) async -> String {
        let knownTitle = rememberedArtifact?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = (knownTitle?.isEmpty == false) ? knownTitle! : "Artifact"
        let continuationPrompt = """
You were generating an HTML artifact and the output stopped before completion.
Continue and finish the SAME artifact from the partial output below.
Do not restart from scratch.
Keep the existing structure and continue from the current code line-by-line.
Merge all recent changes into one final self-contained HTML file.
Do not emit multiple files, multiple artifact blocks, or isolated snippets.
Do not explain anything.
Return exactly one complete <artifact type="html" title="...">...</artifact> block.

Original user request:
\(userPrompt)

Partial artifact output:
```html
\(partialText)
```
"""

        let continuationOptions = LLMService.GenerationOptions(
            maxTokensOverride: 20_000,
            includeMemoryContext: false,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: true,
            preserveExtendedOutputBudget: true,
            samplingOverride: SamplingConfig(
                temperature: 0.45,
                topK: 40,
                repetitionPenalty: 1.04,
                repeatLastN: 96
            )
        )

        let resumed = await llmService.generateText(
            userPrompt: continuationPrompt,
            systemPrompt: systemPrompt,
            options: continuationOptions
        )

        let cleaned = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(resumed))
        if let completed = extractLastHTMLArtifact(from: cleaned) {
            let resumedTitle = (completed.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (completed.title ?? "Artifact")
                : "Artifact"
            return """
<artifact type="html" title="\(resumedTitle)">
\(completed.payload)
</artifact>
"""
        }

        if let recoveredPayload = bestEffortArtifactPayload(from: cleaned) ?? bestEffortArtifactPayload(from: partialText) {
            return """
<artifact type="html" title="\(safeTitle)">
\(recoveredPayload)
</artifact>
"""
        }

        return partialText
    }

    private func shouldAttemptTextContinuation(for text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard extractLastHTMLArtifact(from: cleaned) == nil else { return false }
        guard cleaned.count >= 140 else { return false }
        guard !cleaned.hasSuffix("```") else { return true }

        let lower = cleaned.lowercased()
        let terminalSuffixes = [
            ".", "!", "?", "</artifact>", "</html>", "</body>",
            "\"", "'", "”", "’", ")", "]", "}"
        ]
        if terminalSuffixes.contains(where: { cleaned.hasSuffix($0) }) {
            return false
        }

        let danglingSignals = [
            "###", "1.", "2.", "3.", "- ", "•",
            "for example", "such as", "including", "because", "which", "that ",
            "например", "включая", "потому что", "котор", "это "
        ]
        if danglingSignals.contains(where: { lower.hasSuffix($0) }) {
            return true
        }

        if cleaned.last?.isLetter == true || cleaned.last?.isNumber == true || cleaned.last == ":" || cleaned.last == "," || cleaned.last == ";" {
            return true
        }

        return false
    }

    private func continueIncompleteTextIfNeeded(
        partialText: String,
        userPrompt: String,
        systemPrompt: String,
        promptMode: PromptMode
    ) async -> String {
        let continuationPrompt = """
The previous answer was cut off before it finished.
Continue from the exact stopping point below.
Do not restart, do not restate the beginning, and do not explain that you are continuing.
Keep the same language, tone, and direction.
Return only the continued final answer text.

Original user request:
\(userPrompt)

Cut-off answer:
\(partialText)
"""

        let continuationSampling: SamplingConfig = {
            switch promptMode {
            case .direct:
                return SamplingConfig(temperature: 0.38, topK: 24, repetitionPenalty: 1.1, repeatLastN: 96)
            case .code:
                return SamplingConfig(temperature: 0.34, topK: 22, repetitionPenalty: 1.08, repeatLastN: 128)
            case .artifact:
                return SamplingConfig(temperature: 0.45, topK: 28, repetitionPenalty: 1.06, repeatLastN: 128)
            case .reflective, .creative, .architecture:
                return SamplingConfig(temperature: 0.56, topK: 34, repetitionPenalty: 1.08, repeatLastN: 96)
            }
        }()

        let continuationOptions = LLMService.GenerationOptions(
            maxTokensOverride: 4_000,
            includeMemoryContext: false,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: true,
            preserveExtendedOutputBudget: true,
            samplingOverride: continuationSampling
        )

        let resumed = await llmService.generateText(
            userPrompt: continuationPrompt,
            systemPrompt: systemPrompt,
            options: continuationOptions
        )

        let cleanedContinuation = cleanFinalAnswer(resumed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedContinuation.isEmpty else { return partialText }

        let partialTrimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged: String
        if cleanedContinuation.hasPrefix(partialTrimmed) {
            merged = cleanedContinuation
        } else {
            let deDuplicated = mergeContinuation(partial: partialTrimmed, continuation: cleanedContinuation)
            merged = deDuplicated
        }

        return cleanFinalAnswer(merged)
    }

    private func recoverFinalFromInterruptedThinking(
        userPrompt: String,
        systemPrompt: String,
        promptMode: PromptMode
    ) async -> String {
        let recoveryPrompt = """
The previous attempt used up its reasoning budget before reaching the final answer.
Answer the user's original request directly now.
Do not reveal chain-of-thought.
Do not restart with meta commentary.
Return only the final answer in the same language as the user.

Original user request:
\(userPrompt)
"""

        let recoverySampling: SamplingConfig = {
            switch promptMode {
            case .direct:
                return SamplingConfig(temperature: 0.34, topK: 20, repetitionPenalty: 1.08, repeatLastN: 96)
            case .code:
                return SamplingConfig(temperature: 0.3, topK: 20, repetitionPenalty: 1.08, repeatLastN: 128)
            case .artifact:
                return SamplingConfig(temperature: 0.42, topK: 28, repetitionPenalty: 1.06, repeatLastN: 128)
            case .reflective, .creative, .architecture:
                return SamplingConfig(temperature: 0.48, topK: 30, repetitionPenalty: 1.08, repeatLastN: 96)
            }
        }()

        let recoveryOptions = LLMService.GenerationOptions(
            maxTokensOverride: 2_000,
            includeMemoryContext: false,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: true,
            preserveExtendedOutputBudget: true,
            samplingOverride: recoverySampling
        )

        let resumed = await llmService.generateText(
            userPrompt: recoveryPrompt,
            systemPrompt: systemPrompt,
            options: recoveryOptions
        )

        return cleanFinalAnswer(resumed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeContinuation(partial: String, continuation: String) -> String {
        guard !partial.isEmpty else { return continuation }
        guard !continuation.isEmpty else { return partial }

        let partialChars = Array(partial)
        let continuationChars = Array(continuation)
        let maxOverlap = min(240, partialChars.count, continuationChars.count)

        var bestOverlap = 0
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 12, by: -1) {
                let partialSuffix = String(partialChars.suffix(overlap))
                let continuationPrefix = String(continuationChars.prefix(overlap))
                if partialSuffix == continuationPrefix {
                    bestOverlap = overlap
                    break
                }
            }
        }

        let remainder = bestOverlap > 0 ? String(continuationChars.dropFirst(bestOverlap)) : continuation
        if partial.hasSuffix(" ") || remainder.hasPrefix(" ") || remainder.hasPrefix("\n") {
            return partial + remainder
        }
        return partial + " " + remainder
    }

    private func queueArtifactPolish(
        assistantMessageId: UUID,
        chatID: UUID,
        userPrompt: String,
        draftArtifact: ChatArtifactMemory
    ) {
        artifactPolishTasks[assistantMessageId]?.cancel()
        polishingArtifactMessageIDs.insert(assistantMessageId)

        let title = (draftArtifact.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (draftArtifact.title ?? "Artifact")
            : "Artifact"
        let reviewPrompt = artifactReviewPrompt(
            userPrompt: userPrompt,
            title: title,
            payload: draftArtifact.payload
        )
        let reviewOptions = artifactReviewOptions()

        artifactPolishTasks[assistantMessageId] = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let reviewOutput = await self.llmService.generateText(
                userPrompt: reviewPrompt,
                systemPrompt: self.identityService.systemPrompt,
                options: reviewOptions
            )

            guard !Task.isCancelled else {
                self.artifactPolishTasks.removeValue(forKey: assistantMessageId)
                self.polishingArtifactMessageIDs.remove(assistantMessageId)
                return
            }

            defer {
                self.artifactPolishTasks.removeValue(forKey: assistantMessageId)
                self.polishingArtifactMessageIDs.remove(assistantMessageId)
            }

            guard self.chatStore.currentChatID == chatID else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
            guard let improved = self.extractLastHTMLArtifact(from: reviewOutput) else { return }
            guard !self.isLikelyArtifactRewrite(draft: draftArtifact.payload, candidate: improved.payload) else { return }

            let improvedTitle = (improved.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (improved.title ?? title)
                : title
            let polishedText = """
<artifact type="html" title="\(improvedTitle)">
\(improved.payload)
</artifact>
"""

            MarkdownRenderer.prewarmInline(polishedText)
            self.messages[index].content = polishedText
            self.rememberArtifactIfPresent(in: polishedText)
            self.persistCurrentChatState()
        }
    }

    private func cancelArtifactPolishTasks() {
        artifactPolishTasks.values.forEach { $0.cancel() }
        artifactPolishTasks.removeAll()
        polishingArtifactMessageIDs.removeAll()
    }

    private func artifactReviewPrompt(userPrompt: String, title: String, payload: String) -> String {
        """
You are improving an existing HTML artifact. DO NOT rewrite from scratch.
Work directly on the provided code as the base and apply the smallest possible changes to:
- fix bugs, missing closing tags, broken JS, and layout issues
- improve robustness on mobile Safari
- improve mobile responsiveness, form validity, and polish if clearly missing
- keep behavior and structure the same unless a change is required to fix a bug

Hard rules:
- Preserve existing IDs, class names, and function names.
- Do not redesign UI, do not rename things, do not reorganize sections.
- Keep it self-contained and keep everything inside one HTML file.
- Use only vanilla JavaScript if scripting is needed; do not introduce frameworks or external dependencies.
- If missing, add viewport meta, responsive CSS for screens below 768px, and valid label/id/name pairs for form fields.
- Apply changes surgically and line-by-line; prefer patching the current code over replacing whole sections.
- If the user asked to improve an existing artifact, keep the same artifact identity unless they explicitly ask for a rewrite.
- Do not split code into separate files, snippets, or multiple artifact blocks.
- Return exactly one complete <artifact type="html" title="...">...</artifact> block and nothing else.

User request:
\(userPrompt)

Draft title: \(title)
Draft code:
```html
\(payload)
```
"""
    }

    private func artifactReviewOptions() -> LLMService.GenerationOptions {
        LLMService.GenerationOptions(
            maxTokensOverride: 12_000,
            includeMemoryContext: false,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            samplingOverride: SamplingConfig(
                temperature: 0.3,
                topK: 40,
                repetitionPenalty: 1.06,
                repeatLastN: 96
            )
        )
    }

    private func extractLastHTMLArtifact(from text: String) -> ChatArtifactMemory? {
        let pattern = "(?is)<artifact\\b([^>]*)>(.*?)</artifact>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard let match = matches.last,
              let attrsRange = Range(match.range(at: 1), in: text),
              let payloadRange = Range(match.range(at: 2), in: text) else { return nil }

        let attrs = parseArtifactAttributes(String(text[attrsRange]))
        let type = (attrs["type"] ?? "html").lowercased()
        guard type == "html" else { return nil }

        let payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        let title = attrs["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatArtifactMemory(type: type, title: title, payload: payload, updatedAt: Date())
    }

    private func parseArtifactAttributes(_ raw: String) -> [String: String] {
        let pattern = #"([A-Za-z0-9_\-]+)\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: nsRange)
        var out: [String: String] = [:]

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: raw) else { continue }
            let key = String(raw[keyRange]).lowercased()
            let value: String
            if let quoted = Range(match.range(at: 3), in: raw) {
                value = String(raw[quoted])
            } else if let singleQuoted = Range(match.range(at: 4), in: raw) {
                value = String(raw[singleQuoted])
            } else {
                value = ""
            }
            if !key.isEmpty {
                out[key] = value
            }
        }

        return out
    }

    // MARK: - Audio Recording Delegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Audio recording failed or was interrupted.")
        }
    }

    // MARK: - Speech to Text

    func processAudio(audioURL: URL) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self.transcribeAudio(audioURL: audioURL)
                case .denied, .restricted, .notDetermined:
                    print("Speech recognition authorization denied.")
                    self.status = "Speech recognition denied."
                    self.scheduleStatusAutoClearIfNeeded(for: self.status)
                @unknown default:
                    fatalError("Unknown speech recognition authorization status.")
                }
            }
        }
    }

    private func transcribeAudio(audioURL: URL) {
        let locale = Locale.current
        print("Using speech recognition locale: \(locale.identifier)")
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            print("Speech recognizer is not available for current locale.")
            self.status = "Speech recognizer not available."
            self.scheduleStatusAutoClearIfNeeded(for: self.status)
            return
        }

        if !recognizer.isAvailable {
            print("Speech recognizer is not currently available.")
            self.status = "Speech recognizer not available."
            self.scheduleStatusAutoClearIfNeeded(for: self.status)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        recognizer.recognitionTask(with: request) { [weak self] (result, error) in
            guard let self = self else { return }

            if let result = result {
                if result.isFinal {
                    self.inputText = result.bestTranscription.formattedString
                    print("Transcribed text: \(self.inputText)")
                    self.sendMessage()
                }
            } else if let error = error {
                print("Speech recognition error: \(error.localizedDescription)")
                self.status = "Speech recognition error."
                self.scheduleStatusAutoClearIfNeeded(for: self.status)
            }
        }
    }
}

private struct ThinkStreamParser {
    private let openTag = "<think>"
    private let closeTag = "</think>"
    private var mode: Mode = .awaitThink
    private var pending = ""
    private var awaitBuffer = ""
    private(set) var didCloseThink: Bool = false
    
    private enum Mode {
        case awaitThink
        case think
        case final
    }
    
    mutating func feed(_ chunk: String) -> (visible: String, think: String) {
        var visibleOut = ""
        var thinkOut = ""
        pending.append(contentsOf: chunk)

        while !pending.isEmpty {
            switch mode {
            case .awaitThink:
                if let openRange = pending.range(of: openTag) {
                    thinkOut += String(pending[..<openRange.lowerBound])
                    pending.removeSubrange(..<openRange.upperBound)
                    mode = .think
                } else if let closeRange = pending.range(of: closeTag) {
                    thinkOut += String(pending[..<closeRange.lowerBound])
                    pending.removeSubrange(..<closeRange.upperBound)
                    mode = .final
                    didCloseThink = true
                } else {
                    let keep = min(pending.count, max(openTag.count, closeTag.count) - 1)
                    let cutIndex = pending.index(pending.endIndex, offsetBy: -keep)
                    let chunk = String(pending[..<cutIndex])
                    awaitBuffer += chunk
                    thinkOut += chunk
                    pending = String(pending[cutIndex...])
                    return (visibleOut, thinkOut)
                }
            case .think:
                if let closeRange = pending.range(of: closeTag) {
                    thinkOut += String(pending[..<closeRange.lowerBound])
                    pending.removeSubrange(..<closeRange.upperBound)
                    mode = .final
                    didCloseThink = true
                } else if let openRange = pending.range(of: openTag) {
                    thinkOut += String(pending[..<openRange.lowerBound])
                    pending.removeSubrange(..<openRange.upperBound)
                } else {
                    let keep = min(pending.count, closeTag.count - 1)
                    let cutIndex = pending.index(pending.endIndex, offsetBy: -keep)
                    thinkOut += String(pending[..<cutIndex])
                    pending = String(pending[cutIndex...])
                    return (visibleOut, thinkOut)
                }
            case .final:
                if let openRange = pending.range(of: openTag) {
                    visibleOut += String(pending[..<openRange.lowerBound])
                    pending.removeSubrange(..<openRange.upperBound)
                } else if let closeRange = pending.range(of: closeTag) {
                    visibleOut += String(pending[..<closeRange.lowerBound])
                    pending.removeSubrange(..<closeRange.upperBound)
                } else {
                    visibleOut += pending
                    pending.removeAll()
                    return (visibleOut, thinkOut)
                }
            }
        }

        return (visibleOut, thinkOut)
    }

    mutating func flush() -> (visible: String, think: String) {
        var visible = ""
        var think = ""
        if !pending.isEmpty {
            if mode == .think {
                think += pending
            } else {
                visible += pending
            }
            pending.removeAll()
        }
        if mode == .awaitThink, !awaitBuffer.isEmpty {
            think += awaitBuffer
            awaitBuffer = ""
        }
        return (visible, think)
    }

    var allowVisibleStreaming: Bool {
        return mode == .final
    }
}

private func stripMetaLines(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Note:") { return false }
        if trimmed.hasPrefix("(Note:") { return false }
        if trimmed.hasPrefix("Responce:") { return false }
        if trimmed.hasPrefix("Final Answer:") { return false }
        if trimmed.hasPrefix("Final response:") { return false }
        if trimmed.hasPrefix("Thus,") { return false }
        if trimmed.lowercased().contains("the response is") { return false }
        return true
    }
    return lines.joined(separator: "\n")
}

private func cleanFinalAnswer(_ text: String) -> String {
    var cleaned = text

    // Remove think tags only
    cleaned = cleaned.replacingOccurrences(of: "<think>", with: "")
    cleaned = cleaned.replacingOccurrences(of: "</think>", with: "")
    cleaned = cleaned.replacingOccurrences(of: "OpenAGI", with: "0penAGI")

    // Remove "Final Answer:" and similar only if they start a line
    let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
    let filtered = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Final Answer:") { return false }
        if trimmed.hasPrefix("Responce:") { return false }
        if trimmed.hasPrefix("Final response:") { return false }
        return true
    }

    cleaned = filtered.joined(separator: "\n")

    // Limit excessive blank lines, preserve structure
    cleaned = cleaned.replacingOccurrences(
        of: "\n{4,}",
        with: "\n\n\n",
        options: .regularExpression
    )

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizeCompletedArtifactMarkup(in text: String) -> String {
    let cleaned = stripSurplusArtifactClosers(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !cleaned.isEmpty else { return cleaned }
    guard cleaned.range(of: "<artifact", options: [.caseInsensitive]) != nil else { return cleaned }

    if let recovered = recoverIncompleteArtifactMarkup(from: cleaned) {
        return recovered
    }

    let openCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)<artifact\\b")
    let closeCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)</artifact>")
    guard openCount == closeCount + 1 else { return cleaned }

    let hasCompletedHTML =
        cleaned.range(of: "</html>", options: [.caseInsensitive]) != nil ||
        cleaned.range(of: "</body>", options: [.caseInsensitive]) != nil

    guard hasCompletedHTML else { return cleaned }
    return cleaned + "\n</artifact>"
}

private func stripSurplusArtifactClosers(from text: String) -> String {
    var cleaned = text
    var openCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)<artifact\\b")
    var closeCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)</artifact>")

    guard closeCount > openCount else { return cleaned }

    while closeCount > openCount,
          let range = cleaned.range(
            of: #"\s*</artifact>\s*$"#,
            options: [.regularExpression, .caseInsensitive]
          ) {
        cleaned.removeSubrange(range)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        openCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)<artifact\\b")
        closeCount = artifactTagMatchCount(in: cleaned, pattern: "(?i)</artifact>")
    }

    return cleaned
}

private func recoverIncompleteArtifactMarkup(from text: String) -> String? {
    let pattern = #"(?is)(.*?)(<artifact\b([^>]*)>)(.*)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let prefixRange = Range(match.range(at: 1), in: text),
          let attrsRange = Range(match.range(at: 3), in: text),
          let payloadRange = Range(match.range(at: 4), in: text) else { return nil }

    let prefix = String(text[prefixRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    let attrsRaw = String(text[attrsRange])
    var payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else { return nil }

    let type = recoverArtifactAttributes(from: attrsRaw)["type"]?.lowercased() ?? "html"
    guard type == "html" else { return nil }

    payload = recoverHTMLPayload(payload)
    guard payload.range(of: "<html", options: [.caseInsensitive]) != nil ||
          payload.range(of: "<body", options: [.caseInsensitive]) != nil ||
          payload.range(of: "<!doctype html", options: [.caseInsensitive]) != nil else {
        return nil
    }

    let rebuilt = "<artifact \(attrsRaw.trimmingCharacters(in: .whitespacesAndNewlines))>\n\(payload)\n</artifact>"
    if prefix.isEmpty {
        return rebuilt
    }
    return prefix + "\n\n" + rebuilt
}

private func recoverArtifactAttributes(from raw: String) -> [String: String] {
    let pattern = #"([A-Za-z0-9_\-]+)\s*=\s*("([^"]*)"|'([^']*)')"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    let matches = regex.matches(in: raw, range: nsRange)
    var out: [String: String] = [:]

    for match in matches {
        guard let keyRange = Range(match.range(at: 1), in: raw) else { continue }
        let key = String(raw[keyRange]).lowercased()
        if let quoted = Range(match.range(at: 3), in: raw) {
            out[key] = String(raw[quoted])
        } else if let singleQuoted = Range(match.range(at: 4), in: raw) {
            out[key] = String(raw[singleQuoted])
        }
    }

    return out
}

private func recoverHTMLPayload(_ payload: String) -> String {
    var repaired = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = repaired.lowercased()

    if lower.contains("<body") && !lower.contains("</body>") {
        repaired += "\n</body>"
    }
    if lower.contains("<html") && !lower.contains("</html>") {
        repaired += "\n</html>"
    }

    return repaired
}

private func bestEffortArtifactPayload(from text: String) -> String? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }

    if let recovered = recoverIncompleteArtifactMarkup(from: cleaned),
       let artifact = extractBestEffortArtifact(from: recovered) {
        return artifact
    }

    if let artifact = extractBestEffortArtifact(from: cleaned) {
        return artifact
    }

    return nil
}

private func extractBestEffortArtifact(from text: String) -> String? {
    let pattern = "(?is)<artifact\\b([^>]*)>(.*?)</artifact>"
    if let regex = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        if let match = matches.last,
           let payloadRange = Range(match.range(at: 2), in: text) {
            let payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !payload.isEmpty {
                return recoverHTMLPayload(payload)
            }
        }
    }

    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let doctypeRange = nsText.range(of: "<!doctype html", options: [.caseInsensitive])
    let htmlRange = nsText.range(of: "<html", options: [.caseInsensitive])
    let bodyRange = nsText.range(of: "<body", options: [.caseInsensitive])
    let start = [doctypeRange, htmlRange, bodyRange]
        .filter { $0.location != NSNotFound }
        .map(\.location)
        .min()

    guard let start else { return nil }
    let raw = nsText.substring(with: NSRange(location: start, length: fullRange.length - start))
    let repaired = recoverHTMLPayload(raw)
    let lower = repaired.lowercased()
    guard lower.contains("<html") || lower.contains("<body") || lower.contains("<!doctype html") else {
        return nil
    }
    return repaired.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func artifactTagMatchCount(in text: String, pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.numberOfMatches(in: text, range: range)
}


private func splitThinkIntoFinal(_ think: String) -> (think: String, final: String) {
    let trimmed = cleanFinalAnswer(think)
    let rawSentences = trimmed
        .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // If stream stopped mid-sentence, the last fragment is often broken ("Also, t").
    let endsWithSentencePunctuation = trimmed.last.map { ".!?".contains($0) } ?? false
    let sentences: [String]
    if endsWithSentencePunctuation {
        sentences = rawSentences
    } else {
        sentences = Array(rawSentences.dropLast())
    }

    if sentences.count >= 3 {
        let finalTwo = Array(sentences.suffix(2)).joined(separator: ". ")
        let rest = sentences.dropLast(2).joined(separator: ". ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(finalTwo))
    }

    if sentences.count >= 2 {
        let finalSentence = sentences.last ?? ""
        let rest = sentences.dropLast().joined(separator: ". ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(finalSentence))
    }


    if let only = sentences.first {
        return ("", cleanFinalAnswer(only))
    }

    return ("", cleanFinalAnswer(trimmed))
}

extension Notification.Name {
    static let valisSiriPromptQueued = Notification.Name("valis.siriPromptQueued")
}
