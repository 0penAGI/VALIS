import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// llama.cpp backend state is process-wide. Swift initializes this static exactly once,
/// even if model reloads construct runtimes on different queues at the same time.
private enum LlamaBackendLifecycle {
    static let initialized: Void = {
        llama_backend_init()
    }()
}

enum LlamaRuntimeError: LocalizedError {
    case modelNotFound(expectedFilename: String)
    case backendInitFailed
    case modelLoadFailed(path: String)
    case contextInitFailed
    case tokenizationFailed
    case decodeFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let expectedFilename):
            return "Model not found. Expected \(expectedFilename) in app bundle or Documents."
        case .backendInitFailed:
            return "Failed to initialize llama backend."
        case .modelLoadFailed(let path):
            return "Failed to load model at \(path)."
        case .contextInitFailed:
            return "Failed to create llama context."
        case .tokenizationFailed:
            return "Tokenization failed."
        case .decodeFailed(let code):
            return "Decode failed with code \(code)."
        }
    }
}

struct SamplingConfig: Sendable {
    let temperature: Float
    let topK: Int
    let topP: Float
    let repetitionPenalty: Float
    let repeatLastN: Int
    
    init(
        temperature: Float,
        topK: Int,
        topP: Float = 0.95,
        repetitionPenalty: Float,
        repeatLastN: Int
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repeatLastN = repeatLastN
    }

    static let `default` = SamplingConfig(
        temperature: 0.7,
        topK: 40,
        topP: 0.95,
        repetitionPenalty: 1.1,
        repeatLastN: 64
    )
}

final class LlamaRuntime {
    private struct PromptPrefixSnapshot {
        let stateData: Data
        let tokenCount: Int32
        let tokens: [llama_token]
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var tokenCount: Int32 = 0
    private var samplingTopIndices: [Int] = []
    private var samplingTopLogits: [Float] = []
    private var samplingProbs: [Float] = []
    private var samplingOrder: [Int] = []
    private let stateLock = NSLock()
    private var promptPrefixCache: [String: PromptPrefixSnapshot] = [:]
    private var promptPrefixCacheOrder: [String] = []
    private var promptPrefixCacheBytes = 0
    private var pendingContextShrinkTarget: Int32?

    private static let prefixCacheBudgetFraction = 0.10
    private static let prefixCacheMaxBudgetBytes = 1024 * 1024 * 1024
    private static let prefixCacheHardEntryLimit = 8

    var contextSize: Int32
    private let batchSize: Int32
    private let threadCount: Int32
    private let gpuLayerCount: Int32
    private static let loadLogs: ggml_log_callback = { level, message, _ in
        guard let message else { return }
        let text = String(cString: message)
        print("[Llama][\(level.rawValue)] \(text)")
    }

    init(modelPath: String, contextSize: Int32, threads: Int32? = nil, isSmallModel: Bool = false) throws {
        self.contextSize = max(1, contextSize)
        let gpuLayers = Self.recommendedGPULayerCount(
            modelPath: modelPath,
            contextSize: self.contextSize,
            isSmallModel: isSmallModel
        )
        self.gpuLayerCount = gpuLayers
        self.threadCount = threads ?? Self.recommendedThreadCount(gpuLayers: gpuLayers)

        llama_log_set(LlamaRuntime.loadLogs, nil)
        print("[Llama] Initializing backend (process lifetime)")
        _ = LlamaBackendLifecycle.initialized
        if let info = llama_print_system_info() {
            print("[Llama] System info: \(String(cString: info))")
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers
        print("[Llama] GPU offload layers: \(gpuLayers)")

        print("[Llama] Loading model: \(modelPath)")
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaRuntimeError.modelLoadFailed(path: modelPath)
        }

        let trainedCtx = llama_model_n_ctx_train(model)
        if trainedCtx > 0 && trainedCtx < Int32.max {
            let trained = Int32(trainedCtx)
            if trained < self.contextSize {
                print("[Llama] Clamping context size to model n_ctx_train=\(trained)")
                self.contextSize = max(1, trained)
            }
        }

        // Для маленькой модели уменьшаем batch size (A15 не тянет 256)
        let maxBatch = isSmallModel ? 128 : 256
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, self.contextSize))
        ctxParams.n_batch = UInt32(min(maxBatch, Int(self.contextSize)))
        Self.applyQuantizedKV(to: &ctxParams, contextSize: self.contextSize)

        print("[Llama] Creating context (n_ctx=\(ctxParams.n_ctx), n_batch=\(ctxParams.n_batch))")
        guard let ctx = Self.createContext(model: model, baseParams: ctxParams, contextSize: self.contextSize) else {
            llama_model_free(model)
            throw LlamaRuntimeError.contextInitFailed
        }

        self.model = model
        self.context = ctx
        self.batchSize = Int32(ctxParams.n_batch)
        if let vocabPtr = llama_model_get_vocab(model) {
            self.vocab = OpaquePointer(UnsafeRawPointer(vocabPtr))
        } else {
            self.vocab = nil
        }

        print("[Llama] Using threads: \(self.threadCount)")
        llama_set_n_threads(ctx, self.threadCount, self.threadCount)
    }

    private static func recommendedGPULayerCount(
        modelPath: String,
        contextSize: Int32,
        isSmallModel: Bool
    ) -> Int32 {
        #if targetEnvironment(simulator)
        return isSmallModel ? 14 : 22
        #elseif canImport(UIKit)
        let model = UIDevice.current.modelName.lowercased()
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let modelSizeGB = estimatedModelSizeInGB(at: modelPath)

        var layers: Int32

        if model.contains("iphone 13") || model.contains("iphone 14") {
            layers = isSmallModel ? 8 : 12
        } else if model.contains("iphone 15") || model.contains("iphone 16") || model.contains("iphone 17") {
            layers = isSmallModel ? 14 : 20
        } else if model.contains("ipad") || model.contains("mac") {
            layers = isSmallModel ? 20 : 28
        } else {
            layers = isSmallModel ? 10 : 15
        }

        if memoryGB >= 8 {
            layers += 4
        } else if memoryGB >= 6 {
            layers += 2
        } else if memoryGB <= 4.5 {
            layers -= 3
        }

        if modelSizeGB >= 10 {
            layers -= 6
        } else if modelSizeGB >= 6 {
            layers -= 3
        } else if modelSizeGB > 0, modelSizeGB <= 3.5 {
            layers += 2
        }

        if contextSize >= 8_192 {
            layers -= 4
        } else if contextSize >= 4_096 {
            layers -= 2
        }

        let minLayers: Int32 = isSmallModel ? 6 : 8
        let maxLayers: Int32 = model.contains("ipad") || model.contains("mac") ? 34 : 24
        return max(minLayers, min(maxLayers, layers))
        #else
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let modelSizeGB = estimatedModelSizeInGB(at: modelPath)

        var layers: Int32

        if model.contains("iphone 13") || model.contains("iphone 14") {
            layers = isSmallModel ? 8 : 12
        } else if model.contains("iphone 15") || model.contains("iphone 16") || model.contains("iphone 17") {
            layers = isSmallModel ? 14 : 20
        } else if model.contains("ipad") || model.contains("mac") {
            layers = isSmallModel ? 20 : 28
        } else {
            layers = isSmallModel ? 10 : 15
        }

        if memoryGB >= 8 {
            layers += 4
        } else if memoryGB >= 6 {
            layers += 2
        } else if memoryGB <= 4.5 {
            layers -= 3
        }

        if modelSizeGB >= 10 {
            layers -= 6
        } else if modelSizeGB >= 6 {
            layers -= 3
        } else if modelSizeGB > 0, modelSizeGB <= 3.5 {
            layers += 2
        }

        if contextSize >= 8_192 {
            layers -= 4
        } else if contextSize >= 4_096 {
            layers -= 2
        }

        let minLayers: Int32 = isSmallModel ? 6 : 8
        let maxLayers: Int32 = 34
        return max(minLayers, min(maxLayers, layers))
        #endif
    }

    /// Q8_0 KV cache: ~2x less memory + less bandwidth per decoded token vs F16,
    /// with negligible quality loss on the local models. K is attention-critical
    /// (dot product), so keep it Q8_0 everywhere; V can go Q4_0 on constrained
    /// devices (low RAM / older iPhone / big context / power-saving / hot) since
    /// V does not participate in dot products and tolerates coarser quantization.
    private static func recommendedKVTypeK() -> ggml_type { GGML_TYPE_Q8_0 }

    private static func recommendedKVTypeV(contextSize: Int32) -> ggml_type {
        #if canImport(UIKit)
        let device = UIDevice.current.modelName.lowercased()
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let thermal = ProcessInfo.processInfo.thermalState
        let constrained = memoryGB < 6
            || device.contains("iphone 13") || device.contains("iphone 14")
            || contextSize >= 12_288
            || ProcessInfo.processInfo.isLowPowerModeEnabled
            || thermal == .serious
            || thermal == .critical
        return constrained ? GGML_TYPE_Q4_0 : GGML_TYPE_Q8_0
        #else
        return GGML_TYPE_Q8_0
        #endif
    }

    private static func applyQuantizedKV(to ctxParams: inout llama_context_params, contextSize: Int32) {
        ctxParams.type_k = Self.recommendedKVTypeK()
        ctxParams.type_v = Self.recommendedKVTypeV(contextSize: contextSize)
    }

    /// Creates the context, applying quantized KV types with a safe fallback.
    ///
    /// Quantized V cache requires Flash Attention, which llama.cpp auto-disables
    /// for models/tensors it cannot place on the requested device (e.g. hybrid
    /// Gated Delta Net models on Metal). When that happens llama_init_from_model
    /// returns NULL; we retry once with V back to F16 (K stays Q8, no loss).
    private static func createContext(
        model: OpaquePointer,
        baseParams: llama_context_params,
        contextSize: Int32
    ) -> OpaquePointer? {
        let desiredV = Self.recommendedKVTypeV(contextSize: contextSize)
        if desiredV == GGML_TYPE_F16 {
            var params = baseParams
            Self.applyQuantizedKV(to: &params, contextSize: contextSize)
            return llama_init_from_model(model, params)
        }

        var primary = baseParams
        Self.applyQuantizedKV(to: &primary, contextSize: contextSize)
        if let ctx = llama_init_from_model(model, primary) {
            return ctx
        }

        print("[Llama] Quantized V cache rejected (needs Flash Attention); falling back to V=F16 (K stays Q8_0).")
        var fallback = primary
        fallback.type_v = GGML_TYPE_F16
        return llama_init_from_model(model, fallback)
    }

    private static func recommendedThreadCount(gpuLayers: Int32) -> Int32 {
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var threads = cpuCount - 1

        if gpuLayers >= 24 {
            threads -= 2
        } else if gpuLayers >= 16 {
            threads -= 1
        }

        return Int32(max(1, threads))
    }

    private static func estimatedModelSizeInGB(at path: String) -> Double {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return fileSize.doubleValue / 1_073_741_824.0
    }

    deinit {
        if let ctx = context {
            llama_free(ctx)
        }
        if let model = model {
            llama_model_free(model)
        }
    }

    private func rebuildContext() throws {
        guard let model = self.model else {
            throw LlamaRuntimeError.contextInitFailed
        }
        if let ctx = context {
            llama_free(ctx)
            self.context = nil
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, self.contextSize))
        ctxParams.n_batch = UInt32(max(1, min(Int(self.batchSize), Int(self.contextSize))))
        Self.applyQuantizedKV(to: &ctxParams, contextSize: self.contextSize)

        guard let newCtx = Self.createContext(model: model, baseParams: ctxParams, contextSize: self.contextSize) else {
            throw LlamaRuntimeError.contextInitFailed
        }

        self.context = newCtx
        self.tokenCount = 0

        let threads = Self.recommendedThreadCount(gpuLayers: gpuLayerCount)
        llama_set_n_threads(newCtx, threads, threads)
        clearPrefixCache()
    }

    // MARK: - Memory pressure

    /// Reacts to OS memory pressure. The prefix KV snapshots are the largest
    /// reclaimable allocations we own, so we trim them immediately; the context
    /// itself is shrunk lazily at the next generation start (never mid-decode).
    func handleMemoryPressure(level: Int) {
        switch level {
        case 2...:
            clearPrefixCache()
            requestContextShrink(to: 8192)
        case 1:
            trimPrefixCache(toBytes: Self.prefixCacheBudgetBytes() / 2)
            requestContextShrink(to: 16384)
        default:
            break
        }
    }

    private func requestContextShrink(to target: Int32) {
        stateLock.lock()
        if let existing = pendingContextShrinkTarget {
            pendingContextShrinkTarget = min(existing, target)
        } else {
            pendingContextShrinkTarget = target
        }
        stateLock.unlock()
    }

    private func takePendingContextShrinkTarget() -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let target = pendingContextShrinkTarget
        pendingContextShrinkTarget = nil
        return target
    }

    func applyPendingContextShrinkIfNeeded() throws {
        guard let target = takePendingContextShrinkTarget() else { return }
        let clamped = min(contextSize, target)
        guard clamped >= 4096, clamped < contextSize else { return }
        print("[Llama] Memory pressure: shrinking context \(contextSize) -> \(clamped)")
        contextSize = clamped
        try rebuildContext()
    }

    func generateStream(
        prompt: String,
        maxTokens: Int,
        kvInjection: KVInjection? = nil,
        sampling: SamplingConfig = .default,
        shouldStop: () -> Bool,
        onToken: (String) -> Void
    ) throws {
        try generateStream(
            promptPrefix: "",
            prompt: prompt,
            maxTokens: maxTokens,
            kvInjection: kvInjection,
            sampling: sampling,
            shouldStop: shouldStop,
            onToken: onToken
        )
    }

    func generateStream(
        promptPrefix: String,
        prompt: String,
        maxTokens: Int,
        kvInjection: KVInjection? = nil,
        sampling: SamplingConfig = .default,
        shouldStop: () -> Bool,
        onToken: (String) -> Void
    ) throws {
        try applyPendingContextShrinkIfNeeded()

        guard var ctx = context, let vocab = vocab else {
            throw LlamaRuntimeError.contextInitFailed
        }

        if shouldStop() { return }

        let prefixKey = promptPrefix.isEmpty ? nil : promptPrefix
        print("[Llama] Tokenizing prompt (prefixLen=\(promptPrefix.count), suffixLen=\(prompt.count))")
        let cachedPrefix = prefixKey.flatMap { cachedPrefixSnapshot(for: $0) }
        let prefixTokens: [llama_token]
        if let cachedPrefix {
            prefixTokens = cachedPrefix.tokens
        } else if promptPrefix.isEmpty {
            prefixTokens = []
        } else {
            prefixTokens = try tokenize(promptPrefix, vocab: vocab)
        }

        let suffixTokens = try tokenize(prompt, vocab: vocab)
        let maxPromptTokens = max(1, Int(contextSize) - 256)
        let allPromptTokens = prefixTokens + suffixTokens
        let promptTooLong = allPromptTokens.count > maxPromptTokens
        let canReusePrefix = prefixKey != nil && !promptTooLong && cachedPrefix != nil

        if tokenCount > 0 {
            if !canReusePrefix {
                try rebuildContext()
                guard let refreshed = context else {
                    throw LlamaRuntimeError.contextInitFailed
                }
                ctx = refreshed
            }
        }

        var didRestorePrefix = false
        if let cachedPrefix, canReusePrefix {
            let restored = try restorePromptSnapshot(cachedPrefix, into: &ctx)
            if restored {
                tokenCount = cachedPrefix.tokenCount
                didRestorePrefix = true
            } else {
                try rebuildContext()
                guard let refreshed = context else {
                    throw LlamaRuntimeError.contextInitFailed
                }
                ctx = refreshed
            }
        }

        let prefixDecodeTokens: [llama_token]
        let suffixDecodeTokens: [llama_token]
        if promptTooLong {
            print("[Llama] Prompt too long (\(allPromptTokens.count) tokens). Trimming to \(maxPromptTokens).")
            let decodeTokens = Array(allPromptTokens.suffix(maxPromptTokens))
            prefixDecodeTokens = []
            suffixDecodeTokens = decodeTokens
            tokenCount = 0
        } else if didRestorePrefix {
            prefixDecodeTokens = []
            suffixDecodeTokens = suffixTokens
        } else {
            prefixDecodeTokens = prefixTokens
            suffixDecodeTokens = suffixTokens
            tokenCount = 0
        }

        func decodeChunk(_ chunk: [llama_token]) throws {
            if chunk.isEmpty { return }
            if shouldStop() { return }

            var local = chunk
            let result = local.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
                let r = llama_decode(ctx, batch)
                if r == 0 {
                    tokenCount += Int32(buffer.count)
                }
                return r
            }

            if result == 0 { return }

            // 1 = could not find a KV slot for the batch; retry smaller chunks.
            if result == 1, chunk.count > 1 {
                let mid = chunk.count / 2
                try decodeChunk(Array(chunk[0..<mid]))
                try decodeChunk(Array(chunk[mid..<chunk.count]))
                return
            }

            throw LlamaRuntimeError.decodeFailed(code: result)
        }

        var index = 0
        while index < prefixDecodeTokens.count {
            if shouldStop() { return }
            let end = min(prefixDecodeTokens.count, index + Int(batchSize))
            let slice = Array(prefixDecodeTokens[index..<end])
            try decodeChunk(slice)
            index = end
        }

        if let prefixKey,
           promptPrefix.isEmpty == false,
           cachedPrefix == nil,
           prefixDecodeTokens.count == prefixTokens.count {
            cachePromptPrefix(prefixKey, ctx: ctx, tokens: prefixTokens)
        }

        index = 0
        while index < suffixDecodeTokens.count {
            if shouldStop() { return }
            let end = min(suffixDecodeTokens.count, index + Int(batchSize))
            let slice = Array(suffixDecodeTokens[index..<end])
            try decodeChunk(slice)
            index = end
        }

        if let kvInjection, let model = model {
            let nEmb = Int(llama_model_n_embd(model))
            let projected = projectFieldVector(kvInjection.fieldVector, targetCount: nEmb)
            if !projected.isEmpty {
                _ = KVCacheInjector.applyV(
                    ctx: ctx,
                    vector: projected,
                    beta: kvInjection.beta
                )
            }
        }

        var utf8Buffer: [UInt8] = []
        let availableTokens = max(32, Int(contextSize) - Int(tokenCount) - 32)
        let generationLimit = min(maxTokens, availableTokens)
        if generationLimit < maxTokens {
            print("[Llama] Capping maxTokens to \(generationLimit) to fit context.")
        }

        let sampler = try buildSamplerChain(sampling: sampling)
        defer { llama_sampler_free(sampler) }

        for token in prefixDecodeTokens + suffixDecodeTokens {
            llama_sampler_accept(sampler, token)
        }

        for _ in 0..<generationLimit {
            if shouldStop() { return }
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            var nextTokens = [token]
            let decodeResult = nextTokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, 1)
                let r = llama_decode(ctx, batch)
                if r == 0 {
                    tokenCount += 1
                }
                return r
            }

            if decodeResult != 0 {
                throw LlamaRuntimeError.decodeFailed(code: decodeResult)
            }

            llama_sampler_accept(sampler, token)

            if let bytes = tokenToPieceBytes(token, vocab: vocab) {
                utf8Buffer.append(contentsOf: bytes)
                let cutoff = utf8DecodableCutoffIndex(utf8Buffer)
                if cutoff > 0 {
                    let emit = Array(utf8Buffer.prefix(cutoff))
                    if let text = String(bytes: emit, encoding: .utf8), !text.isEmpty {
                        onToken(text)
                    }
                    utf8Buffer.removeFirst(cutoff)
                }
            }
        }

        if shouldStop() { return }

        if !utf8Buffer.isEmpty {
            if let tail = String(bytes: utf8Buffer, encoding: .utf8) {
                onToken(tail)
            }
        }
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let byteCount = text.utf8.count
        var capacity = max(8, byteCount + 8)
        var tokens = [llama_token](repeating: 0, count: capacity)

        let count = text.withCString { cString -> Int32 in
            return llama_tokenize(
                vocab,
                cString,
                Int32(byteCount),
                &tokens,
                Int32(capacity),
                true,
                true
            )
        }

        if count == Int32.min {
            throw LlamaRuntimeError.tokenizationFailed
        }

        if count < 0 {
            let needed = Int(-count)
            capacity = needed
            tokens = [llama_token](repeating: 0, count: capacity)

            let retry = text.withCString { cString -> Int32 in
                return llama_tokenize(
                    vocab,
                    cString,
                    Int32(byteCount),
                    &tokens,
                    Int32(capacity),
                    true,
                    true
                )
            }

            if retry < 0 {
                throw LlamaRuntimeError.tokenizationFailed
            }

            return Array(tokens.prefix(Int(retry)))
        }

        return Array(tokens.prefix(Int(count)))
    }

    private static func availableMemoryBytes() -> Int {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return Int(ProcessInfo.processInfo.physicalMemory)
        #else
        return Int(os_proc_available_memory())
        #endif
    }

    /// 10% of the memory the process can still allocate before the OS kills it.
    /// Snapshots are full-KV-state copies, so this keeps them from doubling our
    /// footprint under pressure.
    private static func prefixCacheBudgetBytes() -> Int {
        let available = availableMemoryBytes()
        guard available > 0 else { return 0 }
        let fraction = Int(Double(available) * prefixCacheBudgetFraction)
        return min(prefixCacheMaxBudgetBytes, max(0, fraction))
    }

    private func cachedPrefixSnapshot(for key: String) -> PromptPrefixSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let snapshot = promptPrefixCache[key] else { return nil }
        promptPrefixCacheOrder.removeAll { $0 == key }
        promptPrefixCacheOrder.append(key)
        return snapshot
    }

    private func clearPrefixCache() {
        stateLock.lock()
        promptPrefixCache.removeAll()
        promptPrefixCacheOrder.removeAll()
        promptPrefixCacheBytes = 0
        stateLock.unlock()
    }

    private func trimPrefixCache(toBytes target: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        while promptPrefixCacheBytes > target, let oldest = promptPrefixCacheOrder.first {
            if let evicted = promptPrefixCache.removeValue(forKey: oldest) {
                promptPrefixCacheBytes -= evicted.stateData.count
            }
            promptPrefixCacheOrder.removeFirst()
        }
    }

    private func cachePromptPrefix(_ key: String, ctx: OpaquePointer, tokens: [llama_token]) {
        let stateSize = llama_state_get_size(ctx)
        guard stateSize > 0 else { return }

        let budget = Self.prefixCacheBudgetBytes()
        guard Int(stateSize) <= budget else {
            let stateMB = Double(stateSize) / 1_048_576.0
            let budgetMB = Double(budget) / 1_048_576.0
            print("[Llama] Prefix KV snapshot \(String(format: "%.1f", stateMB)) MB exceeds cache budget \(String(format: "%.1f", budgetMB)) MB; skipping cache.")
            return
        }

        // Allocate the snapshot buffer directly and let llama write into it,
        // avoiding a second full-size copy.
        var stateData = Data(count: Int(stateSize))
        let copied = stateData.withUnsafeMutableBytes { buffer -> size_t in
            guard let base = buffer.baseAddress else { return 0 }
            return llama_state_get_data(ctx, base.assumingMemoryBound(to: UInt8.self), stateSize)
        }
        guard copied > 0 else { return }
        if copied < stateData.count {
            stateData.removeSubrange(Int(copied)..<stateData.count)
        }

        let snapshot = PromptPrefixSnapshot(
            stateData: stateData,
            tokenCount: tokenCount,
            tokens: tokens
        )

        stateLock.lock()

        if let existing = promptPrefixCache.removeValue(forKey: key) {
            promptPrefixCacheBytes -= existing.stateData.count
        }
        promptPrefixCache[key] = snapshot
        promptPrefixCacheBytes += snapshot.stateData.count
        promptPrefixCacheOrder.removeAll { $0 == key }
        promptPrefixCacheOrder.append(key)

        while (promptPrefixCacheBytes > budget || promptPrefixCacheOrder.count > Self.prefixCacheHardEntryLimit),
              let oldest = promptPrefixCacheOrder.first {
            if let evicted = promptPrefixCache.removeValue(forKey: oldest) {
                promptPrefixCacheBytes -= evicted.stateData.count
            }
            promptPrefixCacheOrder.removeFirst()
        }

        let totalBytes = promptPrefixCacheBytes
        stateLock.unlock()

        if UserDefaults.standard.bool(forKey: "debug.promptTrace") {
            let snapshotMB = Double(snapshot.stateData.count) / 1_048_576.0
            let totalMB = Double(totalBytes) / 1_048_576.0
            let budgetMB = Double(budget) / 1_048_576.0
            print("[Llama] Cached prefix KV snapshot \(String(format: "%.1f", snapshotMB)) MB; cache \(String(format: "%.1f", totalMB)) MB / budget \(String(format: "%.1f", budgetMB)) MB")
        }
    }

    private func restorePromptSnapshot(_ snapshot: PromptPrefixSnapshot, into ctx: inout OpaquePointer) throws -> Bool {
        guard !snapshot.stateData.isEmpty else { return false }
        let restored = snapshot.stateData.withUnsafeBytes { raw -> size_t in
            guard let base = raw.baseAddress else { return 0 }
            return llama_state_set_data(ctx, base.assumingMemoryBound(to: UInt8.self), snapshot.stateData.count)
        }
        return restored > 0
    }

    private func tokenToPieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8]? {
        var buffer = [Int8](repeating: 0, count: 4096)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length <= 0 { return nil }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

    private func buildSamplerChain(
        sampling: SamplingConfig
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true

        guard let chain = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.contextInitFailed
        }

        let repeatLastN = max(0, sampling.repeatLastN)
        let penaltyRepeat = max(1.0, sampling.repetitionPenalty)
        let penaltyFreq: Float = penaltyRepeat > 1.03 ? 0.04 : 0.0
        let penaltyPresent: Float = penaltyRepeat > 1.03 ? 0.02 : 0.0

        let nVocab = vocab.map { llama_vocab_n_tokens($0) } ?? 0
        if nVocab > 0, let penalties = llama_sampler_init_penalties(
            nVocab,
            repeatLastN == 0 ? -1 : Int32(repeatLastN),
            penaltyRepeat,
            penaltyFreq,
            penaltyPresent
        ) {
            llama_sampler_chain_add(chain, penalties)
        }

        if let sampler = llama_sampler_init_top_k(Int32(max(1, sampling.topK))) {
            llama_sampler_chain_add(chain, sampler)
        }

        if let sampler = llama_sampler_init_top_p(max(0.05, min(1.0, sampling.topP)), 1) {
            llama_sampler_chain_add(chain, sampler)
        }

        if let sampler = llama_sampler_init_temp(max(0.0, sampling.temperature)) {
            llama_sampler_chain_add(chain, sampler)
        }

        let seed = UInt32.random(in: UInt32.min...UInt32.max)
        if let sampler = llama_sampler_init_dist(seed) {
            llama_sampler_chain_add(chain, sampler)
        }

        return chain
    }
    
    private func utf8DecodableCutoffIndex(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var i = bytes.count - 1
        // Find start byte of the last codepoint
        while i >= 0, (bytes[i] & 0xC0) == 0x80 { // continuation byte 10xxxxxx
            i -= 1
        }
        if i < 0 {
            // No start byte in buffer (shouldn't happen in normal flow); emit nothing
            return 0
        }
        let start = bytes[i]
        var expectedLen = 1
        if (start & 0x80) == 0 { // 0xxxxxxx
            expectedLen = 1
        } else if (start & 0xE0) == 0xC0 { // 110xxxxx
            expectedLen = 2
        } else if (start & 0xF0) == 0xE0 { // 1110xxxx
            expectedLen = 3
        } else if (start & 0xF8) == 0xF0 { // 11110xxx
            expectedLen = 4
        } else {
            // Invalid start byte; emit everything before it
            return i
        }
        let available = bytes.count - i
        if available < expectedLen {
            // Incomplete trailing sequence; emit up to the start of it
            return i
        }
        // Full buffer decodable
        return bytes.count
    }

}

private extension LlamaRuntime {
    func sampleToken(
        logits: UnsafePointer<Float>,
        nVocab: Int,
        sampling: SamplingConfig,
        recentTokenCounts: [Int: Int]
    ) -> llama_token {
        let k = max(1, min(sampling.topK, nVocab))
        if samplingTopIndices.count < k {
            samplingTopIndices = [Int](repeating: 0, count: k)
        }
        if samplingTopLogits.count < k {
            samplingTopLogits = [Float](repeating: 0, count: k)
        }

        let temp = max(0.01, sampling.temperature)
        let invTemp: Float = 1 / temp
        let penalty = sampling.repetitionPenalty
        let usePenalty = penalty > 1.0 && sampling.repeatLastN > 0 && !recentTokenCounts.isEmpty
        var selected = 0
        var minPos = 0
        var minLogit = Float.greatestFiniteMagnitude

        for i in 0..<nVocab {
            var v = logits[i]
            if usePenalty, let repeatCount = recentTokenCounts[i], repeatCount > 0 {
                let scale = powf(penalty, Float(repeatCount))
                v = v < 0 ? v * scale : v / scale
            }
            v *= invTemp

            if selected < k {
                samplingTopIndices[selected] = i
                samplingTopLogits[selected] = v
                if v < minLogit {
                    minLogit = v
                    minPos = selected
                }
                selected += 1
                continue
            }

            if v > minLogit {
                samplingTopIndices[minPos] = i
                samplingTopLogits[minPos] = v

                minPos = 0
                minLogit = samplingTopLogits[0]
                for j in 1..<k {
                    let candidate = samplingTopLogits[j]
                    if candidate < minLogit {
                        minLogit = candidate
                        minPos = j
                    }
                }
            }
        }

        guard selected > 0 else {
            return llama_token(0)
        }

        var maxLogit = -Float.greatestFiniteMagnitude
        for i in 0..<selected {
            let v = samplingTopLogits[i]
            if v > maxLogit {
                maxLogit = v
            }
        }

        if samplingProbs.count < selected {
            samplingProbs = [Float](repeating: 0, count: selected)
        }
        var sum: Float = 0
        for i in 0..<selected {
            let p = expf(samplingTopLogits[i] - maxLogit)
            samplingProbs[i] = p
            sum += p
        }
        if sum <= 0 {
            return llama_token(samplingTopIndices[0])
        }

        // Normalize probabilities for sampling.
        let invSum: Float = 1 / sum
        for i in 0..<selected {
            samplingProbs[i] *= invSum
        }

        let topP = max(0.05, min(1.0, sampling.topP))
        if topP < 0.999, selected > 1 {
            if samplingOrder.count < selected {
                samplingOrder = Array(0..<selected)
            } else {
                for i in 0..<selected { samplingOrder[i] = i }
            }
            samplingOrder[0..<selected].sort { samplingProbs[$0] > samplingProbs[$1] }

            var cutoffCount = 0
            var cum: Float = 0
            for i in 0..<selected {
                cum += samplingProbs[samplingOrder[i]]
                cutoffCount += 1
                if cum >= topP { break }
            }
            cutoffCount = max(1, min(selected, cutoffCount))

            let r = Float.random(in: 0..<1)
            var acc: Float = 0
            let renorm = max(1e-9, samplingOrder.prefix(cutoffCount).reduce(0 as Float) { $0 + samplingProbs[$1] })
            let invRenorm: Float = 1 / renorm
            for i in 0..<cutoffCount {
                let j = samplingOrder[i]
                acc += samplingProbs[j] * invRenorm
                if r <= acc {
                    return llama_token(samplingTopIndices[j])
                }
            }
            return llama_token(samplingTopIndices[samplingOrder[0]])
        } else {
            let r = Float.random(in: 0..<1)
            var acc: Float = 0
            for i in 0..<selected {
                acc += samplingProbs[i]
                if r <= acc {
                    return llama_token(samplingTopIndices[i])
                }
            }
            return llama_token(samplingTopIndices[0])
        }
    }
}

private extension LlamaRuntime {
    func projectFieldVector(_ field: [Double], targetCount: Int) -> [Float] {
        TurboQuantCodec.compressedVector(for: field, targetCount: targetCount)
    }
}
