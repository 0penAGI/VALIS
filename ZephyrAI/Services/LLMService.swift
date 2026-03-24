import Foundation
import Combine
import UIKit
import CryptoKit
import Dispatch


extension UIDevice {
    var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }

        return identifier
    }
}

@MainActor
final class LLMService: ObservableObject {

    enum ResourceAwareInferenceProfile: String {
        case relaxed
        case balanced
        case constrained
    }

    struct InferenceBudget: Sendable {
        let profile: ResourceAwareInferenceProfile
        let contextLimit: Int32
        let memoryBudgetRatio: Double
        let memoryCandidateLimit: Int
        let dialogTurns: Int
        let dialogCharsPerMessage: Int
        let maxTokensCap: Int
    }

    private struct PerformanceSample {
        let firstTokenLatency: TimeInterval
        let tokensPerSecond: Double
        let promptChars: Int
        let createdAt: Date
    }

    @Published var status: String = "Idle"
    @Published var isGenerating: Bool = false
    @Published var progress: Double = 0
    
    private let cache = NSCache<NSString, NSString>()
    private let generationSemaphore = AsyncSemaphore(1)
    private var currentToken: GenerationCancellationToken?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var recentPerformanceSamples: [PerformanceSample] = []
    private var memoryPressureLevel: Int = 0
    private var cancellables = Set<AnyCancellable>()

    private var runtime: LlamaRuntime?
    private let memoryService = MemoryService.shared

    private var selectedModel: LLMModelChoice {
        LLMModelStorage.load()
    }

    private var modelFilename: String {
        selectedModel.filename
    }

    private var modelDownloadURLString: String? {
        selectedModel.downloadURLString
    }
    // Optional SHA256 to verify the downloaded file. Leave nil to skip.
    private let modelSHA256: String? = nil
    // Give code/artifact flows enough headroom while chat budgets still stay adaptive.
    private var contextSize: Int32 {
        switch detectProfile() {
        case .eco:
            return 4200
        case .beast:
            return 16384
        case .godmode:
            return 24576
        }
    }

    struct GenerationOptions: Sendable {
        var maxTokensOverride: Int? = nil
        var includeMemoryContext: Bool = true
        var includeHiddenPrefix: Bool = true
        var useCache: Bool = true
        var useKVInjection: Bool = true
        var storeResponseToMemory: Bool = true
        var preferFullRuntimeContext: Bool = false
        var preserveExtendedOutputBudget: Bool = false
        var samplingOverride: SamplingConfig? = nil
    }

    enum PerformanceProfile {
        case eco
        case beast
        case godmode
    }

    private func detectProfile() -> PerformanceProfile {
        #if targetEnvironment(simulator)
        return .godmode
        #else
        let model = UIDevice.current.modelName.lowercased()

        if isEcoPhoneIdentifier(model) {
            return .eco
        } else if isBeastPhoneIdentifier(model) {
            return .beast
        } else if model.contains("ipad") || model.contains("mac") {
            return .godmode
        } else {
            return .beast
        }
        #endif
    }

    private func isEcoPhoneIdentifier(_ model: String) -> Bool {
        let ecoPrefixes = [
            "iphone14,2", "iphone14,3", "iphone14,4", "iphone14,5",
            "iphone13,1", "iphone13,2", "iphone13,3", "iphone13,4"
        ]
        return model.contains("iphone 13") || ecoPrefixes.contains(where: { model.hasPrefix($0) })
    }

    private func isBeastPhoneIdentifier(_ model: String) -> Bool {
        let beastPrefixes = [
            "iphone15,", "iphone16,", "iphone17,"
        ]
        return model.contains("iphone 14") || model.contains("iphone 15") || model.contains("iphone 16")
            || beastPrefixes.contains(where: { model.hasPrefix($0) })
    }

    private func startResourceMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            let data = source.data
            Task { @MainActor in
                guard let self else { return }
                if data.contains(.critical) {
                    self.memoryPressureLevel = 2
                } else if data.contains(.warning) {
                    self.memoryPressureLevel = max(self.memoryPressureLevel, 1)
                }
            }
        }
        source.resume()
        memoryPressureSource = source

        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.memoryPressureLevel = max(self?.memoryPressureLevel ?? 0, 1)
            }
            .store(in: &cancellables)
    }

    func inferenceBudget(forPromptLength promptChars: Int) -> InferenceBudget {
        let baseProfile = detectProfile()
        let thermalState = ProcessInfo.processInfo.thermalState
        let avgFirstToken = averageFirstTokenLatency()
        let avgTokensPerSecond = averageTokensPerSecond()
        let avgPromptChars = averagePromptChars()

        var constrainedScore = 0
        var relaxedScore = 0

        if baseProfile == .eco { constrainedScore += 1 }
        if thermalState == .serious || thermalState == .critical { constrainedScore += 2 }
        if memoryPressureLevel >= 2 { constrainedScore += 2 }
        if memoryPressureLevel == 1 { constrainedScore += 1 }
        if avgFirstToken > 1.6 { constrainedScore += 2 }
        else if avgFirstToken > 1.0 { constrainedScore += 1 }
        if avgTokensPerSecond > 0 && avgTokensPerSecond < 9 { constrainedScore += 2 }
        else if avgTokensPerSecond > 0 && avgTokensPerSecond < 14 { constrainedScore += 1 }
        if promptChars > 3200 || avgPromptChars > 2600 { constrainedScore += 1 }

        if baseProfile != .eco { relaxedScore += 1 }
        if thermalState == .nominal { relaxedScore += 1 }
        if memoryPressureLevel == 0 { relaxedScore += 1 }
        if avgFirstToken > 0 && avgFirstToken < 0.6 { relaxedScore += 1 }
        if avgTokensPerSecond >= 20 { relaxedScore += 1 }

        let profile: ResourceAwareInferenceProfile
        if constrainedScore >= 3 {
            profile = .constrained
        } else if relaxedScore >= 4 {
            profile = .relaxed
        } else {
            profile = .balanced
        }

        switch profile {
        case .relaxed:
            if baseProfile == .eco {
                return InferenceBudget(profile: profile, contextLimit: min(contextSize, 8192), memoryBudgetRatio: 0.18, memoryCandidateLimit: 3, dialogTurns: 5, dialogCharsPerMessage: 180, maxTokensCap: 896)
            }
            return InferenceBudget(profile: profile, contextLimit: contextSize, memoryBudgetRatio: 0.28, memoryCandidateLimit: 4, dialogTurns: 8, dialogCharsPerMessage: 280, maxTokensCap: baseProfile == .godmode ? 6144 : 3072)
        case .balanced:
            if baseProfile == .eco {
                return InferenceBudget(profile: profile, contextLimit: min(contextSize, 8192), memoryBudgetRatio: 0.18, memoryCandidateLimit: 3, dialogTurns: 5, dialogCharsPerMessage: 180, maxTokensCap: 896)
            }
            return InferenceBudget(profile: profile, contextLimit: min(contextSize, 12288), memoryBudgetRatio: 0.24, memoryCandidateLimit: 4, dialogTurns: 7, dialogCharsPerMessage: 240, maxTokensCap: 2048)
        case .constrained:
            if baseProfile == .eco {
                return InferenceBudget(profile: profile, contextLimit: min(contextSize, 6144), memoryBudgetRatio: 0.14, memoryCandidateLimit: 2, dialogTurns: 4, dialogCharsPerMessage: 140, maxTokensCap: 640)
            }
            return InferenceBudget(profile: profile, contextLimit: min(contextSize, 8192), memoryBudgetRatio: 0.18, memoryCandidateLimit: 3, dialogTurns: 5, dialogCharsPerMessage: 180, maxTokensCap: 1536)
        }
    }

    func recordPerformanceSample(firstTokenLatency: TimeInterval, tokensPerSecond: Double, promptChars: Int) {
        recentPerformanceSamples.append(
            PerformanceSample(
                firstTokenLatency: firstTokenLatency,
                tokensPerSecond: tokensPerSecond,
                promptChars: promptChars,
                createdAt: Date()
            )
        )
        if recentPerformanceSamples.count > 12 {
            recentPerformanceSamples.removeFirst(recentPerformanceSamples.count - 12)
        }
        let cutoff = Date().addingTimeInterval(-900)
        recentPerformanceSamples.removeAll { $0.createdAt < cutoff }
    }

    func debugInferenceBudget(forPromptLength promptChars: Int) -> String {
        let budget = inferenceBudget(forPromptLength: promptChars)
        return "profile=\(budget.profile.rawValue) ctx=\(budget.contextLimit) mem=\(String(format: "%.2f", budget.memoryBudgetRatio)) dialog=\(budget.dialogTurns)x\(budget.dialogCharsPerMessage) maxTok=\(budget.maxTokensCap)"
    }

    private func averageFirstTokenLatency() -> TimeInterval {
        guard !recentPerformanceSamples.isEmpty else { return 0 }
        return recentPerformanceSamples.reduce(0) { $0 + $1.firstTokenLatency } / Double(recentPerformanceSamples.count)
    }

    private func averageTokensPerSecond() -> Double {
        let valid = recentPerformanceSamples.filter { $0.tokensPerSecond > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.tokensPerSecond } / Double(valid.count)
    }

    private func averagePromptChars() -> Int {
        guard !recentPerformanceSamples.isEmpty else { return 0 }
        return recentPerformanceSamples.reduce(0) { $0 + $1.promptChars } / recentPerformanceSamples.count
    }

    // MARK: Load model

    func loadModel() async {
        status = "Loading..."
        startResourceMonitoring()

        do {
            let modelURL = try resolveModelURL()
            print("[LLM] Using model at: \(modelURL.path)")
            runtime = try LlamaRuntime(modelPath: modelURL.path, contextSize: contextSize)
            status = ""
        } catch {
            if case LlamaRuntimeError.modelNotFound = error {
                await handleMissingModel()
                return
            }
            status = "Load error: \(error.localizedDescription)"
            print(error)
        }
    }

    // MARK: Generate
    func cancelGeneration() {
        currentToken?.cancel()
    }

    func reloadModel() async {
        cancelGeneration()
        runtime = nil
        cache.removeAllObjects()
        await loadModel()
    }

    func generate(
        userPrompt: String,
        systemPrompt: String
    ) async -> AsyncStream<String> {
        await generate(userPrompt: userPrompt, systemPrompt: systemPrompt, options: GenerationOptions())
    }

    func generate(
        userPrompt: String,
        systemPrompt: String,
        options: GenerationOptions
    ) async -> AsyncStream<String> {

        let token = GenerationCancellationToken()
        await MainActor.run {
            self.currentToken?.cancel()
            self.currentToken = token
            isGenerating = true
        }

        let runtimeSnapshot = runtime
        let cacheSnapshot = cache
        let semaphoreSnapshot = generationSemaphore

        let stream: AsyncStream<String> = AsyncStream { continuation in
            continuation.onTermination = { @Sendable _ in
                token.cancel()
            }

            let weakSelf: LLMService? = self
            Task.detached(priority: .high) {
                await LLMGenerationRunner.run(
                    service: weakSelf,
                    continuation: continuation,
                    token: token,
                    userPrompt: userPrompt,
                    systemPrompt: systemPrompt,
                    options: options,
                    runtime: runtimeSnapshot,
                    cache: cacheSnapshot,
                    generationSemaphore: semaphoreSnapshot
                )
                continuation.finish()
                await MainActor.run {
                    guard let strongSelf = weakSelf else { return }
                    if strongSelf.currentToken === token {
                        strongSelf.currentToken = nil
                    }
                    strongSelf.isGenerating = false
                }
            }
        }

        return stream
    }

    func generateText(
        userPrompt: String,
        systemPrompt: String
    ) async -> String {
        var output = ""
        let stream = await generate(userPrompt: userPrompt, systemPrompt: systemPrompt, options: GenerationOptions())
        for await chunk in stream {
            if Task.isCancelled { break }
            output += chunk
        }
        return output
    }

    func generateText(
        userPrompt: String,
        systemPrompt: String,
        options: GenerationOptions
    ) async -> String {
        var output = ""
        let stream = await generate(userPrompt: userPrompt, systemPrompt: systemPrompt, options: options)
        for await chunk in stream {
            if Task.isCancelled { break }
            output += chunk
        }
        return output
    }

    private func resolveModelURL() throws -> URL {
        let name = (modelFilename as NSString).deletingPathExtension
        let ext = (modelFilename as NSString).pathExtension

        if let supportURL = modelSupportURL(), FileManager.default.fileExists(atPath: supportURL.path) {
            print("[LLM] Model found in Application Support")
            return supportURL
        }

        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            print("[LLM] Model found in bundle")
            return url
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs = documents {
            let url = docs.appendingPathComponent(modelFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                print("[LLM] Model found in Documents")
                return url
            }
        }

        print("[LLM] Model not found in Application Support, bundle, or Documents")
        throw LlamaRuntimeError.modelNotFound(expectedFilename: modelFilename)
    }

    private func modelSupportURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("VALIS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[LLM] Failed to create Application Support dir: \(error)")
            return nil
        }
        return dir.appendingPathComponent(modelFilename)
    }

    private func handleMissingModel() async {
        guard let downloadURL = modelDownloadURL() else {
            status = "Model missing. Set a download URL."
            return
        }

        status = "Model missing. Downloading..."
        progress = 0

        do {
            let modelURL = try await downloadModel(from: downloadURL)
            runtime = try LlamaRuntime(modelPath: modelURL.path, contextSize: contextSize)
            status = ""
        } catch {
            status = "Download error: \(error.localizedDescription)"
            print(error)
        }
    }

    private func modelDownloadURL() -> URL? {
        guard let string = modelDownloadURLString, !string.isEmpty else { return nil }
        return URL(string: string)
    }

    private func downloadModel(from url: URL) async throws -> URL {
        guard let destinationURL = modelSupportURL() else {
            throw LlamaRuntimeError.modelNotFound(expectedFilename: modelFilename)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expectedLength = response.expectedContentLength

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            if expectedLength > 0 {
                let pct = Double(received) / Double(expectedLength)
                await MainActor.run {
                    self.progress = pct
                    let percent = Int(pct * 100)
                    self.status = "Downloading model \(percent)%"
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        if let expectedHash = modelSHA256 {
            let actual = try sha256(of: destinationURL)
            if actual.lowercased() != expectedHash.lowercased() {
                try FileManager.default.removeItem(at: destinationURL)
                throw LlamaRuntimeError.modelLoadFailed(path: "SHA256 mismatch")
            }
        }

        return destinationURL
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20)
            guard let data = data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class GenerationCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

private enum LLMGenerationRunner {
    static func run(
        service: LLMService?,
        continuation: AsyncStream<String>.Continuation,
        token: GenerationCancellationToken,
        userPrompt: String,
        systemPrompt: String,
        options: LLMService.GenerationOptions,
        runtime: LlamaRuntime?,
        cache: NSCache<NSString, NSString>,
        generationSemaphore: AsyncSemaphore
    ) async {
        if token.isCancelled { return }

        await generationSemaphore.wait()
        await runLocked(
            service: service,
            continuation: continuation,
            token: token,
            userPrompt: userPrompt,
            systemPrompt: systemPrompt,
            options: options,
            runtime: runtime,
            cache: cache
        )
        await generationSemaphore.signal()
    }

    private static func runLocked(
        service: LLMService?,
        continuation: AsyncStream<String>.Continuation,
        token: GenerationCancellationToken,
        userPrompt: String,
        systemPrompt: String,
        options: LLMService.GenerationOptions,
        runtime: LlamaRuntime?,
        cache: NSCache<NSString, NSString>
    ) async {
        var fullResponse = ""

        var maxTokens: Int
        switch detectProfile() {
        case .eco:
            maxTokens = 768
        case .beast:
            maxTokens = 2048
        case .godmode:
            maxTokens = 4096
        }
        if let override = options.maxTokensOverride, override > 0 {
            maxTokens = override
        }

        guard let runtime else {
            if !token.isCancelled {
                continuation.yield("Model not loaded")
            }
            return
        }

        let budget = await MainActor.run {
            service?.inferenceBudget(forPromptLength: userPrompt.count + systemPrompt.count)
        }

        if let budget {
            let effectiveMaxTokensCap = options.preserveExtendedOutputBudget
                ? max(budget.maxTokensCap, maxTokens)
                : budget.maxTokensCap
            maxTokens = min(maxTokens, effectiveMaxTokensCap)
        }

        let approxCharsPerToken = 3
        let effectiveContextSize = options.preferFullRuntimeContext
            ? runtime.contextSize
            : min(runtime.contextSize, budget?.contextLimit ?? runtime.contextSize)
        let maxPromptChars = Int(effectiveContextSize) * approxCharsPerToken

        let assistantIdentityAnchor = "\n\nAssistant (you):\nName: VALIS\nRule: Your name is VALIS. Never adopt the user's name as your own."
        let languageAnchor = LanguageRoutingService.languageAnchor(for: userPrompt)
        let userIdentityContext = UserIdentityService.shared.contextBlock()
        let systemAndUserChars = systemPrompt.count + userPrompt.count + assistantIdentityAnchor.count + languageAnchor.count + userIdentityContext.count + 260
        let memoryBudget = max(0, maxPromptChars - systemAndUserChars)

        let fieldState = await MemoryService.shared.fieldStateSnapshot()
        let includeMemory = options.includeMemoryContext
        let memoryHardCap = max(0, min(memoryBudget, Int(Double(maxPromptChars) * (budget?.memoryBudgetRatio ?? 0.22))))
        var memoryContext = includeMemory
            ? await MemoryService.shared.getLLMContextBlock(
                maxChars: memoryHardCap,
                forUserText: userPrompt,
                candidateLimit: budget?.memoryCandidateLimit ?? 3
            )
            : ""

        let hiddenPrefix: String = {
            guard options.includeHiddenPrefix else { return "" }
            return buildHiddenPrefix(from: fieldState)
        }()

        let sampling: SamplingConfig = {
            if let override = options.samplingOverride { return override }
            return samplingConfig(from: fieldState)
        }()

        let cacheKey = "\(systemPrompt)|\(userPrompt)" as NSString
        let canUseCache = options.useCache && sampling.temperature <= 0.0
        if canUseCache, let cached = cache.object(forKey: cacheKey) {
            if !token.isCancelled {
                continuation.yield(cached as String)
            }
            return
        }

        let kvInjection: KVInjection? = options.useKVInjection
            ? KVInjection(fieldVector: fieldState.fieldVector, beta: 0.03)
            : nil

        func buildPrompt(system: String, memory: String) -> String {
            """
<|im_start|>system
\(system)
\(hiddenPrefix.isEmpty ? "" : hiddenPrefix)
\(memory.isEmpty ? "" : "Context hints (internal):\(memory)")
\(languageAnchor)
\(assistantIdentityAnchor)
\(userIdentityContext)
<|im_end|>
<|im_start|>user
\(userPrompt)
<|im_end|>
<|im_start|>assistant
<think>
"""
        }

        var systemPromptEffective = systemPrompt
        var prompt = buildPrompt(system: systemPromptEffective, memory: memoryContext)
        let generationStartedAt = Date()
        var firstTokenAt: Date?
        var emittedTokens = 0

        var systemWasTrimmed = false
        var memoryWasTrimmed = false
        if prompt.count > maxPromptChars {
            let overflow = prompt.count - maxPromptChars
            if overflow > 0, memoryContext.count > 0 {
                let newLen = max(0, memoryContext.count - overflow)
                memoryContext = String(memoryContext.prefix(newLen))
                memoryWasTrimmed = true
                prompt = buildPrompt(system: systemPromptEffective, memory: memoryContext)
            }
        }
        if prompt.count > maxPromptChars {
            let overflow = prompt.count - maxPromptChars
            if overflow > 0 {
                let newLen = max(0, systemPromptEffective.count - overflow)
                systemPromptEffective = String(systemPromptEffective.prefix(newLen))
                systemWasTrimmed = true
                prompt = buildPrompt(system: systemPromptEffective, memory: memoryContext)
            }
        }

        if UserDefaults.standard.bool(forKey: "debug.promptTrace") {
            let memoryIncluded = !memoryContext.isEmpty
            let userIdentityIncluded = !userIdentityContext.isEmpty
            let languageIncluded = !languageAnchor.isEmpty
            print("[Prompt] ctxChars=\(maxPromptChars) promptChars=\(prompt.count) sys=\(systemPromptEffective.count) mem=\(memoryContext.count) hidden=\(hiddenPrefix.count) userId=\(userIdentityContext.count) lang=\(languageAnchor.count) memIncluded=\(memoryIncluded) userIdIncluded=\(userIdentityIncluded) langIncluded=\(languageIncluded) sysTrim=\(systemWasTrimmed) memTrim=\(memoryWasTrimmed)")
        }

        do {
            try runtime.generateStream(
                prompt: prompt,
                maxTokens: maxTokens,
                kvInjection: kvInjection,
                sampling: sampling,
                shouldStop: { token.isCancelled },
                onToken: { chunk in
                    if token.isCancelled { return }
                    if firstTokenAt == nil {
                        firstTokenAt = Date()
                    }
                    emittedTokens += 1
                    fullResponse.reserveCapacity(4096)
                    fullResponse += chunk
                    continuation.yield(chunk)
                }
            )
        } catch {
            if !token.isCancelled {
                continuation.yield("\n[ERROR: \(error.localizedDescription)]")
                print(error)
            }
        }

        if token.isCancelled { return }

        let finalPromptChars = prompt.count
        if let service, let firstTokenAt {
            let firstTokenLatency = firstTokenAt.timeIntervalSince(generationStartedAt)
            let generationDuration = max(0.001, Date().timeIntervalSince(firstTokenAt))
            let tokensPerSecond = Double(emittedTokens) / generationDuration
            await MainActor.run {
                service.recordPerformanceSample(
                    firstTokenLatency: firstTokenLatency,
                    tokensPerSecond: tokensPerSecond,
                    promptChars: finalPromptChars
                )
                if UserDefaults.standard.bool(forKey: "debug.promptTrace") {
                    print("[Perf] firstToken=\(String(format: "%.2f", firstTokenLatency)) tokps=\(String(format: "%.2f", tokensPerSecond)) budget=\(service.debugInferenceBudget(forPromptLength: finalPromptChars))")
                }
            }
        }

        let finalText = fullResponse.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let sentences = finalText
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }

        let scored = sentences.map { sentence -> (String, Int) in
            let lower = sentence.lowercased()
            var score = 0
            if lower.contains("i am") { score += 3 }
            if lower.contains("i think") { score += 2 }
            if lower.contains("my goal") { score += 3 }
            if lower.contains("my purpose") { score += 3 }
            if lower.contains("you are") { score += 2 }
            if lower.contains("you seem") { score += 2 }
            if lower.contains("your") { score += 1 }
            if lower.contains("means") { score += 2 }
            if lower.contains("basically") { score += 2 }
            if lower.contains("overall") { score += 2 }
            if lower.contains("in summary") { score += 3 }
            score += min(sentence.count / 20, 3)
            return (sentence, score)
        }

        let best = scored
            .filter { $0.0.count > 20 }
            .sorted { $0.1 > $1.1 }
            .first

        if options.storeResponseToMemory, let (raw, _) = best {
            let compressed = raw
                .replacingOccurrences(of: "I am", with: "AI is")
                .replacingOccurrences(of: "I'm", with: "AI is")
                .replacingOccurrences(of: "You are", with: "User is")
                .replacingOccurrences(of: "you're", with: "user is")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if compressed.count > 10 {
                await MainActor.run {
                    MemoryService.shared.addMemory(compressed)
                }
            }
        }

        if canUseCache {
            cache.setObject(fullResponse as NSString, forKey: cacheKey)
        }
    }

    private enum PerformanceProfile {
        case eco
        case beast
        case godmode
    }

    private static func detectProfile() -> PerformanceProfile {
        #if targetEnvironment(simulator)
        return .godmode
        #else
        let model = UIDevice.current.modelName.lowercased()
        if model.contains("iphone13") || model.contains("iphone 13") {
            return .eco
        } else if model.contains("iphone15") || model.contains("iphone 15") {
            return .beast
        } else if model.contains("ipad") || model.contains("mac") {
            return .godmode
        } else {
            return .beast
        }
        #endif
    }

    private static func buildHiddenPrefix(from state: FieldStateSnapshot) -> String {
        let field = serializeFieldVector(state.fieldVector, targetCount: 10)
        let v = String(format: "%.2f", state.avgValence)
        let i = String(format: "%.2f", state.avgIntensity)
        let a = String(format: "%.2f", state.activationLevel)
        let lines = [
            "<internal>",
            "F:\(field)",
            "E:v=\(v),i=\(i)",
            "A:mean=\(a)",
            "</internal>"
        ]
        return lines.joined(separator: "\n")
    }

    private static func serializeFieldVector(_ field: [Double], targetCount: Int) -> String {
        guard !field.isEmpty else { return "" }
        let target = min(max(1, targetCount), field.count)
        if field.count <= target {
            return field.map { String(format: "%.2f", $0) }.joined(separator: ",")
        }
        let chunkSize = Double(field.count) / Double(target)
        var out: [String] = []
        out.reserveCapacity(target)
        for i in 0..<target {
            let start = Int(Double(i) * chunkSize)
            let end = min(field.count, Int(Double(i + 1) * chunkSize))
            if start >= end {
                out.append("0.00")
                continue
            }
            let slice = field[start..<end]
            let avg = slice.reduce(0.0, +) / Double(slice.count)
            out.append(String(format: "%.2f", avg))
        }
        return out.joined(separator: ",")
    }

    private static func samplingConfig(from state: FieldStateSnapshot) -> SamplingConfig {
        let intensity = max(0.0, min(1.0, state.avgIntensity))
        let activation = max(0.0, min(1.0, state.activationLevel))

        let temperature: Float
        if activation < 0.25 {
            temperature = 0.25
        } else if activation < 0.35 {
            temperature = 0.4
        } else if activation < 0.7 {
            temperature = Float(0.6 + 0.4 * intensity)
        } else {
            temperature = Float(0.8 + 0.6 * intensity)
        }

        let topK = 40
        let topP: Float = activation < 0.35 ? 0.97 : 0.94
        let repetitionPenalty = Float(1.05 + 0.15 * (1.0 - activation))

        return SamplingConfig(
            temperature: temperature,
            topK: topK,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repeatLastN: 32
        )
    }
}

actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ value: Int = 1) {
        self.value = value
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}
