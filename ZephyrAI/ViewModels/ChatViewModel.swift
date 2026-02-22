import Foundation
import SwiftUI
import AVFoundation
import Speech
import Combine

@MainActor
class ChatViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isInteracting: Bool = false
    @Published var status: String = "Starting LFM 2.5"
    @Published var currentThink: String = ""
    @Published var currentThinkingMessageId: UUID?
    
    private var generationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastSpontaneousAt: Date?
    private let spontaneousCooldown: TimeInterval = 600
    
    private let llmService = LLMService()
    private let memoryService = MemoryService.shared
    private let identityService = IdentityService.shared

    
    override init() {
        super.init()
        setup()
        observeMemoryTriggers()
    }
    
    func setup() {
        Task {
            await llmService.loadModel()
            self.status = llmService.status
            
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

                let now = Date()
                if let last = self.lastSpontaneousAt, now.timeIntervalSince(last) < self.spontaneousCooldown {
                    return
                }

                Task { await self.handleSpontaneousTrigger(memoryID: id) }
            }
            .store(in: &cancellables)
    }
    
    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isInteracting = false
        currentThink = ""
        currentThinkingMessageId = nil
    }
    
    private func shouldUseWebSearch(for text: String) -> Bool {
        let lowercased = text.lowercased()
        let triggers = [
            "search",
            "google",
            "web",
            "internet",
            "найди",
            "найти",
            "поиск",
            "в интернете",
            "что такое",
            "кто такой",
            "посмотри",
            "загугли",
            "поищи"
        ]
        return triggers.contains { lowercased.contains($0) }
    }
    
    private func shouldUseDateTool(for text: String) -> Bool {
        let lowercased = text.lowercased()
        let triggers = [
            "какая сегодня дата",
            "сегодняшняя дата",
            "какой сегодня день",
            "today's date",
            "what is today's date",
            "current date"
        ]
        return triggers.contains { lowercased.contains($0) }
    }
    
    private func buildToolContextBlock(from webContext: String) -> String {
        guard !webContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return """

Web search context:
\(webContext)

"""
    }
    
    private func buildDateContextBlock() -> String {
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let formatted = formatter.string(from: date)
        
        let isoFormatter = ISO8601DateFormatter()
        let iso = isoFormatter.string(from: date)
        
        return """

System time tool:
Сегодняшняя дата (локально): \(formatted)
ISO‑время: \(iso)

"""
    }
    
    private func aggregateToolContext(for prompt: String) async -> String {
        var blocks: [String] = []
        
        if shouldUseDateTool(for: prompt) {
            let dateContext = buildDateContextBlock()
            if !dateContext.isEmpty {
                blocks.append(dateContext)
            }
        }
        
        if shouldUseWebSearch(for: prompt) {
            do {
                let webContext = try await fetchDuckDuckGoSummary(query: prompt)
                if !webContext.isEmpty {
                    print("[Tools] Web search context length: \(webContext.count)")
                    let snippets = splitSnippets(webContext)
                    memoryService.ingestExternalSnippets(snippets, source: "duckduckgo", query: prompt)
                    blocks.append(buildToolContextBlock(from: webContext))
                }
            } catch {
                print("[Tools] Web search failed: \(error)")
            }
        }
        
        return blocks.joined(separator: "\n")
    }
    
    private func fetchDuckDuckGoSummary(query: String) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        
        guard let url = components.url else { return "" }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)
        
        var parts: [String] = []
        if let abstract = decoded.Abstract, !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(abstract.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let abstractText = decoded.AbstractText, !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(abstractText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        let relatedTexts = (decoded.RelatedTopics ?? [])
            .compactMap { $0.Text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        
        if !relatedTexts.isEmpty {
            parts.append(relatedTexts.joined(separator: "\n"))
        }
        
        return parts.joined(separator: "\n\n")
    }

    private func fetchWikipediaSummary(topic: String) async -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)") else { return "" }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            return decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func buildAutonomousContext(ddg: String, wiki: String) -> String {
        var parts: [String] = []
        if !ddg.isEmpty {
            parts.append("DuckDuckGo summary:\n\(ddg)")
        }
        if !wiki.isEmpty {
            parts.append("Wikipedia summary:\n\(wiki)")
        }
        return parts.joined(separator: "\n\n")
    }

    @MainActor
    private func handleSpontaneousTrigger(memoryID: UUID) async {
        guard generationTask == nil else { return }
        guard let memory = memoryService.memories.first(where: { $0.id == memoryID }) else { return }

        let topic = String(memory.content.prefix(36))
        let ddg = (try? await fetchDuckDuckGoSummary(query: topic)) ?? ""
        let wiki = await fetchWikipediaSummary(topic: topic)
        if !ddg.isEmpty {
            let snippets = splitSnippets(ddg)
            memoryService.ingestExternalSnippets(snippets, source: "duckduckgo", query: topic)
        }
        if !wiki.isEmpty {
            let snippets = splitSnippets(wiki)
            memoryService.ingestExternalSnippets(snippets, source: "wikipedia", query: topic)
        }
        let toolContext = buildAutonomousContext(ddg: ddg, wiki: wiki)
        let systemPrompt = identityService.systemPrompt + "\n" + toolContext
        let prompt = "I noticed a gap in my knowledge about \(topic). Help me understand it better."

        isInteracting = true
        lastSpontaneousAt = Date()

        let assistantMessageId = UUID()
        messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: ""))
        currentThinkingMessageId = assistantMessageId
        currentThink = ""

        generationTask = Task {
            var parser = ThinkStreamParser()
            let stream = await llmService.generate(userPrompt: prompt, systemPrompt: systemPrompt)
            for await chunk in stream {
                if Task.isCancelled { break }
                let result = parser.feed(chunk)
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if !result.visible.isEmpty, parser.allowVisibleStreaming {
                        messages[index].content += result.visible
                    }
                    if !result.think.isEmpty {
                        currentThink += result.think
                        messages[index].thinkContent? += result.think
                    }
                }
            }

            if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let tail = parser.flush()
                if !tail.visible.isEmpty, parser.allowVisibleStreaming {
                    messages[index].content += tail.visible
                }
                if !tail.think.isEmpty {
                    currentThink += tail.think
                    messages[index].thinkContent? += tail.think
                }
                messages[index].content = cleanFinalAnswer(messages[index].content)
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            generationTask = nil
        }
    }

    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        generationTask?.cancel()
        generationTask = nil
        
        let userMessage = Message(role: .user, content: inputText)
        messages.append(userMessage)
        let prompt = inputText
        inputText = ""
        
        isInteracting = true
        
        generationTask = Task {
            memoryService.updateConversationSummary(fromUserText: prompt)
            memoryService.updateUserProfile(fromUserText: prompt)
            let detail = memoryService.preferredDetailLevel(forUserText: prompt)
            memoryService.applyPredictionFeedback(fromUserText: prompt)
            memoryService.applyReinforcement(fromUserText: prompt)
            let toolContext = await aggregateToolContext(for: prompt)
            let detailBlock = "\nResponse Detail: \(detail.rawValue)\n"
            let systemPrompt = identityService.systemPrompt + toolContext + detailBlock
            // 2. Generate response
            let assistantMessageId = UUID()
            messages.append(Message(id: assistantMessageId, role: .assistant, content: "", thinkContent: ""))
            currentThinkingMessageId = assistantMessageId
            currentThink = ""
            
            var parser = ThinkStreamParser()
            let stream = await llmService.generate(userPrompt: prompt, systemPrompt: systemPrompt)
            for await chunk in stream {
                if Task.isCancelled {
                    break
                }
                let result = parser.feed(chunk)
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if !result.visible.isEmpty, parser.allowVisibleStreaming {
                        messages[index].content += result.visible
                    }
                    if !result.think.isEmpty {
                        currentThink += result.think
                        messages[index].thinkContent? += result.think
                    }
                }
            }
            
            // 3. Update memory (optional - auto-save conversation?)
            // memoryService.addMemory("Conversation: \(prompt) -> Response")
            
            if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let tail = parser.flush()
                if !tail.visible.isEmpty, parser.allowVisibleStreaming {
                    messages[index].content += tail.visible
                }
                if !tail.think.isEmpty {
                    currentThink += tail.think
                    messages[index].thinkContent? += tail.think
                }

                messages[index].content = cleanFinalAnswer(messages[index].content)

                if messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let thinkText = messages[index].thinkContent,
                   !thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let split = splitThinkIntoFinal(thinkText)
                    messages[index].thinkContent = split.think
                    messages[index].content = split.final
                }
            }

            currentThink = ""
            currentThinkingMessageId = nil
            isInteracting = false
            generationTask = nil
        }
    }

    private struct DuckDuckGoResponse: Decodable {
        let Abstract: String?
        let AbstractText: String?
        let RelatedTopics: [RelatedTopic]?
        
        struct RelatedTopic: Decodable {
            let Text: String?
        }
    }

    private struct WikipediaSummary: Decodable {
        let title: String?
        let extract: String?
    }

    private func splitSnippets(_ text: String) -> [String] {
        let chunks = text
            .split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if chunks.count > 1 { return chunks }

        let sentences = text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return sentences
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
    var cleaned = stripMetaLines(text)
    cleaned = cleaned.replacingOccurrences(of: "Final Answer:", with: "")
    cleaned = cleaned.replacingOccurrences(of: "</think>", with: "")
    cleaned = cleaned.replacingOccurrences(of: "<think>", with: "")
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
