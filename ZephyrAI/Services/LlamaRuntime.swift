import Foundation

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

final class LlamaRuntime {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var tokenCount: Int32 = 0

    private let contextSize: Int32
    private let batchSize: Int32
    private static let silenceLogs: ggml_log_callback = { _, _, _ in }

    init(modelPath: String, contextSize: Int32) throws {
        self.contextSize = contextSize

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

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(1, contextSize))
        ctxParams.n_batch = UInt32(min(1024, Int(contextSize)))

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

    func generateStream(prompt: String, maxTokens: Int, onToken: (String) -> Void) throws {
        guard var ctx = context, let vocab = vocab else {
            throw LlamaRuntimeError.contextInitFailed
        }

        // Reset KV cache if context is near limit (prevents decode crashes)
        if tokenCount > contextSize - 256 {
            print("[Llama] Resetting context (KV cache full via context reset)")
            // Hard reset: recreate context (compatible with older llama.cpp)
            if let model = self.model {
                llama_free(ctx)

                var ctxParams = llama_context_default_params()
                ctxParams.n_ctx = UInt32(max(1, contextSize))
                ctxParams.n_batch = UInt32(min(1024, Int(contextSize)))

                guard let newCtx = llama_init_from_model(model, ctxParams) else {
                    throw LlamaRuntimeError.contextInitFailed
                }

                self.context = newCtx
                ctx = newCtx   // IMPORTANT: update local ctx reference

                let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
                llama_set_n_threads(newCtx, Int32(threads), Int32(threads))
            }

            tokenCount = 0
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

        var index = 0
        while index < tokensForDecode.count {
            let end = min(tokensForDecode.count, index + Int(batchSize))
            var slice = Array(tokensForDecode[index..<end])
            let promptResult = slice.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
                let r = llama_decode(ctx, batch)
                if r == 0 {
                    tokenCount += Int32(buffer.count)
                }
                return r
            }

            if promptResult != 0 {
                throw LlamaRuntimeError.decodeFailed(code: promptResult)
            }

            index = end
        }

        var utf8Buffer: [UInt8] = []
        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { break }
            let nVocab = Int(llama_vocab_n_tokens(vocab))

            var bestToken = 0
            var bestLogit = -Float.greatestFiniteMagnitude
            for i in 0..<nVocab {
                let v = logits[i]
                if v > bestLogit {
                    bestLogit = v
                    bestToken = i
                }
            }

            let token = llama_token(bestToken)
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
