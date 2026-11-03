import Foundation
import SwiftUI
import AVFoundation
import Speech
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct ChatArtifactMemory: Codable, Equatable, Sendable {
    let type: String
    let title: String?
    let payload: String
    let updatedAt: Date
}

struct ChatSession: Identifiable, Codable, Equatable, Sendable {
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
    let indicatesTopicBreak: Bool
    let topicBreakConfidence: Double
    let isContinuationIntent: Bool
}

@MainActor
final class ChatSessionStore: ObservableObject {
    static let shared = ChatSessionStore()

    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var currentChatID: UUID = UUID()

    private let currentChatDefaultsKey = "chat.currentSessionID"
    private let persistenceQueue = DispatchQueue(label: "valis.chat-persistence", qos: .utility)

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
        let chatsSnapshot = chats
        let destination = storageURL
        let currentChatIDString = currentChatID.uuidString
        let defaultsKey = currentChatDefaultsKey

        persistenceQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(chatsSnapshot)
                try data.write(to: destination, options: .atomic)
                UserDefaults.standard.set(currentChatIDString, forKey: defaultsKey)
            } catch {
                print("Failed to save chats: \(error)")
            }
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
    @Published private(set) var isTranscribingAudio: Bool = false
    @Published var status: String = "Starting Models"
    @Published private(set) var isModelReady: Bool = false
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
    private let continuousContextService = ContinuousContextService.shared
    private let voiceLayerService = VoiceLayerService(
        emotionService: EmotionService.shared
    )
    private var lastReflectionHash: Int?
    private var lastDriftSignal: ResponseDriftSignal?
    private var statusClearTask: Task<Void, Never>?
    private var activeRuleBasedContextTask: Task<ActionService.PreparedContext, Never>?
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

        llmService.$isModelReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isModelReady = value
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

    private func suggestedChatTitle(from messages: [Message]) -> String {
        let latestUserMessages = Array(
            messages.reversed().lazy
                .filter { $0.role == .user }
                .prefix(3)
        ).reversed()
        let text = latestUserMessages
            .map { $0.content }
            .joined(separator: " ")

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return "New chat"
        }

        return String(cleaned.prefix(32))
    }

    func updateArtifactContent(for messageID: UUID, payload: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard let artifact = extractLastHTMLArtifact(from: messages[index].content) else { return }

        let updatedContent = replaceLastHTMLArtifact(
            in: messages[index].content,
            title: artifact.title,
            payload: payload
        )
        guard updatedContent != messages[index].content else { return }

        var updatedMessage = messages[index]
        updatedMessage.content = updatedContent
        messages[index] = updatedMessage

        MarkdownRenderer.prewarmInline(updatedContent)

        if let savedArtifact = extractLastHTMLArtifact(from: updatedContent) {
            rememberedArtifact = ChatArtifactMemory(
                type: savedArtifact.type,
                title: savedArtifact.title,
                payload: savedArtifact.payload,
                updatedAt: Date()
            )
        }

        persistCurrentChatState()
    }

    private func normalizedConversationSnippet(_ text: String, maxChars: Int = 180) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }

        return trimmed.count > maxChars
            ? String(trimmed.prefix(maxChars)) + "…"
            : trimmed
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

    private func storeExternalImageMemory(query: String, candidate: ActionService.WebImageCandidate?, attachment: MessageImageAttachment?) async {
        guard let attachment else { return }
        let queryText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return }

        let analysis = await visionAttachmentService.analyze(attachment)
        let title = candidate?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = candidate?.sourcePageURL?.absoluteString

        var snippets = analysis.learningSnippets(
            query: queryText,
            title: title?.isEmpty == false ? title : nil,
            sourceURL: sourceURL?.isEmpty == false ? sourceURL : nil,
            attachmentFilename: attachment.filename
        )

        snippets.insert("Visual reference saved for \"\(queryText)\".", at: 0)

        memoryService.ingestExternalSnippets(
            snippets,
            source: "image-search",
            query: queryText,
            maxCount: 2
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

    private func attachmentSource(for attachment: MessageImageAttachment) -> String? {
        let fileURL = attachmentsDirectoryURL.appendingPathComponent(attachment.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return attachment.filename
    }

    private func enrichArtifactHTMLIfNeeded(
        in text: String,
        attachment: MessageImageAttachment?,
        imageTitle: String? = nil
    ) -> String {
        guard let attachment,
              let artifact = extractLastHTMLArtifact(from: text),
              let imageSource = attachmentSource(for: attachment) else {
            return text
        }

        let updatedPayload = injectImageSource(
            into: artifact.payload,
            source: imageSource,
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
        // Disabled collapsing behavior: always preserve artifacts as-is
        return text
    }

    private func injectImageSource(into html: String, source: String, title: String) -> String {
        let alt = htmlEscaped(title)
        var updated = html

        if let regex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#) {
            let nsRange = NSRange(updated.startIndex..<updated.endIndex, in: updated)
            if let match = regex.firstMatch(in: updated, range: nsRange),
               let fullRange = Range(match.range(at: 0), in: updated) {
                let original = String(updated[fullRange])
                let replaced = original.replacingOccurrences(
                    of: #"(?is)\bsrc\s*=\s*(['"])(.*?)\1"#,
                    with: #"src="\#(source)""#,
                    options: .regularExpression
                )
                return updated.replacingCharacters(in: fullRange, with: replaced)
            }
        }

        let imageBlock = """
        <figure style="margin:24px auto;max-width:920px;padding:0;">
        <img src="\(source)" alt="\(alt)" style="display:block;width:100%;height:auto;border-radius:22px;box-shadow:0 18px 60px rgba(0,0,0,0.22);object-fit:cover;">
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

    private func buildToolAwarePrompt(basePrompt: String, toolContext: String) -> String {
        let trimmedPrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToolContext = toolContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToolContext.isEmpty else { return trimmedPrompt }

        let compactToolContext: String
        if trimmedToolContext.count > 2_400 {
            compactToolContext = String(trimmedToolContext.prefix(2_400)) + "\n..."
        } else {
            compactToolContext = trimmedToolContext
        }

        return "Verified tool context:\n\(compactToolContext)\n\n\(trimmedPrompt)"
    }

    private func buildAdaptiveSamplingOverride(
        promptMode: PromptMode,
        isArtifactRequest: Bool,
        quantumField: QuantumMemoryService.QuantumDecisionField?,
        motivators: MotivatorState,
        emotion: EmotionState,
        driftSignal: ResponseDriftSignal?
    ) -> SamplingConfig {
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
            max(lower, min(upper, value))
        }

        func clampInt(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
            max(lower, min(upper, value))
        }

        func mix(_ lhs: Double, _ rhs: Double, weight: Double) -> Double {
            lhs * (1.0 - weight) + rhs * weight
        }

        let base: SamplingConfig = {
            switch promptMode {
            case .direct:
                return SamplingConfig(temperature: 0.38, topK: 26, topP: 0.92, repetitionPenalty: 1.08, repeatLastN: 68)
            case .code:
                return SamplingConfig(temperature: 0.42, topK: 30, topP: 0.93, repetitionPenalty: 1.08, repeatLastN: 64)
            case .artifact:
                return SamplingConfig(temperature: 0.72, topK: 40, topP: 0.95, repetitionPenalty: 1.08, repeatLastN: 64)
            case .reflective:
                return SamplingConfig(temperature: 0.58, topK: 38, topP: 0.94, repetitionPenalty: 1.06, repeatLastN: 60)
            case .creative:
                return SamplingConfig(temperature: 0.72, topK: 44, topP: 0.95, repetitionPenalty: 1.05, repeatLastN: 60)
            case .architecture:
                return SamplingConfig(temperature: 0.52, topK: 34, topP: 0.94, repetitionPenalty: 1.07, repeatLastN: 64)
            }
        }()

        var temperature = Double(base.temperature)
        var topK = Double(base.topK)
        var topP = Double(base.topP)
        var repetitionPenalty = Double(base.repetitionPenalty)
        var repeatLastN = Double(base.repeatLastN)

        if let quantumField, promptMode != .direct, !isArtifactRequest {
            let quantum = QuantumMemoryService.shared.samplingConfig(for: quantumField)
            temperature = mix(temperature, Double(quantum.temperature), weight: 0.5)
            topK = mix(topK, Double(quantum.topK), weight: 0.45)
            topP = mix(topP, Double(quantum.topP), weight: 0.45)
            repetitionPenalty = mix(repetitionPenalty, Double(quantum.repetitionPenalty), weight: 0.5)
            repeatLastN = mix(repeatLastN, Double(quantum.repeatLastN), weight: 0.45)
        }

        let valence = clamp(emotion.valence, -1.0, 1.0)
        let intensity = clamp(emotion.intensity, 0.0, 1.0)
        let stability = clamp(emotion.stability, 0.0, 1.0)
        let curiosity = clamp(motivators.curiosity, 0.0, 1.0)
        let helpfulness = clamp(motivators.helpfulness, 0.0, 1.0)
        let caution = clamp(motivators.caution, 0.0, 1.0)
        let mood = clamp(motivators.mood, 0.0, 1.0)
        let trust = clamp(motivators.trust, 0.0, 1.0)
        let energy = clamp(motivators.energy, 0.0, 1.0)
        let driftScore = clamp(driftSignal?.driftScore ?? 0.0, 0.0, 1.0)
        let repetitionLoad = clamp(driftSignal?.repetitionLoad ?? 0.0, 0.0, 1.0)
        let anchorRetention = clamp(driftSignal?.anchorRetention ?? 0.5, 0.0, 1.0)

        let exploratoryPush = clamp(
            (curiosity * 0.35)
            + (helpfulness * 0.15)
            + (energy * 0.15)
            + max(0.0, valence) * 0.08
            + (quantumField?.explorationBias ?? 0.0) * 0.20,
            0.0,
            1.0
        )
        let cautionLoad = clamp(
            (caution * 0.42)
            + ((1.0 - stability) * 0.22)
            + (driftScore * 0.22)
            + (repetitionLoad * 0.18)
            + max(0.0, 1.0 - anchorRetention) * 0.18,
            0.0,
            1.0
        )
        let tension = clamp(
            (1.0 - mood) * 0.12
            + (1.0 - trust) * 0.10
            + intensity * 0.08,
            0.0,
            1.0
        )

        if promptMode == .direct || promptMode == .code {
            temperature = clamp(temperature + exploratoryPush * 0.04 - cautionLoad * 0.10 - tension * 0.03, 0.18, 0.62)
            topK = clamp(topK + exploratoryPush * 4.0 - cautionLoad * 8.0, 12.0, 40.0)
            topP = clamp(topP - cautionLoad * 0.03 + exploratoryPush * 0.01, 0.84, 0.98)
            repetitionPenalty = clamp(repetitionPenalty + cautionLoad * 0.05 + repetitionLoad * 0.04, 1.03, 1.20)
            repeatLastN = clamp(repeatLastN - cautionLoad * 8.0 + exploratoryPush * 2.0, 24.0, 80.0)
        } else if isArtifactRequest {
            temperature = clamp(temperature + exploratoryPush * 0.06 - cautionLoad * 0.04, 0.45, 0.92)
            topK = clamp(topK + exploratoryPush * 6.0 - cautionLoad * 3.0, 24.0, 80.0)
            topP = clamp(topP + exploratoryPush * 0.01 - cautionLoad * 0.01, 0.88, 0.98)
            repetitionPenalty = clamp(repetitionPenalty + cautionLoad * 0.03, 1.03, 1.16)
            repeatLastN = clamp(repeatLastN + exploratoryPush * 4.0 - cautionLoad * 4.0, 32.0, 80.0)
        } else {
            temperature = clamp(temperature + exploratoryPush * 0.06 - cautionLoad * 0.08 - tension * 0.03, 0.20, 1.00)
            topK = clamp(topK + exploratoryPush * 10.0 - cautionLoad * 10.0, 16.0, 80.0)
            topP = clamp(topP + exploratoryPush * 0.015 - cautionLoad * 0.02, 0.82, 0.98)
            repetitionPenalty = clamp(repetitionPenalty + cautionLoad * 0.05 + (1.0 - trust) * 0.02, 1.02, 1.22)
            repeatLastN = clamp(repeatLastN + exploratoryPush * 6.0 - cautionLoad * 6.0, 24.0, 80.0)
        }

        return SamplingConfig(
            temperature: Float(temperature),
            topK: clampInt(Int(round(topK)), 12, 80),
            topP: Float(topP),
            repetitionPenalty: Float(repetitionPenalty),
            repeatLastN: clampInt(Int(round(repeatLastN)), 24, 80)
        )
    }

    private func buildVerifiedContextPrompt(basePrompt: String, contextLabel: String, context: String) -> String {
        let trimmedPrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return trimmedPrompt }

        let compactContext: String
        if trimmedContext.count > 3_600 {
            compactContext = String(trimmedContext.prefix(3_600)) + "\n..."
        } else {
            compactContext = trimmedContext
        }

        return """
Verified \(contextLabel):
\(compactContext)

\(trimmedPrompt)
"""
    }

    private func visibleLinkAnalysisThinkText(from analysis: String) -> String {
        let trimmed = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        if normalized.count <= 4_000 {
            return normalized
        }

        return String(normalized.prefix(4_000)) + "\n..."
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
            #if canImport(UIKit)
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.consumePendingSiriPromptIfNeeded()
            }
            .store(in: &cancellables)
            #endif
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

    private func appendStreamChunk(_ existing: inout String, _ chunk: String) {
        guard !chunk.isEmpty else { return }

        // Preserve exact model output
        existing.append(chunk)
    }

    private func formattedAssistantDisplayText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Preserve original structure: no sentence reflow, no space collapsing
        // Only reduce extreme blank-line spam
        let collapsed = trimmed.replacingOccurrences(
            of: "\\n{4,}",
            with: "\n\n\n",
            options: .regularExpression
        )

        return collapsed
    }

    func stopGeneration() {
        didUserRequestStopGeneration = true
        activeRuleBasedContextTask?.cancel()
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
        let recentArray = Array(recent)

        guard !recent.isEmpty else { return "" }

        let lines: [String] = recentArray.enumerated().compactMap { index, message in
            let role = message.role == .user ? "User" : "Assistant"
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { return nil }

            if message.role == .assistant {
                let previousUserText = recentArray[..<index]
                    .last(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                    .content ?? ""
                let summary = assistantContinuationSummary(
                    from: normalizedConversationSnippet(content, maxChars: maxCharsPerMessage),
                    fallbackUserText: normalizedConversationSnippet(previousUserText, maxChars: 120)
                )
                return "\(role): \(summary)"
            }

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
        let recent = messages
            .filter { ($0.role == .user || $0.role == .assistant) && $0.id != currentUserMessageID }
            .suffix(8)

        guard !recent.isEmpty else { return nil }

        let currentTerms = Set(extractAttentionTerms(from: trimmed))
        let currentIsUnderspecified = currentTerms.count <= 2
        let recentArray = Array(recent)
        let continuationIntent = isLikelyContextDependentFollowUp(trimmed)
        let topicBreakSignal = topicBreakConfidence(for: trimmed, recentMessages: recentArray)
        let adjustedTopicBreakSignal = continuationIntent ? min(topicBreakSignal, 0.35) : topicBreakSignal

        guard continuationIntent || topicBreakSignal >= 0.62 else { return nil }

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

        guard let bestSummary, bestScore >= 0.42 || topicBreakSignal >= 0.62 else { return nil }
        return ConversationAttentionFocus(
            summary: bestSummary,
            inheritedMode: bestMode,
            confidence: min(1.0, bestScore),
            isAssistantContinuation: bestIsAssistantContinuation,
            indicatesTopicBreak: adjustedTopicBreakSignal >= 0.62,
            topicBreakConfidence: min(1.0, adjustedTopicBreakSignal),
            isContinuationIntent: continuationIntent
        )
    }

    private func buildConversationAttentionBlock(_ focus: ConversationAttentionFocus?) -> String {
        guard let focus else { return "" }
        let clipped = focus.summary.count > 160 ? String(focus.summary.prefix(160)) + "…" : focus.summary
        if focus.isContinuationIntent {
            return "\n\nThe user is asking for more detail on the current topic, so stay on the same thread and expand the latest answer instead of switching away: \(clipped)"
        }
        if focus.indicatesTopicBreak {
            return "\n\nThe user's message appears to start a new topic, so drop stale assumptions from the previous thread and answer from the new request first. Only reuse older context if it is clearly relevant: \(clipped)"
        }
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



    private func semanticAttentionSimilarity(between lhs: String, and rhs: String) -> Double {
        let lhsVector = attentionEmbedding(for: lhs)
        let rhsVector = attentionEmbedding(for: rhs)
        guard !lhsVector.isEmpty, lhsVector.count == rhsVector.count else { return 0.0 }
        return cosineSimilarity(lhsVector, rhsVector)
    }

    private func topicBreakConfidence(for userText: String, recentMessages: [Message]) -> Double {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.0 }
        guard !recentMessages.isEmpty else { return 0.0 }

        let recentCombined = recentMessages
            .suffix(6)
            .map { normalizedConversationSnippet($0.content, maxChars: 180) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !recentCombined.isEmpty else { return 0.0 }

        let currentTerms = Set(extractAttentionTerms(from: trimmed))
        let priorTerms = Set(extractAttentionTerms(from: recentCombined))
        let overlap = currentTerms.intersection(priorTerms).count
        let overlapScore = currentTerms.isEmpty ? 0.0 : Double(overlap) / Double(max(1, currentTerms.count))
        let semantic = semanticAttentionSimilarity(between: trimmed, and: recentCombined)
        let novelty = currentTerms.isEmpty ? 0.0 : Double(currentTerms.subtracting(priorTerms).count) / Double(max(1, currentTerms.count))

        let lower = trimmed.lowercased()
        let explicitShiftSignals = [
            "new topic", "different question", "another thing", "switching topic",
            "другая тема", "другой вопрос", "а теперь", "переключимся", "новый вопрос"
        ]
        let entitySignals = [
            "http://", "https://", "www.", ".com", ".ru", ".org", ".ai", ".io"
        ]

        var score = ((1.0 - overlapScore) * 0.42) + ((1.0 - semantic) * 0.33) + (novelty * 0.25)
        if explicitShiftSignals.contains(where: { lower.contains($0) }) {
            score += 0.22
        }
        if entitySignals.contains(where: { lower.contains($0) }) {
            score += 0.12
        }
        if lower.range(of: #"\b\d{3,}\b"#, options: .regularExpression) != nil {
            score += 0.08
        }
        if trimmed.count > 48 && currentTerms.count >= 3 {
            score += 0.05
        }

        return max(0.0, min(1.0, score))
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

    private func buildRecentCodeContext(for prompt: String, maxChars: Int = 2_400) -> String {
        let lower = prompt.lowercased()
        let codeSignals = [
            "code", "bug", "debug", "fix", "refactor", "patch", "error", "compile",
            "improve", "improvement", "enhance", "refine", "update", "modify", "adjust",
            "optimize", "polish", "tune", "rewrite", "extend", "change", "tweak",
            "swift", "html", "css", "javascript", "js", "bugfix",
            "код", "ошиб", "дебаг", "почини", "исправ", "рефактор", "собери", "пофикс",
            "улучш", "доработ", "улучши", "улучшить", "подправ", "поправ", "сделай лучше", "допили"
        ]
        let wantsCodeContext = codeSignals.contains(where: { lower.contains($0) })
            || shouldUseArtifactContinuation(for: prompt)

        guard wantsCodeContext else { return "" }

        let recentAssistantCode: String? = messages.reversed().compactMap { message in
            guard message.role == .assistant else { return nil }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            if let artifact = extractLastHTMLArtifact(from: content) {
                return artifact.payload
            }

            if let codeBlock = extractLastFencedCodeBlock(from: content) {
                return codeBlock
            }

            if looksLikeCodeHeavyResponse(content) {
                return content
            }

            return nil
        }.first

        guard let code = recentAssistantCode else { return "" }
        let clipped = code.count > maxChars ? String(code.prefix(maxChars)) + "…" : code
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        return """

Recent assistant code:
```text
\(clipped)
```
"""
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

    private func extractLastFencedCodeBlock(from text: String) -> String? {
        let pattern = #"(?is)```(?:[A-Za-z0-9_+-]*)\s*\n(.*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let blockRange = Range(match.range(at: 1), in: text) else { return nil }

        let block = String(text[blockRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : block
    }

    private func looksLikeCodeHeavyResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 120 else { return false }

        let lower = trimmed.lowercased()
        let codeMarkers = [
            "<html", "</html>", "<body", "</body>", "<script", "</script>",
            "func ", "struct ", "class ", "enum ", "extension ", "import ",
            "let ", "var ", "private func", "public func", "return ", "if ", "guard ",
            "{", "}", "=>", "self.", "onAppear", "onChange"
        ]
        let hits = codeMarkers.reduce(into: 0) { partialResult, marker in
            if lower.contains(marker) { partialResult += 1 }
        }
        return hits >= 4
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
            "improve", "enhance", "refine", "update", "modify", "adjust", "optimize", "polish",
            "код", "ошибка", "дебаг", "рефактор", "почини", "собери", "свифт",
            "улучш", "доработ", "улучши", "улучшить", "подправ", "поправ", "сделай лучше", "допили"
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

    private func isEcoGenerationDevice() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(UIKit)
        let model = UIDevice.current.modelName.lowercased()
        return model.contains("iphone13") || model.contains("iphone 13")
        #else
        return false
        #endif
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
        let systemPrompt = """
        \(identityService.systemPrompt(for: LLMModelStorage.load()))
        \(toolContext)

        This is a private internal reflection pass.
        Do not address the user.
        Do not offer help, follow-up questions, or closing invitations.
        Keep it concise, grounded, and self-referential only if needed.
        """
        let prompt = """
        Internal reflection topic: \(topic)

        Write a compact private note about this topic in 1-2 sentences.
        Focus on what is missing, what stands out, or what should be remembered.
        Avoid any user-facing phrasing.
        """
        lastSpontaneousAt = Date()

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.generationTask = nil
                }
            }

            let note = await self.llmService.generateText(
                userPrompt: prompt,
                systemPrompt: systemPrompt,
                options: LLMService.GenerationOptions(
                    includeMemoryContext: false,
                    includeHiddenPrefix: false,
                    useCache: false,
                    useKVInjection: false,
                    storeResponseToMemory: false,
                    preferFullRuntimeContext: false,
                    managesActiveGenerationState: false
                )
            )
            if Task.isCancelled { return }

            let cleanedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedNote.isEmpty {
                self.memoryService.addExperienceMemory(
                    "[self-reflection-loop] \(cleanedNote)",
                    importanceOverride: 0.9
                )
            }
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
        let rawText = inputText
        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingImageAttachment

        guard !cleaned.isEmpty || attachment != nil else { return }
        guard isModelReady else {
            status = "Model is still loading..."
            return
        }
        playSendHaptic()

        pendingUserFeedbackValence = nil
        if let valence = experienceService.applyUserReaction(from: rawText) {
            motivationService.updateForReaction(valence: valence)
            emotionService.updateForReaction(valence: valence)
            pendingUserFeedbackValence = valence
        }
        hasUserInteracted = true
        prepareForNewGeneration()

        MarkdownRenderer.prewarmInline(rawText)
        inputText = ""
        pendingImageAttachment = nil
        if let editingId = editingUserMessageId,
           let userIndex = messages.firstIndex(where: { $0.id == editingId && $0.role == .user }) {
            messages[userIndex].content = rawText
            messages[userIndex].imageAttachment = attachment
            if userIndex + 1 < messages.count {
                messages.removeSubrange((userIndex + 1)..<messages.count)
            }
            editingUserMessageId = nil
            startAssistantGeneration(prompt: rawText, userMessageId: editingId, imageAttachment: attachment)
            return
        }

        let userMessage = Message(role: .user, content: rawText, imageAttachment: attachment)
        messages.append(userMessage)
        startAssistantGeneration(prompt: rawText, userMessageId: userMessage.id, imageAttachment: attachment)
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

    @discardableResult
    private func appendAssistantPlaceholder(thinkContent: String = "") -> UUID {
        let assistantMessageId = UUID()
        messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: thinkContent))
        currentThinkingMessageId = assistantMessageId
        currentThink = thinkContent
        return assistantMessageId
    }

    private func updateAssistantMessage(
        _ assistantMessageId: UUID,
        thinkContent: String? = nil,
        content: String? = nil,
        imageAttachment: MessageImageAttachment? = nil
    ) {
        guard let index = messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
        if let thinkContent {
            messages[index].thinkContent = thinkContent
        }
        if let content {
            messages[index].content = content
        }
        if let imageAttachment {
            messages[index].imageAttachment = imageAttachment
        }
    }

    private func completeAssistantGeneration() {
        currentThink = ""
        currentThinkingMessageId = nil
        isInteracting = false
        playGenerationFinishedHaptic()
        generationTask = nil
        activeGenerationId = nil
        didUserRequestStopGeneration = false
    }

    private struct StreamedGenerationResult {
        let visible: String
        let think: String
        let sawThinkTag: Bool
        let emittedImplicitThinking: Bool
        let didCloseThink: Bool
    }

    private func streamGeneratedText(
        userPrompt: String,
        systemPrompt: String,
        options: LLMService.GenerationOptions,
        generationId: UUID,
        assistantMessageId: UUID? = nil,
        startingVisibleText: String = "",
        startingThinkText: String = "",
        assumeImplicitThinking: Bool = false
    ) async -> StreamedGenerationResult {
        let thinkingEnabled = options.thinkingEnabled ?? (LLMThinkingModeStorage.load() == .thinking)
        var parser = ThinkStreamParser(assumeImplicitThinking: assumeImplicitThinking && thinkingEnabled, expectNoThink: !thinkingEnabled)
        var visibleBuffer = startingVisibleText
        var thinkBuffer = startingThinkText
        var lastVisibleFlushAt = Date.distantPast
        var lastThinkFlushAt = Date.distantPast
        let uiFlushInterval: TimeInterval = 0.05
        let stream = await llmService.generate(userPrompt: userPrompt, systemPrompt: systemPrompt, options: options)

        for await chunk in stream {
            if Task.isCancelled || activeGenerationId != generationId {
                break
            }

            let result = parser.feed(chunk)
            if !result.visible.isEmpty, parser.allowVisibleStreaming {
                appendStreamChunk(&visibleBuffer, result.visible)
                if !thinkingEnabled, let assistantMessageId,
                   currentThinkingMessageId == assistantMessageId {
                    currentThinkingMessageId = nil
                }
                if let assistantMessageId,
                   Date().timeIntervalSince(lastVisibleFlushAt) >= uiFlushInterval {
                    lastVisibleFlushAt = Date()
                    updateAssistantMessage(assistantMessageId, content: visibleBuffer)
                }
            }

            if !result.think.isEmpty {
                appendStreamChunk(&thinkBuffer, result.think)
                if let assistantMessageId,
                   Date().timeIntervalSince(lastThinkFlushAt) >= uiFlushInterval {
                    lastThinkFlushAt = Date()
                    updateAssistantMessage(assistantMessageId, thinkContent: thinkBuffer)
                }
            }
        }

        if !Task.isCancelled && activeGenerationId == generationId {
            let tail = parser.flush()
            if !tail.visible.isEmpty, parser.allowVisibleStreaming {
                appendStreamChunk(&visibleBuffer, tail.visible)
                if let assistantMessageId {
                    updateAssistantMessage(assistantMessageId, content: visibleBuffer)
                }
            }
            if !tail.think.isEmpty {
                appendStreamChunk(&thinkBuffer, tail.think)
                if let assistantMessageId {
                    updateAssistantMessage(assistantMessageId, thinkContent: thinkBuffer)
                }
            }
        }

        return StreamedGenerationResult(
            visible: visibleBuffer,
            think: thinkBuffer,
            sawThinkTag: parser.sawThinkTag,
            emittedImplicitThinking: parser.emittedImplicitThinking,
            didCloseThink: parser.didCloseThink
        )
    }

    private func startAssistantGeneration(prompt: String, userMessageId: UUID, imageAttachment: MessageImageAttachment? = nil) {
        guard isModelReady else {
            status = "Model is still loading..."
            return
        }
        isInteracting = true
        let generationId = UUID()
        activeGenerationId = generationId

        generationTask = Task { [generationId] in
            if let directActionCall = directActionCall(for: prompt) {
                let assistantMessageId = appendAssistantPlaceholder()

                let toolContext = await actionService.context(for: directActionCall)
                let finalText = extractToolUserMessage(from: toolContext, fallback: "")
                updateAssistantMessage(
                    assistantMessageId,
                    thinkContent: nil,
                    content: finalText.isEmpty ? cleanedToolEnvelope(toolContext) ?? "" : finalText
                )
                completeAssistantGeneration()
                return
            }

            if let explicitLinkAnalysis = await analyzeExplicitLinksIfNeeded(for: prompt) {
                let assistantMessageId = appendAssistantPlaceholder()
                currentThinkingMessageId = assistantMessageId

                memoryService.updateUserProfile(fromUserText: prompt)
                emotionService.updateForPrompt(prompt)

                let visibleAnalysisThink = visibleLinkAnalysisThinkText(from: explicitLinkAnalysis)
                currentThink = formattedAssistantDisplayText(visibleAnalysisThink)

                let answerPrompt = buildExplicitLinkAnswerPrompt(userText: prompt, analysis: explicitLinkAnalysis)
                let answerPromptWithContext = buildVerifiedContextPrompt(
                    basePrompt: answerPrompt,
                    contextLabel: "link analysis context",
                    context: explicitLinkAnalysis
                )
                let answerSystemPrompt = buildExplicitLinkSystemPrompt()
                var answerOptions = LLMService.GenerationOptions(
                    includeMemoryContext: false,
                    preferFullRuntimeContext: false
                )
                answerOptions.managesActiveGenerationState = false
                answerOptions.samplingOverride = SamplingConfig(
                    temperature: 0.2,
                    topK: 20,
                    repetitionPenalty: 1.05,
                    repeatLastN: 64
                )

                let answer = await llmService.generateText(
                    userPrompt: answerPromptWithContext,
                    systemPrompt: answerSystemPrompt,
                    options: answerOptions
                )

                var finalText = stripToolDirectivesFromOutput(cleanFinalAnswer(answer))
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = buildExplicitLinkFallbackAnswer(from: explicitLinkAnalysis)
                }
                let tone = MarkovMemoryLayer.shared.classifyTone(from: finalText)
                finalText = voiceLayerService.apply(to: finalText, tone: tone)
                finalText = formatAssistantDisplayText(finalText)

                updateAssistantMessage(
                    assistantMessageId,
                    thinkContent: formattedAssistantDisplayText(visibleAnalysisThink),
                    content: finalText
                )

                rememberArtifactIfPresent(in: finalText)
                storeInternalReflection(
                    draft: finalText,
                    detail: memoryService.preferredDetailLevel(forUserText: prompt)
                )

                completeAssistantGeneration()
                return
            }

            let assistantMessageId = appendAssistantPlaceholder()
            let imageAnalysisTask: Task<VisionAttachmentAnalysis, Never>?
            if let imageAttachment {
                imageAnalysisTask = Task(priority: .utility) { await visionAttachmentService.analyze(imageAttachment) }
            } else {
                imageAnalysisTask = nil
            }

            let attentionFocus = buildConversationAttentionFocus(for: prompt, currentUserMessageID: userMessageId)
            let imageAnalysis = await imageAnalysisTask?.value
            let llmPrompt = buildLLMPrompt(userText: prompt, imageAnalysis: imageAnalysis)
            let conversationAttentionBlock = buildConversationAttentionBlock(attentionFocus)
            let implicitSearchQuery = deriveImplicitSearchQuery(for: prompt, currentUserMessageID: userMessageId)

            memoryService.updateUserProfile(fromUserText: llmPrompt)
            let detail = memoryService.preferredDetailLevel(forUserText: llmPrompt)
            memoryService.applyPredictionFeedback(fromUserText: llmPrompt)
            memoryService.applyReinforcement(fromUserText: llmPrompt)
            emotionService.updateForPrompt(llmPrompt)
            let promptMode = classifyPromptMode(for: llmPrompt, attentionFocus: attentionFocus)
            let isArtifactRequest = promptMode == .artifact
            let isInstantMode = LLMThinkingModeStorage.load() == .instant
            let selectedModel = LLMModelStorage.load()
            let systemPromptForModel = identityService.systemPrompt(for: selectedModel)
            _ = Task(priority: .utility) { await self.buildImplicitSearchContext(for: llmPrompt, currentUserMessageID: userMessageId) }
            let previousAssistantTextForPrompt = messages
                .dropLast()
                .reversed()
                .first(where: { $0.role == .assistant })?
                .content
            let webImageQuery = implicitSearchQuery ?? (shouldAttachWebImage(for: prompt) ? prompt : nil)
            let shouldFetchWebImage = implicitSearchQuery != nil || (webImageQuery.map { shouldAttachWebImage(for: $0) } ?? false)
            let webImageCandidateTask: Task<ActionService.WebImageCandidate?, Never> = Task(priority: .utility) {
                guard let query = webImageQuery, shouldFetchWebImage else { return nil }
                return await actionService.fetchRelevantWebImage(for: query)
            }
            if shouldFetchWebImage, let query = webImageQuery {
                Task(priority: .utility) { [weak self] in
                    guard let self else { return }
                    guard let candidate = await webImageCandidateTask.value else { return }
                    guard let webAttachment = await self.downloadWebImageAttachment(from: candidate.imageURL) else { return }
                    await MainActor.run {
                        if let assistantIndex = self.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                            self.messages[assistantIndex].imageAttachment = webAttachment
                        }
                    }
                    await self.storeExternalImageMemory(query: query, candidate: candidate, attachment: webAttachment)
                }
            }
            let shouldWaitForRuleBasedContext = shouldWaitForRuleBasedContext(for: prompt, promptMode: promptMode)
            activeRuleBasedContextTask?.cancel()
            let ruleBasedContextTask: Task<ActionService.PreparedContext, Never>? = shouldWaitForRuleBasedContext
                ? Task(priority: .utility) {
                    await actionService.aggregateRuleBasedContext(for: prompt)
                }
                : nil
            activeRuleBasedContextTask = ruleBasedContextTask
            let preparedContext = await ruleBasedContextTask?.value ?? ActionService.PreparedContext(blocks: [])
            if activeGenerationId == generationId {
                activeRuleBasedContextTask = nil
            }
            let toolContext = preparedContext.rendered
            let hasSearchData = preparedContext.hasSuccessBlock(for: .search) || preparedContext.hasSuccessBlock(for: .news)
            let userPromptForLLM = buildToolAwarePrompt(basePrompt: llmPrompt, toolContext: toolContext)

            motivationService.updateForPrompt(llmPrompt)
            let quantumField = !isInstantMode && (promptMode == .reflective || promptMode == .creative || promptMode == .architecture) ? QuantumMemoryService.shared.collapseDecisionField(
                prompt: llmPrompt,
                motivators: motivationService.state
            ) : nil
            let adaptiveSampling = buildAdaptiveSamplingOverride(
                promptMode: promptMode,
                isArtifactRequest: isArtifactRequest,
                quantumField: quantumField,
                motivators: motivationService.state,
                emotion: emotionService.state,
                driftSignal: lastDriftSignal
            )
            let userIdentityContext = UserIdentityService.shared.contextBlock(maxChars: 160)
            let identityProfileContext = (isInstantMode || promptMode == .artifact || promptMode == .direct || promptMode == .code) ? "" : identityProfileService.contextBlock()
            let experienceContext: String = {
                if isInstantMode { return "" }
                switch promptMode {
                case .direct, .artifact, .code:
                    return ""
                case .reflective, .creative, .architecture:
                    return experienceService.contextBlock(for: llmPrompt, maxChars: 220)
                }
            }()
            let freshnessContext = buildResponseFreshnessContext(
                userText: llmPrompt,
                previousAssistantText: previousAssistantTextForPrompt,
                promptMode: promptMode
            )
            let continuousDeviceContext = continuousContextService.contextBlock(includeDeviceState: continuousContextService.isDeviceStateRelevant(llmPrompt))
            let budget = llmService.inferenceBudget(forPromptLength: userPromptForLLM.count + systemPromptForModel.count)
            let memoryContext = isInstantMode ? "" : buildSmartMemoryContext(
                for: llmPrompt,
                promptMode: promptMode,
                budget: budget,
                attentionFocus: attentionFocus
            )
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
            let recentCodeContext = buildRecentCodeContext(for: llmPrompt)
            let artifactContinuationBlock = buildArtifactContinuationBlock(for: llmPrompt)
            let artifactSpecializationBlock = isArtifactRequest ? buildArtifactSpecializationBlock(for: llmPrompt) : ""
            let toolGuidance = shouldIncludeToolGuidance(
                for: llmPrompt,
                toolContext: toolContext,
                promptMode: promptMode
            ) ? actionService.buildToolGuidanceBlock(hasTools: preparedContext.hasSuccessBlock(for: .search) || preparedContext.hasSuccessBlock(for: .news) || preparedContext.hasSuccessBlock(for: .url)) : ""
            let hasContextNow = hasSearchData
            let newsPrimer = !hasContextNow && shouldPrimeNewsTools(for: llmPrompt, promptMode: promptMode)
                ? actionService.buildNewsToolPrimerBlock()
                : ""
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
            let isEcoDevice = isEcoGenerationDevice()
            let allowsSecondaryPasses = promptMode == .reflective || promptMode == .creative || promptMode == .architecture
            let promptBudgetChars: Int = {
                if isEcoDevice {
                    switch promptMode {
                    case .direct:
                        return budget.profile == .constrained ? 1600 : 1800
                    case .code:
                        return budget.profile == .constrained ? 1600 : 1900
                    case .artifact:
                        return 3000
                    case .reflective, .creative, .architecture:
                        return budget.profile == .constrained ? 1700 : 2500
                    }
                }
                switch promptMode {
                case .direct:
                    return budget.profile == .constrained ? 1800 : 4000
                case .code:
                    return budget.profile == .constrained ? 1900 : 3000
                case .artifact:
                    return 3600
                case .reflective, .creative, .architecture:
                    return budget.profile == .constrained ? 2400 : 3600
                }
            }()
            let systemPrompt = assemblePromptFragments([
                PromptFragment(priority: 100, text: systemPromptForModel, maxChars: isEcoDevice ? 1350 : 1600),
                PromptFragment(priority: 99, text: toolContext, maxChars: isEcoDevice ? 500 : 2000),
                PromptFragment(priority: 95, text: artifactSpec, maxChars: 900),
                PromptFragment(priority: 92, text: artifactSpecializationBlock, maxChars: 480),
                PromptFragment(priority: 91, text: newsPrimer, maxChars: 180),
                PromptFragment(priority: 90, text: conversationAttentionBlock, maxChars: isEcoDevice ? 180 : 320),
                PromptFragment(priority: 89, text: continuousDeviceContext, maxChars: 180),
                PromptFragment(priority: 88, text: freshnessContext, maxChars: isEcoDevice ? 180 : 320),
                PromptFragment(priority: 88, text: userIdentityContext, maxChars: 160),
                PromptFragment(priority: 87, text: dialogContext, maxChars: isEcoDevice ? (promptMode == .direct ? 360 : 520) : (promptMode == .direct ? 760 : 980)),
                PromptFragment(priority: 86, text: memoryContext, maxChars: isEcoDevice ? (promptMode == .direct ? 240 : 360) : (promptMode == .direct ? 640 : 920)),
                PromptFragment(priority: 68, text: identityProfileContext, maxChars: 100),
                PromptFragment(priority: 85, text: toolGuidance, maxChars: isEcoDevice ? 260 : 460),
                PromptFragment(priority: 52, text: codeCoachContext, maxChars: 420),
                PromptFragment(priority: 51, text: recentCodeContext, maxChars: 1_000),
                PromptFragment(priority: 48, text: artifactContinuationBlock, maxChars: 720),
                PromptFragment(priority: 44, text: experienceContext, maxChars: 220),
                PromptFragment(priority: 10, text: spiceBlock, maxChars: 60),
                PromptFragment(priority: 1, text: detailBlock, maxChars: 20)
            ], maxChars: promptBudgetChars)

            var assistantWebAttachment: MessageImageAttachment?

            let thinkingEnabled = LLMThinkingModeStorage.load() == .thinking
            let assumesImplicitThinking = selectedModel == .small && thinkingEnabled
            var parser = ThinkStreamParser(assumeImplicitThinking: assumesImplicitThinking, expectNoThink: !thinkingEnabled)
            var visibleBuffer = ""

            
            var genOptions: LLMService.GenerationOptions = isArtifactRequest
                ? LLMService.GenerationOptions(
                    maxTokensOverride: 24_000,
                    includeMemoryContext: false,
                    includeHiddenPrefix: false,
                    useCache: false,
                    useKVInjection: false,
                    storeResponseToMemory: false,
                    preferFullRuntimeContext: false,
                    preserveExtendedOutputBudget: true,
                    samplingOverride: adaptiveSampling
                )
                : LLMService.GenerationOptions(
                    includeMemoryContext: !isInstantMode,
                    includeHiddenPrefix: false,
                    useKVInjection: !isInstantMode,
                    preferFullRuntimeContext: !isInstantMode && (promptMode == .reflective || promptMode == .creative || promptMode == .architecture),
                    affectProfile: isInstantMode ? nil : AffectProfile.from(
                        emotion: emotionService.state,
                        motivators: motivationService.state,
                        drift: lastDriftSignal
                    )
                )
            if !isArtifactRequest {
                genOptions.samplingOverride = adaptiveSampling
            }
            if isEcoDevice, !isArtifactRequest, selectedModel == .small {
                genOptions.useThinkTagPrompting = false
            }
            if selectedModel == .large {
                genOptions.useThinkTagPrompting = false
            }
            genOptions.thinkingEnabled = thinkingEnabled

            let stream = await llmService.generate(userPrompt: userPromptForLLM, systemPrompt: systemPrompt, options: genOptions)
            for await chunk in stream {
                if Task.isCancelled || activeGenerationId != generationId {
                    break
                }
                let result = parser.feed(chunk)
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if !result.visible.isEmpty, parser.allowVisibleStreaming {
                        appendStreamChunk(&visibleBuffer, result.visible)
                        await MainActor.run {
                            if !thinkingEnabled, currentThinkingMessageId == assistantMessageId {
                                currentThinkingMessageId = nil
                            }
                            updateAssistantMessage(assistantMessageId, content: visibleBuffer)
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
                if let repaired = repairReasoningLeakIfNeeded(in: finalText, parserSawThinkTag: parser.sawThinkTag) {
                    if !(repaired.think?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        updateAssistantMessage(assistantMessageId, thinkContent: repaired.think)
                    }
                    finalText = repaired.final
                }
                let endedInsideThink = !parser.didCloseThink && !currentThink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   (parser.didCloseThink || parser.emittedImplicitThinking) {
                    let split = splitThinkIntoFinal(thinkText, preferImplicitReasoningSplit: parser.emittedImplicitThinking)
                    updateAssistantMessage(assistantMessageId, thinkContent: split.think)
                    finalText = normalizeCompletedArtifactMarkup(in: split.final)
                }

                var toolLoopIterations = 0
                let maxToolIterations = isInstantMode ? 1 : 3
                var accumulatedToolContext = toolContext
                var currentFinalText = finalText
                var currentThinkText = messages[index].thinkContent ?? ""
                var seenToolCalls = Set<String>()
                let hasSearchContext = preparedContext.hasSuccessBlock(for: .search)
                let hasNewsContext = preparedContext.hasSuccessBlock(for: .news)
                var didUseToolContext = hasSearchContext || hasNewsContext
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
                    didUseToolContext = true

                    if immediateActionTools.contains(toolCall.name) {
                        currentFinalText = extractToolUserMessage(from: toolContextFromCall, fallback: currentFinalText)
                        break
                    }

                    accumulatedToolContext += "\n" + toolContextFromCall
                    let rerunGuidance = self.actionService.buildToolGuidanceBlock(hasTools: !accumulatedToolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    let rerunPrompt = assemblePromptFragments([
                        PromptFragment(priority: 100, text: systemPromptForModel, maxChars: 1600),
                        PromptFragment(priority: 91, text: self.actionService.buildNewsToolPrimerBlock(), maxChars: 180),
                        PromptFragment(priority: 90, text: rerunGuidance, maxChars: 380),
                        PromptFragment(priority: 89, text: conversationAttentionBlock, maxChars: 240),
                        PromptFragment(priority: 87, text: freshnessContext, maxChars: 220),
                        PromptFragment(priority: 86, text: userIdentityContext, maxChars: 160),
                        PromptFragment(priority: 85, text: accumulatedToolContext, maxChars: promptMode == .direct ? 960 : 1_440),
                        PromptFragment(priority: 84, text: codeCoachContext, maxChars: 420),
                        PromptFragment(priority: 83, text: recentCodeContext, maxChars: 1_000),
                        PromptFragment(priority: 83, text: artifactContinuationBlock, maxChars: 720),
                        PromptFragment(priority: 81, text: memoryContext, maxChars: promptMode == .direct ? 260 : 520),
                        PromptFragment(priority: 77, text: identityProfileContext, maxChars: 80),
                        PromptFragment(priority: 69, text: experienceContext, maxChars: 320),
                        PromptFragment(priority: 65, text: dialogContext, maxChars: promptMode == .direct ? 180 : 420),
                        PromptFragment(priority: 55, text: detailBlock, maxChars: 80),
                        PromptFragment(priority: 19, text: spiceBlock, maxChars: 90)
                    ], maxChars: promptBudgetChars)
                    var rerunOptions = LLMService.GenerationOptions()
                    rerunOptions.thinkingEnabled = thinkingEnabled
                    rerunOptions.managesActiveGenerationState = false
                    rerunOptions.samplingOverride = adaptiveSampling
                    if selectedModel == .large {
                        rerunOptions.useThinkTagPrompting = false
                    }
                    rerunOptions.includeMemoryContext = false
                    rerunOptions.affectProfile = AffectProfile.from(
                        emotion: emotionService.state,
                        motivators: motivationService.state,
                        drift: lastDriftSignal
                    )
                    let rerunUserPrompt = buildToolAwarePrompt(basePrompt: llmPrompt, toolContext: accumulatedToolContext)
                    let rerunResult = await streamGeneratedText(
                        userPrompt: rerunUserPrompt,
                        systemPrompt: rerunPrompt,
                        options: rerunOptions,
                        generationId: generationId,
                        assistantMessageId: assistantMessageId,
                        assumeImplicitThinking: assumesImplicitThinking
                    )

                    var rerunVisible = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(rerunResult.visible))
                    var rerunThinkText = rerunResult.think
                    if let repaired = repairReasoningLeakIfNeeded(in: rerunVisible, parserSawThinkTag: rerunResult.sawThinkTag) {
                        rerunThinkText = repaired.think ?? rerunThinkText
                        rerunVisible = repaired.final
                    }

                    currentThinkText = rerunThinkText
                    if !rerunVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        currentFinalText = formatAssistantDisplayText(rerunVisible)
                    } else if !rerunThinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let split = splitThinkIntoFinal(rerunThinkText, preferImplicitReasoningSplit: rerunResult.emittedImplicitThinking)
                        currentThinkText = split.think
                        currentFinalText = formatAssistantDisplayText(normalizeCompletedArtifactMarkup(in: split.final))
                    }

                    toolLoopIterations += 1
                }

                if !didUseToolContext,
                   promptMode != .artifact,
                   !isInstantMode,
                   allowsSecondaryPasses,
                   shouldIncludeToolGuidance(for: llmPrompt, toolContext: "", promptMode: promptMode) {
                    let fallbackQuery = implicitSearchQuery ?? bestSearchQuery(for: llmPrompt) ?? llmPrompt
                    let fallbackCall = ActionService.ActionCall(
                        name: "web_search",
                        query: fallbackQuery,
                        args: ["query": fallbackQuery]
                    )
                    let fallbackToolContext = await self.actionService.context(for: fallbackCall)
                    if !fallbackToolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let fallbackPrompt = buildVerifiedContextPrompt(
                            basePrompt: llmPrompt,
                            contextLabel: "search evidence",
                            context: fallbackToolContext
                        )
                        var fallbackOptions = LLMService.GenerationOptions(
                            includeMemoryContext: true,
                            preferFullRuntimeContext: false
                        )
                        fallbackOptions.managesActiveGenerationState = false
                        fallbackOptions.samplingOverride = adaptiveSampling
                        fallbackOptions.thinkingEnabled = thinkingEnabled
                        if selectedModel == .large {
                            fallbackOptions.useThinkTagPrompting = false
                        }

                        let fallbackResult = await streamGeneratedText(
                            userPrompt: fallbackPrompt,
                            systemPrompt: buildSearchAnswerSystemPrompt(),
                            options: fallbackOptions,
                            generationId: generationId,
                            assistantMessageId: assistantMessageId
                        )
                        let fallbackVisible = normalizeCompletedArtifactMarkup(
                            in: cleanFinalAnswer(fallbackResult.visible)
                        )
                        if !fallbackVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            currentFinalText = formatAssistantDisplayText(fallbackVisible)
                            currentThinkText = fallbackResult.think
                        }
                    }
                }

                if !currentThinkText.isEmpty {
                    updateAssistantMessage(assistantMessageId, thinkContent: currentThinkText)
                }
                finalText = currentFinalText

                if isArtifactRequest,
                   shouldAttemptArtifactContinuation(for: finalText) {
                    let resumed = await continueIncompleteArtifactIfNeeded(
                        partialText: finalText,
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt,
                        generationId: generationId,
                        assistantMessageId: assistantMessageId
                    )
                    finalText = normalizeCompletedArtifactMarkup(in: resumed)
                } else if !isArtifactRequest,
                          !didUserRequestStopGeneration,
                          !isEcoDevice,
                          allowsSecondaryPasses,
                          endedInsideThink,
                          finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = await recoverFinalFromInterruptedThinking(
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt,
                        promptMode: promptMode,
                        generationId: generationId,
                        assistantMessageId: assistantMessageId
                    )
                } else if !isArtifactRequest,
                          !didUserRequestStopGeneration,
                          !isEcoDevice,
                          allowsSecondaryPasses,
                          shouldAttemptTextContinuation(for: finalText) {
                    finalText = await continueIncompleteTextIfNeeded(
                        partialText: finalText,
                        userPrompt: llmPrompt,
                        systemPrompt: systemPrompt,
                        promptMode: promptMode,
                        generationId: generationId,
                        assistantMessageId: assistantMessageId
                    )
                }

                if isEcoDevice,
                   !isArtifactRequest,
                   finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let split = splitThinkIntoFinal(currentThinkText, preferImplicitReasoningSplit: true)
                    let fallback = cleanFinalAnswer(split.final).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fallback.isEmpty {
                        finalText = fallback
                    } else if !currentFinalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalText = currentFinalText
                    } else {
                        finalText = "Ответ оборвался из-за лимита генерации на устройстве. Могу продолжить короче."
                    }
                }

                finalText = ensureHTMLWrappedAsArtifactIfNeeded(finalText)

                if isArtifactRequest {
                    let webImageCandidate = await webImageCandidateTask.value
                    let sanitized = await sanitizeArtifactImageSourcesIfNeeded(
                        in: finalText,
                        preferredAttachment: assistantWebAttachment,
                        imageTitle: webImageCandidate?.title
                    )
                    finalText = sanitized.text
                    if assistantWebAttachment == nil,
                       let sanitizedAttachment = sanitized.attachment {
                        updateAssistantMessage(assistantMessageId, imageAttachment: sanitizedAttachment)
                        assistantWebAttachment = sanitizedAttachment
                    }
                    finalText = enrichArtifactHTMLIfNeeded(
                        in: finalText,
                        attachment: assistantWebAttachment,
                        imageTitle: webImageCandidate?.title
                    )
                }

                // Keep the text that was streamed to the user. Post-stream voice
                // shaping and repetition repair rewrite punctuation/spacing and
                // make the completed answer visibly jump after it has finished.
                finalText = finalText.replacingOccurrences(of: "\r\n", with: "\n")

                let artifactDraft = isArtifactRequest ? extractLastHTMLArtifact(from: finalText) : nil
                let originChatID = chatStore.currentChatID

                updateAssistantMessage(assistantMessageId, content: finalText)
                rememberArtifactIfPresent(in: finalText)
                schedulePostFactumStateUpdate(
                    userPrompt: prompt,
                    assistantText: finalText,
                    userMessageId: userMessageId,
                    assistantMessageId: assistantMessageId,
                    previousAssistantText: previousAssistantTextForPrompt,
                    detail: detail,
                    userFeedback: pendingUserFeedbackValence
                )
                pendingUserFeedbackValence = nil

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

            completeAssistantGeneration()
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
        if rememberedArtifact != nil && shouldUseArtifactContinuation(for: prompt) {
            return true
        }
        return hasArtifact && hasIntent
    }

    private func isLikelyLocalActionRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let actionSignals = [
            "create", "make", "add", "set", "schedule", "book", "plan", "arrange", "remind",
            "создай", "добавь", "поставь", "запланир", "назнач", "напомни"
        ]
        let localObjectSignals = [
            "calendar", "reminder", "reminders", "event", "events", "schedule", "appointment", "meeting",
            "calendar event", "календар", "событи", "встреч", "напомин"
        ]
        return actionSignals.contains(where: { lower.contains($0) })
            && localObjectSignals.contains(where: { lower.contains($0) })
    }

    private func shouldIncludeToolGuidance(
        for prompt: String,
        toolContext: String,
        promptMode: PromptMode
    ) -> Bool {
        let trimmedToolContext = toolContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToolContext.isEmpty {
            return true
        }

        if promptMode == .artifact {
            return false
        }

        let intent = IntentRouter.classify(prompt)
        return intent.search || intent.news || intent.weather || intent.health || intent.system || intent.wiki
            || intent.calendar != .none
            || !intent.urlAnalysis.isEmpty
    }

    private func shouldWaitForRuleBasedContext(
        for prompt: String,
        promptMode: PromptMode
    ) -> Bool {
        guard promptMode != .artifact else { return false }

        if isLikelyLocalActionRequest(prompt) {
            return true
        }

        if !explicitURLs(in: prompt).isEmpty {
            return true
        }

        let intent = IntentRouter.classify(prompt)
        return intent.search || intent.news || intent.weather || intent.health || intent.system
    }

    private func shouldPrimeNewsTools(for prompt: String, promptMode: PromptMode) -> Bool {
        guard promptMode != .artifact else { return false }
        let lower = prompt.lowercased()
        let newsSignals = [
            "news", "headline", "breaking", "latest", "current events", "what's new",
            "новости", "свежие", "последние", "что нового", "что случилось"
        ]
        return newsSignals.contains(where: { lower.contains($0) })
    }

    private func shouldBoostMemoryContext(for prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let followUpSignals = [
            "remember", "earlier", "before", "previous", "again", "same", "continue",
            "you said", "we discussed", "as we said", "my last", "last time",
            "помни", "раньше", "до этого", "снова", "ещё раз", "мы обсуждали", "ты говорил"
        ]
        return followUpSignals.contains(where: { lower.contains($0) })
    }

    private func buildSmartMemoryContext(
        for prompt: String,
        promptMode: PromptMode,
        budget: LLMService.InferenceBudget,
        attentionFocus: ConversationAttentionFocus?
    ) -> String {
        let topicBreakConfidence = attentionFocus?.topicBreakConfidence ?? 0.0
        let isTopicBreak = attentionFocus?.indicatesTopicBreak == true
        let memoryQuery: String = {
            guard attentionFocus?.isContinuationIntent == true else { return prompt }
            let anchor = attentionFocus?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !anchor.isEmpty else { return prompt }
            return "\(prompt)\n\(anchor)"
        }()
        switch promptMode {
        case .artifact:
            return ""
        case .reflective, .creative, .architecture:
            let maxChars = {
                if isTopicBreak {
                    return budget.profile == .constrained ? 220 : 360
                }
                return budget.profile == .constrained ? 320 : 540
            }()
            let boosted = shouldBoostMemoryContext(for: prompt)
            let candidates = isTopicBreak ? 1 : (boosted ? 3 : 2)
            return memoryService.getLLMContextBlock(
                maxChars: maxChars,
                forUserText: memoryQuery,
                candidateLimit: candidates,
                contextShift: topicBreakConfidence
            )
        case .direct:
            let boosted = shouldBoostMemoryContext(for: prompt)
            let maxChars: Int = {
                if isTopicBreak {
                    return budget.profile == .constrained ? 120 : 180
                }
                if budget.profile == .constrained {
                    return boosted ? 240 : 160
                }
                return boosted ? 360 : 220
            }()
            let candidates = isTopicBreak ? 1 : (boosted ? 2 : 1)
            return memoryService.getLLMContextBlock(
                maxChars: maxChars,
                forUserText: memoryQuery,
                candidateLimit: candidates,
                contextShift: topicBreakConfidence
            )
        case .code:
            let boosted = shouldBoostMemoryContext(for: prompt)
            let maxChars: Int = {
                if isTopicBreak {
                    return budget.profile == .constrained ? 110 : 160
                }
                if budget.profile == .constrained {
                    return boosted ? 220 : 140
                }
                return boosted ? 320 : 180
            }()
            let candidates = isTopicBreak ? 1 : (boosted ? 2 : 1)
            return memoryService.getLLMContextBlock(
                maxChars: maxChars,
                forUserText: memoryQuery,
                candidateLimit: candidates,
                contextShift: topicBreakConfidence
            )
        }
    }

    private func buildResponseFreshnessContext(
        userText: String,
        previousAssistantText: String?,
        promptMode: PromptMode
    ) -> String {
        guard promptMode != .artifact else { return "" }

        let previous = previousAssistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previous, !previous.isEmpty else { return "" }

        let opening = assistantOpeningSnippet(from: previous, maxChars: 120)
        guard !opening.isEmpty else { return "" }

        let userPreview = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)

        let block = """

        Response freshness:
        - Last assistant opening: "\(opening)"
        - Avoid reusing that lead or the same reassurance.
        - Start with a fresh first sentence and a different entry point.
        \(userPreview.isEmpty ? "" : "- User prompt: \"\(userPreview)\"")
        """

        return block
    }

    private func assistantOpeningSnippet(from text: String, maxChars: Int) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let firstLine = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !firstLine.isEmpty else { return "" }

        let sentenceEnders = CharacterSet(charactersIn: ".!?…")
        if let endIndex = firstLine.rangeOfCharacter(from: sentenceEnders)?.upperBound,
           firstLine.distance(from: firstLine.startIndex, to: endIndex) <= maxChars {
            return String(firstLine[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(firstLine.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
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

        let createSignals = [
            "create", "make", "add", "set", "schedule", "book", "plan", "arrange",
            "создай", "добавь", "поставь", "запланируй", "назначь"
        ]
        guard createSignals.contains(where: { lower.contains($0) }) || isReminder else { return nil }

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

    private func analyzeExplicitLinksIfNeeded(for prompt: String) async -> String? {
        let urls = explicitURLs(in: prompt)
        guard !urls.isEmpty else { return nil }

        var contexts: [String] = []
        for url in urls.prefix(2) {
            let call = ActionService.ActionCall(
                name: "analyze_url",
                query: url.absoluteString,
                args: ["url": url.absoluteString]
            )
            let context = await actionService.context(for: call)
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                contexts.append(trimmed)
            }
        }

        let merged = contexts.joined(separator: "\n\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func explicitURLs(in text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []

        var unique: [URL] = []
        var seen = Set<String>()
        for match in matches {
            guard let url = match.url else { continue }
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { continue }
            let key = url.absoluteString.lowercased()
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func buildExplicitLinkSystemPrompt() -> String {
        """
You are answering from pre-fetched link analysis.
Use only the provided analysis.
Do not call tools.
Do not emit TOOL or ACTION lines.
Do not mention internal reasoning, link analysis, or that you fetched a page.
Do not write phrases like "the link analysis indicates", "the page appears to", or "based on the analysis".
Answer as if you directly understood the linked content.
Be concise, direct, and helpful.
"""
    }

    private func buildSearchAnswerSystemPrompt() -> String {
        """
You are answering from pre-fetched search evidence.
Use only the provided evidence and URLs.
Do not call tools.
Do not invent source names, links, or citations that are not present in the evidence.
If the evidence is weak, conflicting, or incomplete, say that plainly.
Answer in the user's language.
Be concise, direct, and factual.
"""
    }

    private func bestSearchQuery(for prompt: String) -> String? {
        let candidates = actionService.searchQueryCandidates(from: prompt)
        return candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func buildExplicitLinkAnswerPrompt(userText: String, analysis: String) -> String {
        """
User request:
\(userText)

Use the verified link analysis context already included in this prompt.
Do not ignore it.
Do not ask to open the link again.
Write a concise answer based only on that context.
Prefer concrete details from the analysis over vague summary wording.
If the analysis is insufficient, say exactly what is missing.
"""
    }

    private func buildExplicitLinkFallbackAnswer(from analysis: String) -> String {
        let cleaned = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return "I couldn't extract useful content from the link."
        }
        return cleaned
    }

    private func stripToolDirectivesFromOutput(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !(lower.hasPrefix("action:") || lower.hasPrefix("tool:"))
        }
        return filtered.joined(separator: "\n")
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

    private func storeInternalReflection(draft: String, detail: DetailLevel) {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }

        let motivators = motivationService.state
        let reflection = memoryService.applyCognitiveLayer(
            to: trimmedDraft,
            detail: detail
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

    private func schedulePostFactumStateUpdate(
        userPrompt: String,
        assistantText: String,
        userMessageId: UUID,
        assistantMessageId: UUID,
        previousAssistantText: String?,
        detail: DetailLevel,
        userFeedback: Double?
    ) {
        let novelty = estimateTurnNovelty(for: userPrompt)
        let driftService = responseDriftService
        Task.detached(priority: .utility) { [weak self, driftService] in
            let driftSignal = driftService.analyze(
                userPrompt: userPrompt,
                assistantText: assistantText,
                previousAssistantText: previousAssistantText
            )

            guard let self else { return }
            await MainActor.run {
                self.emotionService.updateForAssistantResponse(assistantText)
                self.storeInternalReflection(
                    draft: assistantText,
                    detail: detail
                )

                self.motivationService.updateForTurnReward(
                    userPrompt: userPrompt,
                    assistantText: assistantText,
                    userFeedback: userFeedback,
                    novelty: novelty
                )

                self.lastDriftSignal = driftSignal
                self.motivationService.updateForDriftSignal(driftSignal)
                self.storeDriftSignalIfNeeded(driftSignal, userPrompt: userPrompt, assistantText: assistantText)

                if let experienceSnapshot = self.experienceService.recordExperience(
                    userMessageId: userMessageId,
                    assistantMessageId: assistantMessageId,
                    userText: userPrompt,
                    assistantText: assistantText
                ) {
                    self.experienceService.commitPostFactumSnapshot(experienceSnapshot)
                }

                self.performSelfReflectionIfNeeded(userPrompt: userPrompt, assistantText: assistantText)
            }
        }
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

        // Bare HTML documents are valid artifact output too. Do not start a
        // continuation just because they are not wrapped in <artifact> tags.
        if hasHTMLSignal && isHTMLDocumentComplete(cleaned) {
            return false
        }

        if hasArtifactStart { return true }
        if hasHTMLSignal && cleaned.count > 240 { return true }
        return false
    }

    private func isHTMLDocumentComplete(_ text: String) -> Bool {
        let start = ["<!doctype html", "<html", "<body"]
            .compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
        guard let start else { return false }

        let document = text[start...]
        return document.range(of: "</html>", options: .caseInsensitive) != nil
            || document.range(of: "</body>", options: .caseInsensitive) != nil
    }

    private func continueIncompleteArtifactIfNeeded(
        partialText: String,
        userPrompt: String,
        systemPrompt: String,
        generationId: UUID,
        assistantMessageId: UUID? = nil
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
            includeMemoryContext: true,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: false,
            preserveExtendedOutputBudget: true,
            samplingOverride: SamplingConfig(
                temperature: 0.45,
                topK: 40,
                repetitionPenalty: 1.04,
                repeatLastN: 96
            ),
        )

        let resumed = await streamGeneratedText(
            userPrompt: continuationPrompt,
            systemPrompt: systemPrompt,
            options: continuationOptions,
            generationId: generationId,
            assistantMessageId: assistantMessageId,
            startingVisibleText: partialText
        )

        let cleaned = normalizeCompletedArtifactMarkup(in: cleanFinalAnswer(resumed.visible))
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

    private func ensureHTMLWrappedAsArtifactIfNeeded(_ text: String) -> String {
        let normalized = normalizeCompletedArtifactMarkup(in: text)
        if extractLastHTMLArtifact(from: normalized) != nil {
            return normalized
        }

        guard let payload = bestEffortArtifactPayload(from: normalized) else { return normalized }
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else { return normalized }

        let title = rememberedArtifact?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = (title?.isEmpty == false) ? title! : "Artifact"
        return """
<artifact type="html" title="\(safeTitle)">
\(trimmedPayload)
</artifact>
"""
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
        promptMode: PromptMode,
        generationId: UUID,
        assistantMessageId: UUID? = nil
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
            includeMemoryContext: true,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: false,
            preserveExtendedOutputBudget: true,
            samplingOverride: continuationSampling,
            managesActiveGenerationState: false
        )

        let resumed = await streamGeneratedText(
            userPrompt: continuationPrompt,
            systemPrompt: systemPrompt,
            options: continuationOptions,
            generationId: generationId,
            assistantMessageId: assistantMessageId,
            startingVisibleText: partialText
        )

        let cleanedContinuation = cleanFinalAnswer(resumed.visible)
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
        promptMode: PromptMode,
        generationId: UUID,
        assistantMessageId: UUID? = nil
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
            includeMemoryContext: true,
            includeHiddenPrefix: false,
            useCache: false,
            useKVInjection: false,
            storeResponseToMemory: false,
            preferFullRuntimeContext: false,
            preserveExtendedOutputBudget: true,
            samplingOverride: recoverySampling,
            managesActiveGenerationState: false
        )

        let resumed = await streamGeneratedText(
            userPrompt: recoveryPrompt,
            systemPrompt: systemPrompt,
            options: recoveryOptions,
            generationId: generationId,
            assistantMessageId: assistantMessageId
        )

        return cleanFinalAnswer(resumed.visible)
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
                systemPrompt: self.identityService.systemPrompt(for: LLMModelStorage.load()),
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
            guard !self.isLikelyArtifactRewrite(draft: draftArtifact.payload, candidate: improved.payload) else {
                return
            }

            let improvedTitle = (improved.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? (improved.title ?? title)
                : title
            let mergedPayload = self.mergeArtifactRevision(
                base: draftArtifact.payload,
                revision: improved.payload
            )
            let polishedText = """
<artifact type="html" title="\(improvedTitle)">
\(mergedPayload)
</artifact>
"""

            MarkdownRenderer.prewarmInline(polishedText)
            self.messages[index].content = polishedText
            self.rememberArtifactIfPresent(in: polishedText)
            self.persistCurrentChatState()
        }
    }

    private func mergeArtifactRevision(base: String, revision: String) -> String {
        let baseTrimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let revisionTrimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revisionTrimmed.isEmpty else { return baseTrimmed }
        guard baseTrimmed != revisionTrimmed else { return revisionTrimmed }

        if let idMerged = mergeArtifactElementsByID(base: baseTrimmed, revision: revisionTrimmed) {
            return idMerged
        }

        if let bodyMerged = replaceArtifactBodyContent(base: baseTrimmed, revision: revisionTrimmed) {
            return bodyMerged
        }

        return revisionTrimmed
    }

    private func mergeArtifactElementsByID(base: String, revision: String) -> String? {
        let pattern = #"(?is)<([A-Za-z][A-Za-z0-9:-]*)\b([^>]*)\bid\s*=\s*(['"])([^'"]+)\3([^>]*)>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let revisionRange = NSRange(revision.startIndex..<revision.endIndex, in: revision)
        let matches = regex.matches(in: revision, range: revisionRange).reversed()
        guard !matches.isEmpty else { return nil }

        var merged = base
        var didReplace = false

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: revision),
                  let tagRange = Range(match.range(at: 1), in: revision),
                  let idRange = Range(match.range(at: 4), in: revision) else { continue }

            let tag = String(revision[tagRange])
            let identifier = String(revision[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }

            let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
            let tagPattern = #"(?is)<\#(tag)\b[^>]*\bid\s*=\s*(['"])\#(escapedIdentifier)\2[^>]*>.*?</\#(tag)>"#
            guard let tagRegex = try? NSRegularExpression(pattern: tagPattern) else { continue }

            let mergedRange = NSRange(merged.startIndex..<merged.endIndex, in: merged)
            guard let baseMatch = tagRegex.firstMatch(in: merged, range: mergedRange),
                  let baseRange = Range(baseMatch.range(at: 0), in: merged) else { continue }

            merged.replaceSubrange(baseRange, with: String(revision[fullRange]))
            didReplace = true
        }

        return didReplace ? merged : nil
    }

    private func replaceArtifactBodyContent(base: String, revision: String) -> String? {
        let pattern = #"(?is)(<body\b[^>]*>)(.*?)(</body>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let baseRange = NSRange(base.startIndex..<base.endIndex, in: base)
        let revisionRange = NSRange(revision.startIndex..<revision.endIndex, in: revision)
        guard let baseMatch = regex.firstMatch(in: base, range: baseRange),
              let revisionMatch = regex.firstMatch(in: revision, range: revisionRange),
              let baseContentRange = Range(baseMatch.range(at: 2), in: base),
              let revisionContentRange = Range(revisionMatch.range(at: 2), in: revision) else { return nil }

        let revisionContent = String(revision[revisionContentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revisionContent.isEmpty else { return nil }

        var merged = base
        merged.replaceSubrange(baseContentRange, with: revisionContent)
        return merged
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
        isTranscribingAudio = true
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self.transcribeAudio(audioURL: audioURL)
                case .denied, .restricted, .notDetermined:
                    self.isTranscribingAudio = false
                    print("Speech recognition authorization denied.")
                    self.status = "Speech recognition denied."
                    self.scheduleStatusAutoClearIfNeeded(for: self.status)
                @unknown default:
                    self.isTranscribingAudio = false
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
            self.isTranscribingAudio = false
            self.status = "Speech recognizer not available."
            self.scheduleStatusAutoClearIfNeeded(for: self.status)
            return
        }

        if !recognizer.isAvailable {
            print("Speech recognizer is not currently available.")
            self.isTranscribingAudio = false
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
                    self.isTranscribingAudio = false
                }
            }
            if let error = error {
                self.isTranscribingAudio = false
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
    private let assumeImplicitThinking: Bool
    private var mode: Mode = .awaitThink
    private var pending = ""
    private var awaitBuffer = ""
    private(set) var didCloseThink: Bool = false
    private(set) var sawThinkTag: Bool = false
    private(set) var emittedImplicitThinking: Bool = false
    
    private enum Mode {
        case awaitThink
        case think
        case final
    }

    init(assumeImplicitThinking: Bool = false, expectNoThink: Bool = false) {
        self.assumeImplicitThinking = assumeImplicitThinking
        self.mode = expectNoThink ? .final : .awaitThink
    }
    
    mutating func feed(_ chunk: String) -> (visible: String, think: String) {
        var visibleOut = ""
        var thinkOut = ""
        pending.append(contentsOf: chunk)

        while !pending.isEmpty {
            switch mode {
            case .awaitThink:
                if let openRange = pending.range(of: openTag) {
                    let prefix = String(pending[..<openRange.lowerBound])
                    let buffered = awaitBuffer + prefix
                    if !buffered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        visibleOut += buffered
                    }
                    awaitBuffer = ""
                    pending.removeSubrange(..<openRange.upperBound)
                    mode = .think
                    sawThinkTag = true
                } else if let closeRange = pending.range(of: closeTag) {
                    thinkOut += String(pending[..<closeRange.lowerBound])
                    pending.removeSubrange(..<closeRange.upperBound)
                    mode = .final
                    didCloseThink = true
                    sawThinkTag = true
                } else {
                    let keep = min(pending.count, max(openTag.count, closeTag.count) - 1)
                    if pending.count <= keep {
                        awaitBuffer += pending
                        pending.removeAll()
                        return (visibleOut, thinkOut)
                    }
                    let cutIndex = pending.index(pending.endIndex, offsetBy: -keep)
                    let chunk = String(pending[..<cutIndex])
                    awaitBuffer += chunk
                    if assumeImplicitThinking {
                        thinkOut += chunk
                        emittedImplicitThinking = true
                    }
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
            } else if mode == .awaitThink {
                if assumeImplicitThinking {
                    think += pending
                    emittedImplicitThinking = true
                } else {
                    visible += pending
                }
            } else {
                visible += pending
            }
            pending.removeAll()
        }
        if mode == .awaitThink, !awaitBuffer.isEmpty {
            if assumeImplicitThinking {
                think = awaitBuffer + think
                emittedImplicitThinking = true
            } else {
                visible = awaitBuffer + visible
            }
            awaitBuffer = ""
        }
        return (visible, think)
    }

    var allowVisibleStreaming: Bool {
        return mode == .final
    }
}

private func cleanFinalAnswer(_ text: String) -> String {
    var cleaned = text

    // Remove think tags only
    cleaned = cleaned.replacingOccurrences(of: "<think>", with: "")
    cleaned = cleaned.replacingOccurrences(of: "</think>", with: "")
    cleaned = cleaned.replacingOccurrences(of: "OpenAGI", with: "0penAGI")
    cleaned = stripInternalContent(cleaned)

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

    // Trim only leading/trailing newlines, preserve internal whitespace/indentation
    cleaned = cleaned.trimmingCharacters(in: .newlines)
    return cleaned
}

func stripInternalContent(_ text: String) -> String {
    var cleaned = text

    if let regex = try? NSRegularExpression(
        pattern: #"(?is)<internal\b[^>]*>.*?</internal>"#,
        options: []
    ) {
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        cleaned = regex.stringByReplacingMatches(
            in: cleaned,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    if let tagRegex = try? NSRegularExpression(
        pattern: #"(?im)^[ \t]*</?internal[^>\n]*>[ \t]*\n?"#,
        options: []
    ) {
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        cleaned = tagRegex.stringByReplacingMatches(
            in: cleaned,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    cleaned = cleaned.replacingOccurrences(
        of: "\n{4,}",
        with: "\n\n\n",
        options: .regularExpression
    )

    return cleaned
}

private func normalizeCompletedArtifactMarkup(in text: String) -> String {
    let cleaned = stripSurplusArtifactClosers(from: text)
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
        // Trim only trailing newlines, preserve internal whitespace/indentation
        cleaned = cleaned.trimmingCharacters(in: .newlines)
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

    if let fenced = unwrapMarkdownCodeFence(from: cleaned),
       let recovered = recoverIncompleteArtifactMarkup(from: fenced),
       let artifact = extractBestEffortArtifact(from: recovered) {
        return artifact
    }

    if let artifact = extractBestEffortArtifact(from: cleaned) {
        return artifact
    }

    return nil
}

private func unwrapMarkdownCodeFence(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), let fenceEnd = trimmed.range(of: "\n```", options: .backwards) else {
        return nil
    }

    let bodyStart = trimmed.firstIndex(of: "\n").map { trimmed.index(after: $0) } ?? trimmed.startIndex
    let body = String(trimmed[bodyStart..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return body
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


private func splitThinkIntoFinal(
    _ think: String,
    preferImplicitReasoningSplit: Bool = false
) -> (think: String, final: String) {
    let trimmed = cleanFinalAnswer(think)

    let hasVisibleStructure = trimmed.contains("\n\n")
        || trimmed.contains("```")
        || trimmed.contains("\n- ")
        || trimmed.contains("\n* ")
        || trimmed.contains("\n• ")
        || trimmed.contains("\n1. ")
        || trimmed.contains("\n# ")

    if hasVisibleStructure {
        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count >= 2 {
            let finalParagraphCount = min(2, paragraphs.count)
            let final = paragraphs.suffix(finalParagraphCount).joined(separator: "\n\n")
            let think = paragraphs.dropLast(finalParagraphCount).joined(separator: "\n\n")
            return (think.trimmingCharacters(in: .whitespacesAndNewlines), final)
        }

        if preferImplicitReasoningSplit, let only = paragraphs.first, only.count > 120 {
            let splitPoint = max(40, only.count * 2 / 3)
            let boundary = only[..<only.index(only.startIndex, offsetBy: min(splitPoint, only.count))]
            let think = boundary.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = only.dropFirst(min(splitPoint, only.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !think.isEmpty, !final.isEmpty {
                return (think, final)
            }
        }

        return ("", trimmed)
    }

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

    // Short direct answers like "Привет" often arrive without terminal punctuation.
    // In that case, treat the whole text as the final answer instead of dropping it.
    if sentences.isEmpty {
        if rawSentences.count == 1 {
            if preferImplicitReasoningSplit {
                let raw = cleanFinalAnswer(rawSentences[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.count > 120 {
                    let splitPoint = max(40, raw.count * 2 / 3)
                    let boundary = raw[..<raw.index(raw.startIndex, offsetBy: min(splitPoint, raw.count))]
                    let think = boundary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let final = raw.dropFirst(min(splitPoint, raw.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !think.isEmpty, !final.isEmpty {
                        return (think, final)
                    }
                }
            }
            return ("", cleanFinalAnswer(rawSentences[0]))
        }
        return ("", cleanFinalAnswer(trimmed))
    }

    if sentences.count >= 3 {
        if preferImplicitReasoningSplit {
            let first = sentences.first ?? ""
            let rest = sentences.dropFirst().joined(separator: ". ")
            return (first.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(rest))
        }
        let finalTwo = Array(sentences.suffix(2)).joined(separator: ". ")
        let rest = sentences.dropLast(2).joined(separator: ". ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(finalTwo))
    }

    if sentences.count >= 2 {
        if preferImplicitReasoningSplit {
            let first = sentences.first ?? ""
            let rest = sentences.dropFirst().joined(separator: ". ")
            return (first.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(rest))
        }
        let finalSentence = sentences.last ?? ""
        let rest = sentences.dropLast().joined(separator: ". ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(finalSentence))
    }

    if let only = sentences.first {
        if preferImplicitReasoningSplit, only.count > 120 {
            let splitPoint = max(40, only.count * 2 / 3)
            let boundary = only[..<only.index(only.startIndex, offsetBy: min(splitPoint, only.count))]
            let think = boundary.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = only.dropFirst(min(splitPoint, only.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !think.isEmpty, !final.isEmpty {
                return (think, final)
            }
        }
        return ("", cleanFinalAnswer(only))
    }

    return ("", cleanFinalAnswer(trimmed))
}

private func repairReasoningLeakIfNeeded(in text: String, parserSawThinkTag: Bool) -> (think: String?, final: String)? {
    let cleaned = cleanFinalAnswer(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    guard !parserSawThinkTag else { return nil }
    guard looksLikeReasoningLeak(cleaned) else { return nil }

    let split = splitThinkIntoFinal(cleaned)
    let final = cleanFinalAnswer(split.final).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !final.isEmpty, final != cleaned else { return nil }

    let think = split.think.trimmingCharacters(in: .whitespacesAndNewlines)
    return (think.isEmpty ? nil : think, final)
}

private func looksLikeReasoningLeak(_ text: String) -> Bool {
    let lower = text.lowercased()
    let markers = [
        "user, probably expects",
        "user likely expects",
        "judging by the context",
        "i should answer",
        "i will answer",
        "same language as the user",
        "since the user wrote",
        "пользователь, вероятно",
        "судя по контексту",
        "поскольку пользователь",
        "мой ответ должен",
        "я выберу русский",
        "итак, ответ",
        "инструкции говорят"
    ]

    let markerHits = markers.filter { lower.contains($0) }.count
    if markerHits >= 2 {
        return true
    }

    let paragraphCount = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    return paragraphCount >= 3 && lower.contains("пользователь")
}

func formatAssistantDisplayText(_ text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let preserved = normalized
        .replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preserved.isEmpty else { return preserved }
    return preserved
}

extension Notification.Name {
    static let valisSiriPromptQueued = Notification.Name("valis.siriPromptQueued")
}
