import SwiftUI
import AVFoundation

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var showSettings = false
    @State private var showSandwich: Bool = true
    @State private var sandwichHideTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool
    
    @State private var isRecording: Bool = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioFilename: URL?
    @State private var audioLevel: CGFloat = 0.2
    @State private var silenceTimer: TimeInterval = 0
    @State private var meterTimer: Timer?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Status
            ZStack {

                // Tap area (doesn't block buttons)
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)

                // Title center
                Text("V A L I S")
                    .font(.system(size: 16, weight: .medium))

                // Right side (status + sandwich)
                HStack(spacing: 8) {
                    Spacer()

                    Text(viewModel.status)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Button {
                        showSettings = true
                        restartSandwichTimer()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.primary)
                            .opacity(showSandwich ? 1 : 0.15)
                            .allowsHitTesting(showSandwich)
                            .scaleEffect(showSandwich ? 1 : 0.8)
                            .animation(.easeInOut(duration: 0.25), value: showSandwich)
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal)
            .onTapGesture {
                showSandwich = true
                restartSandwichTimer()
            }
            .background(Color(UIColor.systemBackground))
            
            // Message List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(
                                message: message,
                                isThinkingForMessage: viewModel.isInteracting && viewModel.currentThinkingMessageId == message.id,
                                currentThink: viewModel.currentThink
                            )
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.messages.last?.content) { oldValue, newValue in
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.currentThink) { oldValue, newValue in
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Input Area
            VStack(spacing: 0) {
                HStack(alignment: .bottom) {
                    TextField("Type a message...", text: $viewModel.inputText, axis: .vertical)
                        .focused($isInputFocused)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .disabled(viewModel.isInteracting || isRecording)
                    
                    if viewModel.inputText.isEmpty && !viewModel.isInteracting {
                        Button(action: {
                            if isRecording {
                                stopRecording()
                            } else {
                                startRecording()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.primary.opacity(0.6), lineWidth: 1)
                                    .frame(width: 34, height: 34)
                                    .scaleEffect(isRecording ? 1.0 : 0.95)
                                    .opacity(isRecording ? 0.0 : 1.0)
                                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isRecording)

                                Image(systemName: "waveform")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                    .scaleEffect(isRecording ? (0.6 + audioLevel * 1.4) : 1.0)
                                    .opacity(
                                        isRecording
                                        ? (0.4 + audioLevel * 0.8)
                                        : (sin(Date().timeIntervalSince1970 * 0.8) > 0 ? 0.7 : 0.0)
                                    )
                                    .animation(.easeInOut(duration: 0.2), value: audioLevel)
                                    .animation(.easeInOut(duration: 1.5), value: isRecording)
                            }
                            .frame(width: 34, height: 34)
                        }
                    } else {
                        Button(action: {
                            if viewModel.isInteracting {
                                viewModel.stopGeneration()
                            } else {
                                viewModel.sendMessage()
                            }
                        }) {
                            ZStack {
                                // Animated ring / background (size grows on active)
                                let isActive = viewModel.isInteracting || !viewModel.inputText.isEmpty
                                Circle()
                                    .fill(
                                        isActive
                                        ? Color.primary.opacity(viewModel.isInteracting ? 0.15 : 0.08)
                                        : Color.clear
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                Color.primary,
                                                lineWidth: isActive ? 0 : 1.1
                                            )
                                    )
                                    .frame(
                                        width: isActive ? 34 : 27,
                                        height: isActive ? 34 : 27
                                    )
                                    .rotationEffect(.degrees(viewModel.isInteracting ? 360 : 0))
                                    .animation(
                                        .spring(response: 0.25, dampingFraction: 0.75),
                                        value: isActive
                                    )
                                    .animation(
                                        viewModel.isInteracting
                                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                                        : .easeOut(duration: 0.25),
                                        value: viewModel.isInteracting
                                    )

                                // Icon background
                                if viewModel.isInteracting || !viewModel.inputText.isEmpty {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 22, height: 22)
                                        .transition(.scale.combined(with: .opacity))
                                }

                                // Icon
                                if viewModel.isInteracting {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(UIColor.systemBackground))
                                        .transition(.scale.combined(with: .opacity))
                                } else if !viewModel.inputText.isEmpty {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(UIColor.systemBackground))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .frame(width: 34, height: 34)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isInteracting)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.inputText)
                        }
                        .disabled(!viewModel.isInteracting && viewModel.inputText.isEmpty)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
            }
        }
        .onTapGesture {
            showSandwich = true
            restartSandwichTimer()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: viewModel.isInteracting) { _, newValue in
            if newValue {
                isInputFocused = false
                restartSandwichTimer()
            } else {
                isInputFocused = false
                restartSandwichTimer()
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationBackground(.clear)
        }
        .onAppear {
            restartSandwichTimer()
        }
    }
    
    private func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true)
            AVAudioApplication.requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    guard allowed else {
                        print("Recording permission denied.")
                        return
                    }
                    self.setupRecorder()
                    self.audioRecorder?.record()
                    self.isRecording = true
                    self.startMetering()
                    print("Recording started.")
                }
            }
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        stopMetering()
        print("Recording stopped.")

        if let audioFilename = audioFilename {
            print("Recorded audio at: \(audioFilename.lastPathComponent)")
            viewModel.processAudio(audioURL: audioFilename)
        }
    }

    private func setupRecorder() {
        audioFilename = getDocumentsDirectory().appendingPathComponent("recording.m4a")

        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename!, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.delegate = viewModel
        } catch {
            print("Could not create audio recorder: \(error.localizedDescription)")
            stopRecording()
        }
    }

    private func startMetering() {
        silenceTimer = 0

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let recorder = audioRecorder, recorder.isRecording else { return }

            recorder.updateMeters()

            let power = recorder.averagePower(forChannel: 0)
            let raw = (power + 60) / 60
            let safeRaw: Float
            if raw.isNaN || raw.isInfinite {
                safeRaw = 0.2
            } else {
                safeRaw = raw
            }
            let clamped = max(0.05, min(1.5, CGFloat(safeRaw)))

            audioLevel = clamped

            if clamped < 0.08 {
                silenceTimer += 0.1
            } else {
                silenceTimer = 0
            }

            if silenceTimer >= 3 {
                stopRecording()
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0.2
        silenceTimer = 0
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private func restartSandwichTimer() {
        sandwichHideTask?.cancel()

        sandwichHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                withAnimation {
                    showSandwich = false
                }
            }
        }
    }
}

struct ThinkingPanel: View {
    let text: String
    let isThinking: Bool
    @State private var isExpanded: Bool = false
    @State private var pulse = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("Through")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .scaleEffect(pulse ? 1.05 : 1.0)
                        .opacity(pulse ? 1.0 : 0.7)
                        .animation(
                            pulse
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                            value: pulse
                        )
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(text.isEmpty ? "…" : text)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("BOTTOM")
                        }
                    }
                    .frame(maxHeight: 140)
                    .onChange(of: text) { _, _ in
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("BOTTOM", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("BOTTOM", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear {
            pulse = isThinking
        }
        .onDisappear {
            pulse = false
        }
        .onChange(of: isThinking) { _, newValue in
            pulse = newValue
        }
        .padding(8)
        .background(Color.clear)
    }
}

struct TypewriterText: View {
    let text: String

    @State private var displayed: String = ""
    @State private var lastText: String = ""

    var body: some View {
        md(displayed)
            .id("TYPEWRITER_BOTTOM")
            .opacity(displayed.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: displayed)
            .onAppear {
                displayed = text
                lastText = text
            }
            .onChange(of: text) { _, newValue in
                // If new text is an append, just add the delta
                if newValue.hasPrefix(displayed) {
                    let diff = String(newValue.dropFirst(displayed.count))
                    displayed += diff
                } else {
                    // Otherwise replace completely
                    displayed = newValue
                }
                lastText = newValue
            }
    }

    private func md(_ s: String) -> some View {
        let base: Text
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            base = Text(a)
        } else {
            base = Text(s)
        }
        return base
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }
}

struct TypingIndicatorView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 6) {
            dot(delay: 0)
            dot(delay: 0.2)
            dot(delay: 0.4)
        }
        .padding(.leading, 11)
        .onAppear {
            animate = true
        }
        .onDisappear {
            animate = false
        }
        .accessibilityLabel("Generating response")
    }

    private func dot(delay: Double) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.7))
            .frame(width: 3.14, height: 3.14)
            .scaleEffect(animate ? 1.4 : 0.9)
            .opacity(animate ? 1.0 : 0.3)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animate
            )
    }
}

struct MessageView: View {
    let message: Message
    let isThinkingForMessage: Bool
    let currentThink: String
    
    private let speech = SpeechService.shared
    private let experienceService = ExperienceService.shared
    
    private enum Segment {
        case text(String)
        case code(String, String?) // (content, language)
        case quote(String)
    }
    
    private var segments: [Segment] {
        parseSegments(message.content)
    }
    
    private func md(_ s: String) -> some View {
        let base: Text
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            base = Text(a)
        } else {
            base = Text(s)
        }

        return base
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }
    
    private func parseSegments(_ s: String) -> [Segment] {
        var result: [Segment] = []
        var lines = s.components(separatedBy: "\n")
        var bufferText: [String] = []
        var bufferQuote: [String] = []
        var inCode = false
        var codeLang: String?
        var codeLines: [String] = []
        
        func flushText() {
            if !bufferText.isEmpty {
                result.append(.text(bufferText.joined(separator: "\n")))
                bufferText.removeAll()
            }
        }
        func flushQuote() {
            if !bufferQuote.isEmpty {
                // Remove leading "> " from each line
                let cleaned = bufferQuote.map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("> ") {
                        return String(trimmed.dropFirst(2))
                    } else if trimmed.hasPrefix(">") {
                        return String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    }
                    return line
                }.joined(separator: "\n")
                result.append(.quote(cleaned))
                bufferQuote.removeAll()
            }
        }
        func flushCode() {
            if !codeLines.isEmpty {
                result.append(.code(codeLines.joined(separator: "\n"), codeLang))
                codeLines.removeAll()
            }
            codeLang = nil
        }
        
        while !lines.isEmpty {
            let line = lines.removeFirst()
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if inCode {
                if t.hasPrefix("```") {
                    inCode = false
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }
            
            if t.hasPrefix("```") {
                flushQuote()
                flushText()
                inCode = true
                let after = t.dropFirst(3)
                codeLang = after.isEmpty ? nil : String(after)
                continue
            }
            
            if t.hasPrefix(">") {
                flushText()
                bufferQuote.append(line)
                // If next line is not quote, flush
                if lines.first.map({ !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) ?? true {
                    flushQuote()
                }
                continue
            }
            
            bufferText.append(line)
            // If next line starts code/quote, flush text
            if let next = lines.first {
                let nt = next.trimmingCharacters(in: .whitespaces)
                if nt.hasPrefix("```") || nt.hasPrefix(">") {
                    flushText()
                }
            }
        }
        
        // Final flush
        if inCode { flushCode() }
        flushQuote()
        flushText()
        
        return result
    }
    
    private struct CodeBlockView: View {
        let content: String
        let language: String?
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
    }
    
    private struct QuoteBlockView: View {
        let content: String
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color(UIColor.quaternaryLabel))
                    .frame(width: 3)
                    .cornerRadius(2)
                Text(content)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(10)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
    }
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        switch seg {
                        case .text(let t):
                            if message.role == .assistant {
                                md(t)
                            } else {
                                md(t)
                            }
                        case .code(let code, let lang):
                            CodeBlockView(content: code, language: lang)
                        case .quote(let q):
                            QuoteBlockView(content: q)
                        }
                    }
                }
                    .padding()
                    .foregroundColor(.primary)
                    .contextMenu {
                        Button(action: {
                            UIPasteboard.general.string = message.content
                        }) {
                            Text("Copy")
                            Image(systemName: "doc.on.doc")
                        }
                        Button(action: {
                            speech.speak(text: message.content, voice: .female)
                        }) {
                            Text("Speak (Female)")
                            Image(systemName: "waveform")
                        }
                        Button(action: {
                            speech.speak(text: message.content, voice: .male)
                        }) {
                            Text("Speak (Male)")
                            Image(systemName: "waveform.circle")
                        }
                        if message.role == .assistant {
                            Button(action: {
                                experienceService.applyReaction(forAssistantMessageId: message.id, isLike: true)
                            }) {
                                Text("Like")
                                Image(systemName: "hand.thumbsup")
                            }
                            Button(action: {
                                experienceService.applyReaction(forAssistantMessageId: message.id, isLike: false)
                            }) {
                                Text("Dislike")
                                Image(systemName: "hand.thumbsdown")
                            }
                        }
                    }
            } else {
                VStack(alignment: .leading) {
                    if message.role == .system {
                        Text("System: \(message.content)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        if isThinkingForMessage || ((message.thinkContent ?? "").isEmpty == false) {
                            ThinkingPanel(
                                text: isThinkingForMessage ? currentThink : (message.thinkContent ?? ""),
                                isThinking: isThinkingForMessage
                            )
                            .padding(.bottom, 4)
                        }
                        if !message.content.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                                switch seg {
                                case .text(let t):
                                    if message.role == .assistant {
                                        md(t)
                                    } else {
                                        md(t)
                                    }
                                    case .code(let code, let lang):
                                        CodeBlockView(content: code, language: lang)
                                    case .quote(let q):
                                        QuoteBlockView(content: q)
                                    }
                                }
                            }
                                .padding()
                                .foregroundColor(.primary)
                                .opacity(message.content.isEmpty ? 0.01 : 1.0)
                                .animation(.easeOut(duration: 0.2), value: message.content)
                                .contextMenu {
                                    Button(action: {
                                        UIPasteboard.general.string = message.content
                                    }) {
                                        Text("Copy")
                                        Image(systemName: "doc.on.doc")
                                    }
                                    Button(action: {
                                        speech.speak(text: message.content, voice: .female)
                                    }) {
                                        Text("Speak (Female)")
                                        Image(systemName: "waveform")
                                    }
                                    Button(action: {
                                        speech.speak(text: message.content, voice: .male)
                                    }) {
                                        Text("Speak (Male)")
                                        Image(systemName: "waveform.circle")
                                    }
                                    if message.role == .assistant {
                                        Button(action: {
                                            experienceService.applyReaction(forAssistantMessageId: message.id, isLike: true)
                                        }) {
                                            Text("Like")
                                            Image(systemName: "hand.thumbsup")
                                        }
                                        Button(action: {
                                            experienceService.applyReaction(forAssistantMessageId: message.id, isLike: false)
                                        }) {
                                            Text("Dislike")
                                            Image(systemName: "hand.thumbsdown")
                                        }
                                    }
                                }
                        }
                        else if isThinkingForMessage || !(currentThink.isEmpty) {
                            TypingIndicatorView()
                        }
                    }
                }
                Spacer()
            }
        }
    }
    
}

#Preview {
    ChatView()
}
