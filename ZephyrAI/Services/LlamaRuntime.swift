import Foundation
import Darwin

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

struct SamplingConfig {
    let temperature: Float
    let topK: Int
    let repetitionPenalty: Float
    let repeatLastN: Int

    static let `default` = SamplingConfig(
        temperature: 0.7,
        topK: 40,
        repetitionPenalty: 1.1,
        repeatLastN: 64
    )
}

final class LlamaRuntime {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var tokenCount: Int32 = 0

    var contextSize: Int32
    private let batchSize: Int32
    private static let silenceLogs: ggml_log_callback = { _, _, _ in }

    init(modelPath: String, contextSize: Int32) throws {
        self.contextSize = max(1, contextSize)

        llama_log_set(LlamaRuntime.silenceLogs, nil)
        print("[Llama] Initializing backend")
        llama_backend_init()
        if let info = llama_print_system_info() {
            print("[Llama] System info: \(String(cString: info))")
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 0

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

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, self.contextSize))
        ctxParams.n_batch = UInt32(min(256, Int(self.contextSize)))

        print("[Llama] Creating context (n_ctx=\(ctxParams.n_ctx), n_batch=\(ctxParams.n_batch))")
        guard let ctx = llama_init_from_model(model, ctxParams) else {
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

        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        print("[Llama] Using threads: \(threads)")
        llama_set_n_threads(ctx, Int32(threads), Int32(threads))
    }

    deinit {
        if let ctx = context {
            llama_free(ctx)
        }
        if let model = model {
            llama_model_free(model)
        }
        llama_backend_free()
    }

    private func rebuildContext() throws {
        guard let model = self.model else {
            throw LlamaRuntimeError.contextInitFailed
        }
        if let ctx = context {
            llama_free(ctx)
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, self.contextSize))
        ctxParams.n_batch = UInt32(max(1, Int(self.batchSize)))

        guard let newCtx = llama_init_from_model(model, ctxParams) else {
            throw LlamaRuntimeError.contextInitFailed
        }

        self.context = newCtx
        self.tokenCount = 0

        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        llama_set_n_threads(newCtx, Int32(threads), Int32(threads))
    }

    func generateStream(
        prompt: String,
        maxTokens: Int,
        kvInjection: KVInjection? = nil,
        sampling: SamplingConfig = .default,
        shouldStop: () -> Bool,
        onToken: (String) -> Void
    ) throws {
        guard var ctx = context, let vocab = vocab else {
            throw LlamaRuntimeError.contextInitFailed
        }

        if shouldStop() { return }

        // We re-decode the full prompt each request; keep KV cache clean.
        if tokenCount > 0 {
            try rebuildContext()
            guard let refreshed = context else {
                throw LlamaRuntimeError.contextInitFailed
            }
            ctx = refreshed
        }

        print("[Llama] Tokenizing prompt (len=\(prompt.count))")
        let promptTokens = try tokenize(prompt, vocab: vocab)
        let maxPromptTokens = max(1, Int(contextSize) - 256)
        let tokensForDecode: [llama_token]
        if promptTokens.count > maxPromptTokens {
            print("[Llama] Prompt too long (\(promptTokens.count) tokens). Trimming to \(maxPromptTokens).")
            tokensForDecode = Array(promptTokens.suffix(maxPromptTokens))
            tokenCount = 0
        } else {
            tokensForDecode = promptTokens
        }
        // Sync tokenCount after (re)building prompt tokens
        tokenCount = Int32(tokensForDecode.count)

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
        while index < tokensForDecode.count {
            if shouldStop() { return }
            let end = min(tokensForDecode.count, index + Int(batchSize))
            let slice = Array(tokensForDecode[index..<end])
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

        var recentTokens: [llama_token] = []

        for _ in 0..<generationLimit {
            if shouldStop() { return }
            guard let logits = llama_get_logits_ith(ctx, -1) else { break }
            let nVocab = Int(llama_vocab_n_tokens(vocab))

            let token: llama_token
            if sampling.temperature <= 0 {
                var bestToken = 0
                var bestLogit = -Float.greatestFiniteMagnitude
                for i in 0..<nVocab {
                    let v = logits[i]
                    if v > bestLogit {
                        bestLogit = v
                        bestToken = i
                    }
                }
                token = llama_token(bestToken)
            } else {
                token = sampleToken(
                    logits: logits,
                    nVocab: nVocab,
                    sampling: sampling,
                    recentTokens: recentTokens
                )
            }
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

            recentTokens.append(token)
            if recentTokens.count > sampling.repeatLastN, sampling.repeatLastN > 0 {
                recentTokens.removeFirst(recentTokens.count - sampling.repeatLastN)
            }

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

    private func tokenToPieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8]? {
        var buffer = [Int8](repeating: 0, count: 4096)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length <= 0 { return nil }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
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
        recentTokens: [llama_token]
    ) -> llama_token {
        var local = [Float](repeating: 0, count: nVocab)
        for i in 0..<nVocab {
            local[i] = logits[i]
        }

        if sampling.repetitionPenalty > 1.0, sampling.repeatLastN > 0, !recentTokens.isEmpty {
            let penalty = sampling.repetitionPenalty
            for token in recentTokens.suffix(sampling.repeatLastN) {
                let idx = Int(token)
                guard idx >= 0 && idx < nVocab else { continue }
                let v = local[idx]
                local[idx] = v < 0 ? v * penalty : v / penalty
            }
        }

        let temp = max(0.01, sampling.temperature)
        for i in 0..<nVocab {
            local[i] /= temp
        }

        let k = max(1, min(sampling.topK, nVocab))
        let pool = selectTopK(from: local, k: k)
        guard !pool.isEmpty else {
            return llama_token(0)
        }

        var maxLogit = -Float.greatestFiniteMagnitude
        for item in pool {
            if item.logit > maxLogit { maxLogit = item.logit }
        }

        var probs: [Float] = []
        probs.reserveCapacity(pool.count)
        var sum: Float = 0
        for item in pool {
            let p = expf(item.logit - maxLogit)
            probs.append(p)
            sum += p
        }
        if sum <= 0 {
            return llama_token(pool[0].index)
        }

        for i in 0..<probs.count {
            probs[i] /= sum
        }

        let r = Float.random(in: 0..<1)
        var acc: Float = 0
        for i in 0..<pool.count {
            acc += probs[i]
            if r <= acc {
                return llama_token(pool[i].index)
            }
        }

        return llama_token(pool.first?.index ?? 0)
    }

    func selectTopK(from logits: [Float], k: Int) -> [(index: Int, logit: Float)] {
        guard k > 0 else { return [] }
        var indices: [Int] = []
        var values: [Float] = []
        indices.reserveCapacity(k)
        values.reserveCapacity(k)

        for i in 0..<logits.count {
            let v = logits[i]
            if indices.count < k {
                indices.append(i)
                values.append(v)
                continue
            }

            var minIdx = 0
            var minVal = values[0]
            for j in 1..<values.count {
                if values[j] < minVal {
                    minVal = values[j]
                    minIdx = j
                }
            }

            if v > minVal {
                indices[minIdx] = i
                values[minIdx] = v
            }
        }

        var out: [(index: Int, logit: Float)] = []
        out.reserveCapacity(indices.count)
        for i in 0..<indices.count {
            out.append((index: indices[i], logit: values[i]))
        }
        return out
    }
}

private extension LlamaRuntime {
    func projectFieldVector(_ field: [Double], targetCount: Int) -> [Float] {
        guard !field.isEmpty else { return [] }
        let target = max(1, targetCount)
        if field.count == target {
            return field.map { Float($0) }
        }
        var out: [Float] = []
        out.reserveCapacity(target)
        let chunkSize = Double(field.count) / Double(target)
        for i in 0..<target {
            let start = Int(Double(i) * chunkSize)
            let end = min(field.count, Int(Double(i + 1) * chunkSize))
            if start >= end {
                out.append(0)
                continue
            }
            let slice = field[start..<end]
            let avg = slice.reduce(0.0, +) / Double(slice.count)
            out.append(Float(avg))
        }
        return out
    }
}
