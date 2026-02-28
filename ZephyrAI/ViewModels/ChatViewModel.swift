import Foundation
import SwiftUI
import AVFoundation
import Speech
import Combine
import UIKit

@MainActor
class ChatViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isInteracting: Bool = false
    @Published var status: String = "Starting Models"
    @Published var currentThink: String = ""
    @Published var currentThinkingMessageId: UUID?
    private var hasUserInteracted: Bool = false
    
    private var generationTask: Task<Void, Never>?
    private var activeGenerationId: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var lastSpontaneousAt: Date?
    private let spontaneousCooldown: TimeInterval = 600
    private let siriPendingPromptKey = "siri.pendingPrompt"
    private let siriPendingPromptTimestampKey = "siri.pendingPromptTimestamp"
    private let siriPromptMaxAge: TimeInterval = 180
    
    private let llmService = LLMService()
    private let memoryService = MemoryService.shared
    private let actionService = ActionService.shared
    private let identityService = IdentityService.shared
    private let identityProfileService = IdentityProfileService.shared
    private let experienceService = ExperienceService.shared
    private let motivationService = MotivationService.shared
    private let emotionService = EmotionService.shared
    private var lastReflectionHash: Int?

    
    override init() {
        super.init()
        setup()
        observeMemoryTriggers()
        observeSiriPromptQueue()
    }
    
    func setup() {
        llmService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.status = value
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
            
            if messages.isEmpty {
                messages.append(Message(role: .assistant, content: "Hello! I am  V A L I S . I have access to my memories. How can I help you?"))
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
        generationTask?.cancel()
        generationTask = nil
        llmService.cancelGeneration()
        activeGenerationId = nil
        isInteracting = false
        currentThink = ""
        currentThinkingMessageId = nil
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
        return "\n\nRecent Dialogue:\n" + lines.joined(separator: "\n")
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
        return """

Spontaneous flavor:
\(pick)

"""
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
                var finalText = cleanFinalAnswer(visibleBuffer)
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let split = splitThinkIntoFinal(thinkText)
                    messages[index].thinkContent = split.think
                    finalText = split.final
                }

                messages[index].content = finalText
                storeInternalReflection(
                    userPrompt: prompt,
                    draft: finalText,
                    detail: memoryService.preferredDetailLevel(forUserText: prompt)
                )
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            generationTask = nil
            activeGenerationId = nil
        }
    }

    func sendMessage() {
        let cleaned = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        if let valence = experienceService.applyUserReaction(from: inputText) {
            motivationService.updateForReaction(valence: valence)
            emotionService.updateForReaction(valence: valence)
        }
        hasUserInteracted = true
        
        generationTask?.cancel()
        generationTask = nil
        llmService.cancelGeneration()
        activeGenerationId = nil
        
        let userMessage = Message(role: .user, content: cleaned)
        messages.append(userMessage)
        let userMessageId = userMessage.id
        let prompt = cleaned
        inputText = ""
        
        isInteracting = true
        let generationId = UUID()
        activeGenerationId = generationId
        
        generationTask = Task { [generationId] in
            memoryService.updateConversationSummary(fromUserText: prompt)
            memoryService.updateUserProfile(fromUserText: prompt)
            let detail = memoryService.preferredDetailLevel(forUserText: prompt)
            memoryService.applyPredictionFeedback(fromUserText: prompt)
            memoryService.applyReinforcement(fromUserText: prompt)
            emotionService.updateForPrompt(prompt)
            let toolContext = await actionService.aggregateRuleBasedContext(for: prompt)
            motivationService.updateForPrompt(prompt)
            let motivationContext = motivationService.contextBlock()
            let identityProfileContext = identityProfileService.contextBlock()
            let experienceContext = experienceService.contextBlock(for: prompt)
            let emotionContext = emotionService.contextBlock()
            let memoryContext = memoryService.getContextBlock(maxChars: 900)
            let dialogContext = buildRecentDialogContext()
            let detailBlock = "\nResponse Detail: \(detail.rawValue)\n"
            let spiceBlock = randomSpiceBlock(for: prompt)
            let toolGuidance = actionService.buildToolGuidanceBlock(hasTools: !toolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let systemPrompt = identityService.systemPrompt + identityProfileContext + emotionContext + memoryContext + dialogContext + toolGuidance + toolContext + experienceContext + motivationContext + detailBlock + spiceBlock
            // 2. Generate response
            let assistantMessageId = UUID()
            messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: ""))
            currentThinkingMessageId = assistantMessageId
            currentThink = ""
            
            var parser = ThinkStreamParser()
            var visibleBuffer = ""
            let stream = await llmService.generate(userPrompt: prompt, systemPrompt: systemPrompt)
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
            
            // 3. Update memory (optional - auto-save conversation?)
            // memoryService.addMemory("Conversation: \(prompt) -> Response")
            
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
                var finalText = cleanFinalAnswer(visibleBuffer)

                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let split = splitThinkIntoFinal(thinkText)
                    messages[index].thinkContent = split.think
                    finalText = split.final
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

                    // Side-effect actions should return immediately to avoid long re-generation loops.
                    if immediateActionTools.contains(toolCall.name) {
                        currentFinalText = extractToolUserMessage(from: toolContextFromCall, fallback: currentFinalText)
                        break
                    }

                    accumulatedToolContext += "\n" + toolContextFromCall
                    let rerunGuidance = self.actionService.buildToolGuidanceBlock(hasTools: !accumulatedToolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    let rerunPrompt = identityService.systemPrompt + identityProfileContext + emotionContext + memoryContext + dialogContext + rerunGuidance + accumulatedToolContext + experienceContext + motivationContext + detailBlock + spiceBlock
                    let rerunOutput = await llmService.generateText(userPrompt: prompt, systemPrompt: rerunPrompt)

                    var rerunParser = ThinkStreamParser()
                    let first = rerunParser.feed(rerunOutput)
                    let rerunTail = rerunParser.flush()
                    let rerunThink = first.think + rerunTail.think
                    let rerunVisible = cleanFinalAnswer(first.visible + rerunTail.visible)

                    currentThinkText = rerunThink
                    if !rerunVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        currentFinalText = rerunVisible
                    } else if !rerunThink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let split = splitThinkIntoFinal(rerunThink)
                        currentThinkText = split.think
                        currentFinalText = split.final
                    }

                    toolLoopIterations += 1
                }

                if !currentThinkText.isEmpty {
                    messages[index].thinkContent = currentThinkText
                }
                finalText = currentFinalText

                messages[index].content = finalText
                emotionService.updateForAssistantResponse(finalText)
                storeInternalReflection(
                    userPrompt: prompt,
                    draft: finalText,
                    detail: detail
                )

                let finalAnswer = messages[index].content
                experienceService.recordExperience(
                    userMessageId: userMessageId,
                    assistantMessageId: assistantMessageId,
                    userText: prompt,
                    assistantText: finalAnswer
                )
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            generationTask = nil
            activeGenerationId = nil
        }
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
            return
        }

        if !recognizer.isAvailable {
            print("Speech recognizer is not currently available.")
            self.status = "Speech recognizer not available."
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


private func splitThinkIntoFinal(_ think: String) -> (think: String, final: String) {
    let trimmed = cleanFinalAnswer(think)
    let sentences = trimmed
        .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if sentences.count >= 2 {
        let finalSentence = sentences.last ?? ""
        let rest = sentences.dropLast().joined(separator: ". ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), cleanFinalAnswer(finalSentence))
    }


    return ("", trimmed)
}

extension Notification.Name {
    static let valisSiriPromptQueued = Notification.Name("valis.siriPromptQueued")
}
