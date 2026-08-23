import Foundation
import AVFoundation

#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#elseif canImport(onnxruntime_objc)
import onnxruntime_objc
#endif

#if canImport(FluidAudio)
import FluidAudio
#endif

#if canImport(KokoroTTS)
import KokoroTTS
#endif

#if canImport(AudioCommon)
import AudioCommon
#endif

final class SpeechService {
    static let shared = SpeechService()
    
    enum VoiceKind {
        case female
        case male
    }

    // onnx-community/Kokoro-82M-v1.0-ONNX is English-only in this integration.
    private let kokoroOnnxDefaultSpeed: Float = 0.72

    private struct SpeechRoute {
        let useLocal: Bool
        let localVoice: String
        let systemLocale: String?
        let languageCode: String
    }
    
    private let synthesizer = AVSpeechSynthesizer()
    private var activeTask: Task<Void, Never>?
    private var activePlayer: AVAudioPlayer?
    private var activeSpeechID = UUID()
    private let userDefaults = UserDefaults.standard

    private enum StorageKey {
        static let useLocalTTS = "tts.useLocal"
        static let kokoroVoiceFemale = "tts.kokoro.voice.female"
        static let kokoroVoiceMale = "tts.kokoro.voice.male"
        static let kokoroModelPath = "tts.kokoro.model.path"
        static let onnxModelPath = "tts.onnx.model.path"
        static let onnxTokenizerPath = "tts.onnx.tokenizer.path"
        static let onnxConfigPath = "tts.onnx.config.path"
        static let onnxVoicesDirPath = "tts.onnx.voices.dir.path"
    }

    private let kokoroModelFilename = "Kokoro_espeak.gguf"
    private let onnxModelFilename = "model_q8f16.onnx"
    private let onnxTokenizerFilename = "tokenizer.json"
    private let onnxConfigFilename = "config.json"
    private let onnxVoicesDirectoryName = "voices"

    #if canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
    private struct OnnxTokenizer {
        let vocab: [String: Int64]
        let bosTokenID: Int64
        let normalizerRegex: NSRegularExpression?
        let normalizerReplacement: String
    }

    private let onnxQueue = DispatchQueue(label: "SpeechService.ONNX")
    private var onnxEnv: ORTEnv?
    private var onnxSession: ORTSession?
    private var onnxSessionModelPath: String?
    private var onnxTokenizerCache: OnnxTokenizer?
    private var onnxTokenizerPath: String?
    #endif
    
    private init() {
        #if canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
        cacheOnnxResourcePathsIfAvailable()
        logOnnxPreflight()
        #endif
    }
    
    func speak(text: String, voice: VoiceKind) {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return }
        let route = makeSpeechRoute(for: sanitized, requestedVoice: voice)

        prepareAudioSession()
        print("SpeechService speak requested: chars=\(sanitized.count), local=\(shouldUseLocalTTS), routeLocal=\(route.useLocal), lang=\(route.languageCode), voice=\(route.localVoice)")

        if shouldUseLocalTTS && route.useLocal {
            speakLocally(text: sanitized, route: route)
        } else {
            print("SpeechService using system AVSpeechSynthesizer backend")
            speakWithSystemTTS(text: sanitized, voice: voice, localeHint: route.systemLocale)
        }
    }

    func stop() {
        activeSpeechID = UUID()
        activeTask?.cancel()
        activeTask = nil
        activePlayer?.stop()
        activePlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private var shouldUseLocalTTS: Bool {
        // Always try local first; fallback to system TTS is already handled in speakLocally on any error.
        if localTTSIsAvailable { return true }
        return true
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            print("SpeechService audio session error: \(error)")
        }
    }

    private func speakWithSystemTTS(text: String, voice: VoiceKind, localeHint: String? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = pickVoice(kind: voice, localeHint: localeHint)

        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    private func speakLocally(text: String, route: SpeechRoute) {
        let speechID = UUID()
        activeSpeechID = speechID
        activeTask?.cancel()
        activePlayer?.stop()
        activePlayer = nil

        activeTask = Task { [weak self] in
            guard let self else { return }

            do {
                let audioData = try await self.generateLocalAudio(text: text, route: route)
                try Task.checkCancellation()

                await MainActor.run {
                    do {
                        let player = try AVAudioPlayer(data: audioData)
                        player.prepareToPlay()
                        player.play()
                        self.activePlayer = player
                    } catch {
                        print("SpeechService playback error: \(error)")
                        self.activePlayer = nil
                    }
                }

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    let isPlaying = await MainActor.run { self.activePlayer?.isPlaying ?? false }
                    if !isPlaying { break }
                }
                await MainActor.run {
                    if self.activeSpeechID == speechID {
                        self.activePlayer = nil
                    }
                }
            } catch is CancellationError {
                // Intentionally ignore cancellations from a new speak()/stop() call.
            } catch {
                print("SpeechService local TTS error: \(error)")
                await MainActor.run {
                    if self.activeSpeechID == speechID {
                        self.activePlayer = nil
                    }
                }
                let fallbackVoice: VoiceKind = route.localVoice.hasPrefix("m") ? .male : .female
                self.speakWithSystemTTS(text: text, voice: fallbackVoice, localeHint: route.systemLocale)
            }

            await MainActor.run {
                if self.activeSpeechID == speechID {
                    self.activeTask = nil
                }
            }
        }
    }

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pickVoice(kind: VoiceKind, localeHint: String?) -> AVSpeechSynthesisVoice? {
        let preferred = localeHint ?? Locale.preferredLanguages.first ?? "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language == preferred }
        let prefix = voices.filter { $0.language.hasPrefix(String(preferred.prefix(2))) }
        let pool = !exact.isEmpty ? exact : (!prefix.isEmpty ? prefix : voices)
        
        if pool.isEmpty {
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        
        switch kind {
        case .female:
            return pool.first
        case .male:
            return pool.dropFirst().first ?? pool.first
        }
    }

    private var localTTSIsAvailable: Bool {
        #if canImport(FluidAudioTTS) || canImport(KokoroTTS) || canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
        return true
        #else
        return false
        #endif
    }

    private func generateLocalAudio(text: String, route: SpeechRoute) async throws -> Data {
        cacheOnnxResourcePathsIfAvailable()

        #if canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
        if let onnxAudio = try generateOnnxAudioIfAvailable(text: text, route: route) {
            return onnxAudio
        }
        #endif

        if let modelURL = resolveKokoroModelURL() {
            userDefaults.set(modelURL.path, forKey: StorageKey.kokoroModelPath)
            print("SpeechService using local Kokoro model: \(modelURL.path)")
        } else {
            print("SpeechService local Kokoro model not found: \(kokoroModelFilename)")
        }

        if userDefaults.string(forKey: StorageKey.onnxModelPath) != nil {
            print("SpeechService ONNX resources detected (model/tokenizer/config/voices).")
            #if canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
            print("SpeechService ONNX Runtime is linked. ONNX backend is active.")
            #else
            print("SpeechService ONNX Runtime is not linked yet; using existing local backend/fallback.")
            #endif
        }

        #if canImport(FluidAudioTTS)
        // FluidAudioTTS exposes the Kokoro model as a simple async synthesis API.
        print("SpeechService backend: FluidAudioTTS")
        return try await KokoroModel.synthesize(text: text)
        #elseif canImport(KokoroTTS)
        // Legacy KokoroTTS-style API used by some integrations.
        print("SpeechService backend: KokoroTTS")
        let model = try KokoroTTSModel.fromPretrained()
        let audio = try await model.synthesize(text: text, voice: route.localVoice)
        guard let wavData = audio.wavData() else {
            throw NSError(domain: "SpeechService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kokoro returned no WAV data"])
        }
        return wavData
        #else
        throw NSError(domain: "SpeechService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local TTS is not available"])
        #endif
    }

    private func resolveKokoroModelURL() -> URL? {
        let name = (kokoroModelFilename as NSString).deletingPathExtension
        let ext = (kokoroModelFilename as NSString).pathExtension

        let fm = FileManager.default
        var candidates: [URL] = []

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let valisDir = appSupport.appendingPathComponent("VALIS", isDirectory: true)
            candidates.append(valisDir.appendingPathComponent(kokoroModelFilename))
        }

        if let bundleModelsURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models") {
            candidates.append(bundleModelsURL)
        }
        if let bundleRootURL = Bundle.main.url(forResource: name, withExtension: ext) {
            candidates.append(bundleRootURL)
        }

        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent(kokoroModelFilename))
        }

        return candidates.first(where: { fm.fileExists(atPath: $0.path) })
    }

    private func cacheOnnxResourcePathsIfAvailable() {
        guard let bundleRoot = Bundle.main.resourceURL else { return }
        let fm = FileManager.default

        let candidateRoots: [URL] = [
            bundleRoot.appendingPathComponent("Models", isDirectory: true),
            bundleRoot
        ]

        for root in candidateRoots {
            let onnxModelURL = root.appendingPathComponent(onnxModelFilename)
            let tokenizerURL = root.appendingPathComponent(onnxTokenizerFilename)
            let configURL = root.appendingPathComponent(onnxConfigFilename)

            guard fm.fileExists(atPath: onnxModelURL.path),
                  fm.fileExists(atPath: tokenizerURL.path),
                  fm.fileExists(atPath: configURL.path) else {
                continue
            }

            let nestedVoicesDirURL = root.appendingPathComponent(onnxVoicesDirectoryName, isDirectory: true)
            let flattenedVoiceExists = fm.fileExists(atPath: root.appendingPathComponent("af_heart.bin").path)
            let voicesDirectoryURL: URL

            if fm.fileExists(atPath: nestedVoicesDirURL.path) {
                voicesDirectoryURL = nestedVoicesDirURL
            } else if flattenedVoiceExists {
                // Xcode Copy Bundle Resources often flattens `voices/*.bin` into bundle root.
                voicesDirectoryURL = root
            } else {
                continue
            }

            userDefaults.set(onnxModelURL.path, forKey: StorageKey.onnxModelPath)
            userDefaults.set(tokenizerURL.path, forKey: StorageKey.onnxTokenizerPath)
            userDefaults.set(configURL.path, forKey: StorageKey.onnxConfigPath)
            userDefaults.set(voicesDirectoryURL.path, forKey: StorageKey.onnxVoicesDirPath)
            print("SpeechService ONNX resources cached from: \(root.path)")
            return
        }

        print("SpeechService ONNX resources not found in bundle root or Models/")
    }

    private func logOnnxPreflight() {
        let model = userDefaults.string(forKey: StorageKey.onnxModelPath) ?? "<nil>"
        let tokenizer = userDefaults.string(forKey: StorageKey.onnxTokenizerPath) ?? "<nil>"
        let voices = userDefaults.string(forKey: StorageKey.onnxVoicesDirPath) ?? "<nil>"
        let fm = FileManager.default
        let modelExists = model != "<nil>" && fm.fileExists(atPath: model)
        let tokenizerExists = tokenizer != "<nil>" && fm.fileExists(atPath: tokenizer)
        let voicesExists = voices != "<nil>" && fm.fileExists(atPath: voices)
        print("SpeechService ONNX preflight: model=\(modelExists), tokenizer=\(tokenizerExists), voices=\(voicesExists)")
    }

    #if canImport(OnnxRuntimeBindings) || canImport(onnxruntime_objc)
    private struct OnnxPaths {
        let modelPath: String
        let tokenizerPath: String
        let voicesDirectoryPath: String
    }

    private func generateOnnxAudioIfAvailable(text: String, route: SpeechRoute) throws -> Data? {
        guard let paths = resolvedOnnxPaths() else {
            print("SpeechService ONNX skipped: unresolved model/tokenizer/voices paths")
            return nil
        }

        let voiceName = route.localVoice
        let preparedText = route.languageCode == "en" ? prepareEnglishTextForKokoro(text) : text
        let tokens: [Int64]
        do {
            tokens = try tokenizeWithOnnxTokenizer(preparedText, tokenizerPath: paths.tokenizerPath)
        } catch {
            print("SpeechService tokenizer.json parse error: \(error). Falling back to scalar tokenizer.")
            tokens = tokenizeForOnnx(text: preparedText)
        }
        guard !tokens.isEmpty else { return nil }
        let style = try loadOnnxVoiceEmbedding(
            named: voiceName,
            voicesDirectoryPath: paths.voicesDirectoryPath,
            tokenCount: tokens.count
        )

        print("SpeechService ONNX synth start: voice=\(voiceName), tokens=\(tokens.count)")
        let pcmData = try runONNX(tokens: tokens, style: style, modelPath: paths.modelPath)
        print("SpeechService ONNX synth done: pcmBytes=\(pcmData.count)")
        return try makeWavFromFloatPCM(pcmData: pcmData, sampleRate: 24_000)
    }

    private func prepareEnglishTextForKokoro(_ text: String) -> String {
        var t = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "…", with: ". ")
            .lowercased()

        let replacements: [(String, String)] = [
            ("can't", "can not"),
            ("won't", "will not"),
            ("n't", " not"),
            ("i'm", "i am"),
            ("you're", "you are"),
            ("we're", "we are"),
            ("they're", "they are"),
            ("it's", "it is"),
            ("that's", "that is"),
            ("what's", "what is"),
            ("there's", "there is"),
            ("gonna", "going to"),
            ("wanna", "want to")
        ]
        for (from, to) in replacements {
            t = t.replacingOccurrences(of: from, with: to)
        }

        // Expand standalone integers to words for cleaner pronunciation.
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\b") {
            let matches = regex.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed()
            let formatter = NumberFormatter()
            formatter.numberStyle = .spellOut
            formatter.locale = Locale(identifier: "en-US")
            for m in matches {
                guard let r = Range(m.range, in: t) else { continue }
                let token = String(t[r])
                if let n = Int(token), let spoken = formatter.string(from: NSNumber(value: n)) {
                    t.replaceSubrange(r, with: spoken)
                }
            }
        }

        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedOnnxPaths() -> OnnxPaths? {
        guard let modelPath = userDefaults.string(forKey: StorageKey.onnxModelPath),
              let tokenizerPath = userDefaults.string(forKey: StorageKey.onnxTokenizerPath),
              let voicesDirectoryPath = userDefaults.string(forKey: StorageKey.onnxVoicesDirPath) else {
            return nil
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath),
              fm.fileExists(atPath: tokenizerPath),
              fm.fileExists(atPath: voicesDirectoryPath) else {
            return nil
        }

        return OnnxPaths(modelPath: modelPath, tokenizerPath: tokenizerPath, voicesDirectoryPath: voicesDirectoryPath)
    }

    private func runONNX(tokens: [Int64], style: [Float], modelPath: String) throws -> Data {
        let session = try getOrCreateOnnxSession(modelPath: modelPath)

        let inputIds = try ORTValue(
            tensorData: mutableDataFromArray(tokens),
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )

        let styleInput = try ORTValue(
            tensorData: mutableDataFromArray(style),
            elementType: .float,
            shape: [1, 256]
        )

        let speedInput = try ORTValue(
            tensorData: mutableDataFromArray([kokoroOnnxDefaultSpeed]),
            elementType: .float,
            shape: [1]
        )
        let outputNameSets: [Set<String>] = [
            ["audio"],
            ["waveform"],
            ["output"],
            ["audio", "waveform", "output"]
        ]

        // First attempt with speed (most Kokoro ONNX variants accept it).
        if let data = try runONNXWithOutputFallbacks(
            session: session,
            inputs: ["input_ids": inputIds, "style": styleInput, "speed": speedInput],
            outputNameSets: outputNameSets
        ) {
            return data
        }

        // Fallback for variants without speed input.
        if let data = try runONNXWithOutputFallbacks(
            session: session,
            inputs: ["input_ids": inputIds, "style": styleInput],
            outputNameSets: outputNameSets
        ) {
            return data
        }

        throw NSError(domain: "SpeechService", code: 10, userInfo: [NSLocalizedDescriptionKey: "ONNX produced no audio output tensor"])
    }

    private func runONNXWithOutputFallbacks(
        session: ORTSession,
        inputs: [String: ORTValue],
        outputNameSets: [Set<String>]
    ) throws -> Data? {
        for names in outputNameSets {
            guard let outputs = try? session.run(withInputs: inputs, outputNames: names, runOptions: nil) else {
                continue
            }

            let preferred = ["audio", "waveform", "output"]
            let selectedName = preferred.first(where: { outputs[$0] != nil }) ?? outputs.keys.first
            guard let name = selectedName, let tensor = outputs[name] else { continue }

            let tensorData = try tensor.tensorData()
            if let info = try? tensor.tensorTypeAndShapeInfo() {
                print("SpeechService ONNX output: name=\(name), shape=\(info.shape), type=\(info.elementType), bytes=\(tensorData.count)")
            } else {
                print("SpeechService ONNX output: name=\(name), bytes=\(tensorData.count)")
            }

            guard !tensorData.isEmpty else { continue }
            return Data(tensorData)
        }
        return nil
    }

    private func getOrCreateOnnxSession(modelPath: String) throws -> ORTSession {
        try onnxQueue.sync {
            if let existing = onnxSession, onnxSessionModelPath == modelPath {
                return existing
            }

            if onnxEnv == nil {
                onnxEnv = try ORTEnv(loggingLevel: .warning)
            }
            guard let env = onnxEnv else {
                throw NSError(
                    domain: "SpeechService",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to initialize ONNX runtime environment"]
                )
            }

            let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
            onnxSession = session
            onnxSessionModelPath = modelPath
            return session
        }
    }

    private func tokenizeForOnnx(text: String) -> [Int64] {
        // Fallback only; production path uses tokenizer.json.
        text.unicodeScalars.map { Int64($0.value) }
    }

    private func loadOnnxVoiceEmbedding(named voiceName: String, voicesDirectoryPath: String, tokenCount: Int) throws -> [Float] {
        let fm = FileManager.default
        let primaryURL = URL(fileURLWithPath: voicesDirectoryPath).appendingPathComponent("\(voiceName).bin")
        let fallbackURL = URL(fileURLWithPath: voicesDirectoryPath).appendingPathComponent("af_bella.bin")
        let voiceURL = fm.fileExists(atPath: primaryURL.path) ? primaryURL : fallbackURL

        let data = try Data(contentsOf: voiceURL)
        let floatStride = MemoryLayout<Float>.stride
        guard data.count >= 256 * floatStride else {
            throw NSError(
                domain: "SpeechService",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Voice embedding is too small: \(voiceURL.lastPathComponent)"]
            )
        }

        let floats: [Float] = data.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count / floatStride
            let ptr = rawBuffer.bindMemory(to: Float.self)
            return Array(ptr.prefix(count))
        }
        // Kokoro voice bins contain a style bank of shape [N, 1, 256] flattened to N*256.
        // The reference pipeline uses the number of content tokens before adding BOS/EOS.
        let rows = max(1, floats.count / 256)
        let rowIndex = Self.kokoroStyleRowIndex(tokenCount: tokenCount, rowCount: rows)
        let start = rowIndex * 256
        let end = min(start + 256, floats.count)
        if floats[start..<end].count == 256 {
            return Array(floats[start..<end])
        }

        // Fallback if unexpected voice format.
        return Array(floats.prefix(256))
    }

    static func kokoroStyleRowIndex(tokenCount: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        let payloadTokenCount = max(tokenCount - 2, 0)
        return min(payloadTokenCount, rowCount - 1)
    }

    private func tokenizeWithOnnxTokenizer(_ text: String, tokenizerPath: String) throws -> [Int64] {
        let tokenizer = try loadOnnxTokenizer(path: tokenizerPath)
        let normalized = applyTokenizerNormalizer(text, tokenizer: tokenizer)

        var tokens: [Int64] = []
        tokens.reserveCapacity(normalized.count + 2)
        tokens.append(tokenizer.bosTokenID)

        for scalar in normalized.unicodeScalars {
            let tokenKey = String(scalar)
            if let tokenID = tokenizer.vocab[tokenKey] {
                tokens.append(tokenID)
            }
        }

        // Kokoro context is 512. Reserve BOS/EOS, clamp payload to 510.
        if tokens.count > 511 {
            tokens = Array(tokens.prefix(511))
        }
        tokens.append(tokenizer.bosTokenID)
        return tokens
    }

    private func applyTokenizerNormalizer(_ text: String, tokenizer: OnnxTokenizer) -> String {
        guard let regex = tokenizer.normalizerRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: tokenizer.normalizerReplacement
        )
    }

    private func loadOnnxTokenizer(path: String) throws -> OnnxTokenizer {
        if let cached = onnxTokenizerCache, onnxTokenizerPath == path {
            return cached
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = object as? [String: Any],
              let model = root["model"] as? [String: Any],
              let rawVocab = model["vocab"] as? [String: Any] else {
            throw NSError(
                domain: "SpeechService",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "tokenizer.json has unsupported structure"]
            )
        }

        var vocab: [String: Int64] = [:]
        vocab.reserveCapacity(rawVocab.count)
        for (key, value) in rawVocab {
            if let i = value as? NSNumber {
                vocab[key] = i.int64Value
            }
        }

        guard let bosTokenID = vocab["$"] else {
            throw NSError(
                domain: "SpeechService",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "tokenizer.json missing \"$\" special token"]
            )
        }

        let normalizer = root["normalizer"] as? [String: Any]
        let patternNode = normalizer?["pattern"] as? [String: Any]
        let regexPattern = patternNode?["Regex"] as? String
        let replacement = (normalizer?["content"] as? String) ?? ""
        let compiledRegex: NSRegularExpression?
        if let regexPattern, !regexPattern.isEmpty {
            compiledRegex = try? NSRegularExpression(pattern: regexPattern, options: [])
        } else {
            compiledRegex = nil
        }

        let tokenizer = OnnxTokenizer(
            vocab: vocab,
            bosTokenID: bosTokenID,
            normalizerRegex: compiledRegex,
            normalizerReplacement: replacement
        )
        onnxTokenizerCache = tokenizer
        onnxTokenizerPath = path
        return tokenizer
    }

    private func makeWavFromFloatPCM(pcmData: Data, sampleRate: Int) throws -> Data {
        let floatStride = MemoryLayout<Float>.stride
        guard pcmData.count >= floatStride, pcmData.count % floatStride == 0 else {
            throw NSError(
                domain: "SpeechService",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected PCM size from ONNX: \(pcmData.count) bytes"]
            )
        }

        let floatSamples: [Float] = pcmData.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count / floatStride
            let ptr = rawBuffer.bindMemory(to: Float.self)
            return Array(ptr.prefix(count))
        }

        var pcm16 = Data(capacity: floatSamples.count * MemoryLayout<Int16>.stride)
        for sample in floatSamples {
            let clamped = max(-1.0, min(1.0, sample))
            let s16 = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: s16) { bytes in
                pcm16.append(contentsOf: bytes)
            }
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        let dataChunkSize = UInt32(pcm16.count)
        let riffChunkSize = 36 + dataChunkSize

        var wav = Data(capacity: Int(44 + dataChunkSize))
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(dataFromArray([riffChunkSize.littleEndian]))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(dataFromArray([UInt32(16).littleEndian]))
        wav.append(dataFromArray([UInt16(1).littleEndian]))
        wav.append(dataFromArray([channels.littleEndian]))
        wav.append(dataFromArray([UInt32(sampleRate).littleEndian]))
        wav.append(dataFromArray([byteRate.littleEndian]))
        wav.append(dataFromArray([blockAlign.littleEndian]))
        wav.append(dataFromArray([bitsPerSample.littleEndian]))
        wav.append("data".data(using: .ascii)!)
        wav.append(dataFromArray([dataChunkSize.littleEndian]))
        wav.append(pcm16)
        return wav
    }

    private func dataFromArray<T>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private func mutableDataFromArray<T>(_ values: [T]) -> NSMutableData {
        let data = dataFromArray(values)
        return NSMutableData(data: data)
    }
    #endif

    private var femaleKokoroVoice: String {
        normalizedKokoroVoice(
            storedValue: userDefaults.string(forKey: StorageKey.kokoroVoiceFemale),
            fallback: "af_bella",
            legacyFallbacks: ["af_heart"]
        )
    }

    private var maleKokoroVoice: String {
        normalizedKokoroVoice(
            storedValue: userDefaults.string(forKey: StorageKey.kokoroVoiceMale),
            fallback: "am_adam",
            legacyFallbacks: []
        )
    }

    private func normalizedKokoroVoice(storedValue: String?, fallback: String, legacyFallbacks: [String]) -> String {
        guard let storedValue, !storedValue.isEmpty else { return fallback }
        if legacyFallbacks.contains(storedValue) { return fallback }
        return storedValue
    }

    private func makeSpeechRoute(for text: String, requestedVoice: VoiceKind) -> SpeechRoute {
        let lang = LanguageRoutingService.detectedNormalizedCode(for: text) ?? "en"
        switch lang {
        case "en":
            return SpeechRoute(
                useLocal: true,
                localVoice: requestedVoice == .female ? femaleKokoroVoice : maleKokoroVoice,
                systemLocale: "en-US",
                languageCode: lang
            )
        case "ru":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "ru-RU", languageCode: lang)
        case "uk":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "uk-UA", languageCode: lang)
        case "fr":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "fr-FR", languageCode: lang)
        case "de":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "de-DE", languageCode: lang)
        case "es":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "es-ES", languageCode: lang)
        case "it":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "it-IT", languageCode: lang)
        case "pt":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "pt-BR", languageCode: lang)
        case "zh":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "zh-CN", languageCode: lang)
        case "ja":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "ja-JP", languageCode: lang)
        case "ko":
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: "ko-KR", languageCode: lang)
        default:
            return SpeechRoute(useLocal: false, localVoice: femaleKokoroVoice, systemLocale: nil, languageCode: lang)
        }
    }
}
