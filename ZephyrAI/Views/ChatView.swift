import SwiftUI
import AVFoundation
import PhotosUI
import WebKit

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel.shared
    @State private var showSettings = false
    @State private var showSandwich: Bool = true
    @State private var sandwichHideTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var isRecording: Bool = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioFilename: URL?
    @State private var audioLevel: CGFloat = 0.2
    @State private var silenceTimer: TimeInterval = 0
    @State private var meterTimer: Timer?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var inputBarHeight: CGFloat = 58
    private let baselineInputBarHeight: CGFloat = 58
    @State private var isUserControllingScroll = false
    @State private var autoScrollResumeTask: Task<Void, Never>?
    private let autoScrollResumeDelayNs: UInt64 = 3_000_000_000

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(
                                message: message,
                                isThinkingForMessage: viewModel.isInteracting && viewModel.currentThinkingMessageId == message.id,
                                currentThink: viewModel.currentThink,
                                isStreamingCurrentMessage: viewModel.isInteracting && viewModel.messages.last?.id == message.id,
                                isPolishingArtifact: viewModel.isPolishingArtifact(for: message.id),
                                onEditUserMessage: { id in
                                    viewModel.beginEditingUserMessage(id)
                                    isInputFocused = true
                                },
                                onRegenerateAssistantMessage: { id in
                                    viewModel.regenerateAssistantResponse(for: id)
                                }
                            )
                                .id(message.id)
                        }
                    }
                    .padding()
                    .padding(.top, 58)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    guard !isUserControllingScroll else { return }
                    guard let lastId = viewModel.messages.last?.id else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.currentThink) { _, _ in
                    guard !isUserControllingScroll else { return }
                    guard let lastId = viewModel.messages.last?.id else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                .onChange(of: isInputFocused) { _, focused in
                    guard focused, let lastId = viewModel.messages.last?.id else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isUserControllingScroll) { _, isControlling in
                    guard !isControlling else { return }
                    guard viewModel.isInteracting else { return }
                    guard let lastId = viewModel.messages.last?.id else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        showSandwich = true
                        restartSandwichTimer()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in
                            registerUserScrollControl()
                        }
                        .onEnded { _ in
                            registerUserScrollControl()
                        }
                )
            }

            // Intro Greeting Overlay
            if viewModel.messages.isEmpty {
                let isTyping = !viewModel.inputText.isEmpty
                IntroGreetingView(text: IntroGreetingCopy.current(), isTyping: isTyping)
                    .padding(.top, 8)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                .transition(.opacity)
            }

            SoftBarBlurBackground(position: .top)
                .frame(height: 188)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -18)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Header / Status
                ZStack {

                    // Tap area (doesn't block buttons)
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(false)

                    // Title center
                    Text("V A L I S")
                        .font(.system(size: 17, weight: .medium))
                        .offset(y: -11)

                    // Right side (status + sandwich)
                    HStack(spacing: 9) {
                        Spacer()

                        Text(viewModel.status)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 120, alignment: .trailing)
                            .opacity(viewModel.status.isEmpty ? 0 : 0.85)
                            .animation(.easeOut(duration: 0.2), value: viewModel.status)

                        Button {
                            showSettings = true
                            restartSandwichTimer()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.primary)
                                .opacity(showSandwich ? 1 : 0.15)
                                .scaleEffect(showSandwich ? 1 : 0.8)
                                .animation(.easeInOut(duration: 0.25), value: showSandwich)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal)
                .background(Color.clear)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let editingId = viewModel.editingUserMessageId,
                   let message = viewModel.messages.first(where: { $0.id == editingId && $0.role == .user }) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Editing message: \(message.content)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            viewModel.cancelEditingUserMessage()
                            viewModel.inputText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }

                if let attachment = viewModel.pendingImageAttachment {
                    HStack {
                        InputAttachmentPreview(attachment: attachment) {
                            viewModel.removePendingImage()
                            selectedPhotoItem = nil
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }

                HStack(alignment: .bottom) {
                    TextField(viewModel.editingUserMessageId == nil ? "Type a message..." : "Edit message...", text: $viewModel.inputText, axis: .vertical)
                        .focused($isInputFocused)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .disabled(isRecording)
                        .tint(colorScheme == .dark ? .white : .black)

                    if viewModel.inputText.isEmpty && viewModel.pendingImageAttachment == nil && !viewModel.isInteracting {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.56))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .offset(y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isInteracting || isRecording)

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
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.56))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .offset(y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isInteracting || isRecording)

                        Button(action: {
                            if viewModel.isInteracting {
                                viewModel.stopGeneration()
                            } else {
                                isInputFocused = false
                                viewModel.sendMessage()
                            }
                        }) {
                            ZStack {
                                let isActive = viewModel.isInteracting || !viewModel.inputText.isEmpty || viewModel.pendingImageAttachment != nil
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

                                if viewModel.isInteracting || !viewModel.inputText.isEmpty || viewModel.pendingImageAttachment != nil {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 22, height: 22)
                                        .transition(.scale.combined(with: .opacity))
                                }

                                if viewModel.isInteracting {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(UIColor.systemBackground))
                                        .transition(.scale.combined(with: .opacity))
                                } else if !viewModel.inputText.isEmpty || viewModel.pendingImageAttachment != nil {
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
                        .disabled(!viewModel.isInteracting && viewModel.inputText.isEmpty && viewModel.pendingImageAttachment == nil)
                    }
                }
                .padding()
                .background(Color.clear)
            }
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.height
            } action: { newHeight in
                let clamped = max(baselineInputBarHeight, newHeight)
                withAnimation(.easeOut(duration: 0.18)) {
                    inputBarHeight = clamped
                }
            }
            .background(alignment: .bottom) {
                SoftBarBlurBackground(position: .bottom)
                    .frame(height: 145 + max(0, inputBarHeight - baselineInputBarHeight))
                    .offset(y: 42)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
        // .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: viewModel.isInteracting) { _, newValue in
            _ = newValue
            restartSandwichTimer()
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        viewModel.setPendingImage(from: data)
                    }
                }
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
        .onDisappear {
            autoScrollResumeTask?.cancel()
            autoScrollResumeTask = nil
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

    private func registerUserScrollControl() {
        isUserControllingScroll = true
        autoScrollResumeTask?.cancel()
        autoScrollResumeTask = Task {
            try? await Task.sleep(nanoseconds: autoScrollResumeDelayNs)
            if Task.isCancelled { return }
            await MainActor.run {
                isUserControllingScroll = false
            }
        }
    }

}

struct ThinkingPanel: View {
    let text: String
    let isThinking: Bool
    @State private var isExpanded: Bool = false
    @State private var pulse = false
    @State private var didEmitThoughtReadyHaptic = false
    @State private var isUserControllingThoughtScroll = false
    @State private var thoughtAutoScrollResumeTask: Task<Void, Never>?
    private let thoughtAutoScrollResumeDelayNs: UInt64 = 3_000_000_000

    private var hasThoughtText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusLabel: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let toolName = detectedToolName(in: trimmed) {
            return "Using tool: \(toolName)"
        }
        if lower.contains("code") || lower.contains("function") || lower.contains("bug") || lower.contains("refactor") {
            return "Analyzing code"
        }
        if lower.contains("plan") || lower.contains("step") || lower.contains("approach") {
            return "Planning steps"
        }
        if lower.contains("search") || lower.contains("lookup") || lower.contains("look up") || lower.contains("web") || lower.contains("research") {
            return "Searching context"
        }
        if isThinking {
            return trimmed.isEmpty ? "Thinking..." : "Reasoning..."
        }
        return "Thoughts"
    }

    private func detectedToolName(in source: String) -> String? {
        guard !source.isEmpty else { return nil }
        let pattern = #"(?i)(?:tool|action)\s*:\s*([^\n|,()]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: nsRange),
              let rawRange = Range(match.range(at: 1), in: source) else {
            return nil
        }

        let raw = source[rawRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let token = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .first?
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        guard let token, !token.isEmpty else { return nil }
        return token
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                guard hasThoughtText else { return }
                playTapHaptic()
                isExpanded.toggle()
            }) {
                HStack {
                    Text(statusLabel)
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
                    if hasThoughtText {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded && hasThoughtText {
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
                        guard !isUserControllingThoughtScroll else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("BOTTOM", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isUserControllingThoughtScroll) { _, isControlling in
                        guard !isControlling else { return }
                        guard isExpanded else { return }
                        guard hasThoughtText else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("BOTTOM", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("BOTTOM", anchor: .bottom)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { _ in
                                registerThoughtScrollControl()
                            }
                            .onEnded { _ in
                                registerThoughtScrollControl()
                            }
                    )
                }
            }
        }
        .onAppear {
            pulse = isThinking
            if !hasThoughtText {
                isExpanded = false
            }
        }
        .onDisappear {
            pulse = false
            thoughtAutoScrollResumeTask?.cancel()
            thoughtAutoScrollResumeTask = nil
        }
        .onChange(of: isThinking) { _, newValue in
            pulse = newValue
        }
        .onChange(of: text) { _, newValue in
            let hasTextNow = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasTextNow {
                isExpanded = false
                didEmitThoughtReadyHaptic = false
                return
            }
            if !didEmitThoughtReadyHaptic {
                playThoughtReadyHaptic()
                didEmitThoughtReadyHaptic = true
            }
        }
        .padding(8)
        .background(Color.clear)
    }

    private func playTapHaptic() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.8)
#endif
    }

    private func playThoughtReadyHaptic() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
#endif
    }

    private func registerThoughtScrollControl() {
        isUserControllingThoughtScroll = true
        thoughtAutoScrollResumeTask?.cancel()
        thoughtAutoScrollResumeTask = Task {
            try? await Task.sleep(nanoseconds: thoughtAutoScrollResumeDelayNs)
            if Task.isCancelled { return }
            await MainActor.run {
                isUserControllingThoughtScroll = false
            }
        }
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
        if let a = MarkdownRenderer.renderInline(s) {
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

private func attachmentURL(for attachment: MessageImageAttachment) -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents
        .appendingPathComponent("image-attachments", isDirectory: true)
        .appendingPathComponent(attachment.filename)
}

private struct AttachmentThumbnail: View {
    let attachment: MessageImageAttachment

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: attachmentURL(for: attachment).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct InputAttachmentPreview: View {
    let attachment: MessageImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AttachmentThumbnail(attachment: attachment)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct MessageAttachmentView: View {
    let attachment: MessageImageAttachment
    let maxWidth: CGFloat
    @State private var showFullscreen = false

    private var maxHeight: CGFloat {
        320
    }

    var body: some View {
        Button {
            showFullscreen = true
        } label: {
            AttachmentThumbnail(attachment: attachment)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fullScreenCover(isPresented: $showFullscreen) {
            AttachmentFullscreenView(attachment: attachment)
                .presentationBackground(.clear)
        }
    }
}

private struct AttachmentFullscreenView: View {
    let attachment: MessageImageAttachment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isGlassActive = false
    @GestureState private var dragTranslation: CGSize = .zero

    private let glassOpacityDark: Double = 0.32
    private let glassOpacityLight: Double = 0.44
    private let glassOverlayOpacityDark: Double = 0.5
    private let glassOverlayOpacityLight: Double = 0.4
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18

    private var glassBackground: some View {
        let baseOpacity = colorScheme == .dark ? glassOpacityDark : glassOpacityLight
        let overlayOpacity = colorScheme == .dark ? glassOverlayOpacityDark : glassOverlayOpacityLight
        return ZStack {
            AttachmentGlassDistortionLayer(
                baseOpacity: baseOpacity,
                blurRadius: glassBlurRadius,
                maxOffset: glassMaxOffset,
                isActive: isGlassActive
            )
            .ignoresSafeArea()
            .opacity(backgroundOpacity)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(overlayOpacity)
                .ignoresSafeArea()
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            glassBackground

            if colorScheme == .dark {
                Color.black.opacity(0.25)
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()
            }

            Group {
                if let image = UIImage(contentsOfFile: attachmentURL(for: attachment).path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .offset(y: verticalDragOffset)
                        .scaleEffect(imageScale)
                        .gesture(dismissDragGesture)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 36, weight: .medium))
                        Text("Image unavailable")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .padding(.top, 16)
            .padding(.leading, 16)
        }
        .statusBar(hidden: true)
        .onAppear { isGlassActive = true }
        .onDisappear { isGlassActive = false }
    }

    private var imageScale: CGFloat {
        let progress = min(dragProgress * 0.12, 0.12)
        return 1 - progress
    }

    private var verticalDragOffset: CGFloat {
        guard abs(dragTranslation.height) > abs(dragTranslation.width) else { return 0 }
        return dragTranslation.height
    }

    private var dragProgress: CGFloat {
        min(abs(verticalDragOffset) / 320, 1)
    }

    private var backgroundOpacity: CGFloat {
        1 - (dragProgress * 0.35)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                state = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else {
                    return
                }

                let predictedHeight = value.predictedEndTranslation.height
                if abs(value.translation.height) > 120 || abs(predictedHeight) > 220 {
                    dismiss()
                }
            }
    }
}

private struct AttachmentGlassDistortionLayer: View {
    let baseOpacity: Double
    let blurRadius: CGFloat
    let maxOffset: CGFloat
    let isActive: Bool

    var body: some View {
        if #available(iOS 17.0, *) {
            GeometryReader { proxy in
                if isActive {
                    TimelineView(.animation) { timeline in
                        let t = Float(timeline.date.timeIntervalSinceReferenceDate)
                        let w = Float(max(1.0, proxy.size.width))
                        let h = Float(max(1.0, proxy.size.height))
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .distortionEffect(
                                ShaderLibrary.glassDistortion(
                                    .float2(w, h),
                                    .float(t)
                                ),
                                maxSampleOffset: CGSize(width: maxOffset, height: maxOffset)
                            )
                            .blur(radius: blurRadius)
                            .opacity(baseOpacity)
                    }
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .blur(radius: blurRadius)
                        .opacity(baseOpacity)
                }
            }
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .blur(radius: blurRadius)
                .opacity(baseOpacity)
        }
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
        .accessibilityLabel("Generating respo nse")
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
    let isStreamingCurrentMessage: Bool
    let isPolishingArtifact: Bool
    let onEditUserMessage: (UUID) -> Void
    let onRegenerateAssistantMessage: (UUID) -> Void
    
    private let speech = SpeechService.shared
    private let experienceService = ExperienceService.shared
    
    private enum Segment {
        case text(String)
        case code(String, String?) // (content, language)
        case quote(String)
    }

    struct Artifact: Identifiable {
        let id: String
        let type: String
        let title: String?
        let payload: String
    }

    private var artifacts: [Artifact] {
        parseArtifacts(from: message.content)
    }

    private var synthesizedUserArtifact: Artifact? {
        guard message.role == .user else { return nil }
        guard artifacts.isEmpty else { return nil }
        return parseUserHTMLArtifact(from: message.content)
    }

    private var effectiveArtifacts: [Artifact] {
        if !artifacts.isEmpty { return artifacts }
        if let synthesizedUserArtifact { return [synthesizedUserArtifact] }
        return []
    }

    private var renderableContent: String {
        if synthesizedUserArtifact != nil {
            return ""
        }
        return stripArtifacts(from: message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var streamingArtifact: Artifact? {
        guard artifacts.isEmpty else { return nil }
        guard synthesizedUserArtifact == nil else { return nil }
        return parseStreamingArtifact(from: message.content)
    }

    private var hasRenderableText: Bool {
        !renderableContent.isEmpty
    }

    private var segments: [Segment] {
        parseSegments(renderableContent)
    }

    private var assistantBubbleMaxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.88, 760)
    }

    private var userBubbleMaxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.72, 420)
    }
    
    private func md(_ s: String) -> some View {
        // Check for LaTeX
        if s.contains("\\(") || s.contains("\\[") || s.contains("$$") {
            return AnyView(MathJaxMessageView(content: s))
        }
        
        let base: Text

        if var a = MarkdownRenderer.renderInline(s) {

            // Rewrite link styling to avoid default blue tint
            for run in a.runs {
                if run.link != nil {
                    a[run.range].foregroundColor = .primary
                    a[run.range].underlineStyle = .single
                    a[run.range].underlineColor = UIColor.label.withAlphaComponent(0.6)
                }
            }

            base = Text(a)
        } else {
            base = Text(s)
        }

        return AnyView(base
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled))
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

    private func parseArtifacts(from text: String) -> [Artifact] {
        let pattern = "(?is)<artifact\\b([^>]*)>(.*?)</artifact>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var out: [Artifact] = []
        for (index, match) in matches.enumerated() {
            guard let attrsRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let attrsRaw = String(text[attrsRange])
            let payloadRaw = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if payloadRaw.isEmpty { continue }

            let attrs = parseArtifactAttributes(attrsRaw)
            let type = (attrs["type"] ?? "html").lowercased()
            guard type == "html" else { continue }

            let title = attrs["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "\(message.id.uuidString)-artifact-\(index)"
            out.append(Artifact(id: id, type: type, title: title, payload: payloadRaw))
        }

        if out.isEmpty,
           !isStreamingCurrentMessage,
           let recovered = parseRecoveredArtifact(from: text) {
            out.append(recovered)
        }
        return out
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
            var value = ""

            if let quoted = Range(match.range(at: 3), in: raw) {
                value = String(raw[quoted])
            } else if let singleQuoted = Range(match.range(at: 4), in: raw) {
                value = String(raw[singleQuoted])
            }
            if !key.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private func stripArtifacts(from text: String) -> String {
        text.replacingOccurrences(
            of: "(?is)<artifact\\b[^>]*>.*?(</artifact>|$)",
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: "(?im)^\\s*</artifact>\\s*$",
            with: "",
            options: .regularExpression
        )
    }

    private func countMatches(in text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: nsRange)
    }

    private func parseStreamingArtifact(from text: String) -> Artifact? {
        let openCount = countMatches(in: text, pattern: "(?i)<artifact\\b")
        let closeCount = countMatches(in: text, pattern: "(?i)</artifact>")
        guard openCount > closeCount else { return nil }

        let nsText = text as NSString
        let fullLen = nsText.length
        let openStart = nsText.range(of: "<artifact", options: [.caseInsensitive, .backwards])
        guard openStart.location != NSNotFound else { return nil }

        let openEndSearch = NSRange(location: openStart.location, length: fullLen - openStart.location)
        let openEnd = nsText.range(of: ">", options: [], range: openEndSearch)
        guard openEnd.location != NSNotFound else { return nil }

        let attrsStart = openStart.location + "<artifact".count
        let attrsLen = max(0, openEnd.location - attrsStart)
        let attrsRaw = nsText.substring(with: NSRange(location: attrsStart, length: attrsLen))
        let attrs = parseArtifactAttributes(attrsRaw)
        let type = (attrs["type"] ?? "html").lowercased()
        guard type == "html" else { return nil }

        let bodyStart = openEnd.location + openEnd.length
        guard bodyStart <= fullLen else { return nil }
        let payload = nsText.substring(from: bodyStart)
        let title = attrs["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "\(message.id.uuidString)-artifact-streaming"
        return Artifact(id: id, type: type, title: title, payload: payload)
    }

    private func parseRecoveredArtifact(from text: String) -> Artifact? {
        let pattern = #"(?is)<artifact\b([^>]*)>(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let attrsRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else { return nil }

        let attrsRaw = String(text[attrsRange])
        let attrs = parseArtifactAttributes(attrsRaw)
        let type = (attrs["type"] ?? "html").lowercased()
        guard type == "html" else { return nil }

        var payload = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        payload = repairArtifactHTML(payload)
        let lower = payload.lowercased()
        guard lower.contains("<!doctype html") || lower.contains("<html") || lower.contains("<body") else {
            return nil
        }

        let title = attrs["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Artifact(
            id: "\(message.id.uuidString)-artifact-recovered",
            type: type,
            title: title,
            payload: payload
        )
    }

    private func parseUserHTMLArtifact(from text: String) -> Artifact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 220 else { return nil }

        if let fenced = parseFencedHTMLPayload(from: trimmed) {
            return Artifact(
                id: "\(message.id.uuidString)-artifact-user-html",
                type: "html",
                title: "User HTML",
                payload: repairArtifactHTML(fenced)
            )
        }

        let lower = trimmed.lowercased()
        let htmlSignalCount = [
            "<!doctype html", "<html", "<head", "<body", "<style", "<script", "</html>"
        ].filter { lower.contains($0) }.count
        guard htmlSignalCount >= 2 else { return nil }

        return Artifact(
            id: "\(message.id.uuidString)-artifact-user-html",
            type: "html",
            title: "User HTML",
            payload: repairArtifactHTML(trimmed)
        )
    }

    private func parseFencedHTMLPayload(from text: String) -> String? {
        let pattern = #"(?is)```(?:html)?\s*(<!doctype html.*?|<html.*?|<body.*?).*?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let payloadRange = Range(match.range(at: 1), in: text) else { return nil }
        let payload = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private func repairArtifactHTML(_ payload: String) -> String {
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
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            if message.role == .user {
                VStack(alignment: .leading, spacing: 8) {
                    if let attachment = message.imageAttachment {
                        MessageAttachmentView(attachment: attachment, maxWidth: 220)
                    }
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
                    ForEach(effectiveArtifacts) { artifact in
                        ArtifactBlockView(artifact: artifact, isPolishing: false)
                    }
                }
                    .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                    .padding()
                    .foregroundColor(.primary)
                    .contextMenu {
                        Button(action: {
                            onEditUserMessage(message.id)
                        }) {
                            Text("Edit message")
                            Image(systemName: "pencil")
                        }
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
                        if hasRenderableText || message.imageAttachment != nil || !effectiveArtifacts.isEmpty || streamingArtifact != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                if let attachment = message.imageAttachment {
                                    MessageAttachmentView(attachment: attachment, maxWidth: 260)
                                }
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
                                ForEach(effectiveArtifacts) { artifact in
                                    ArtifactBlockView(artifact: artifact, isPolishing: isPolishingArtifact)
                                }
                                if let streamingArtifact {
                                    ArtifactGeneratingCardView(artifact: streamingArtifact)
                                }
                            }
                                .padding(.vertical, 12)
                                .padding(.leading, 14)
                                .padding(.trailing, 18)
                                .foregroundColor(.primary)
                                .opacity(message.content.isEmpty ? 0.01 : 1.0)
                                .animation(.easeOut(duration: 0.2), value: message.content)
                                .contextMenu {
                                    Button(action: {
                                        onRegenerateAssistantMessage(message.id)
                                    }) {
                                        Text("Regenerate")
                                        Image(systemName: "arrow.clockwise")
                                    }
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
                .frame(maxWidth: assistantBubbleMaxWidth, alignment: .leading)
                Spacer(minLength: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.leading, 8)
        .padding(.trailing, 12)
    }
    
}

private struct ArtifactGeneratingCardView: View {
    let artifact: MessageView.Artifact
    @State private var animate = false
    @State private var showFullscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Artifact")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.02))

                ArtifactGenerationShaderLayer(isActive: animate)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Building artifact...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                            Text("Tap to inspect live code")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.white.opacity(0.46))
                        }
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
        }
        .opacity(animate ? 1.0 : 0.6)
        .scaleEffect(animate ? 1.0 : 0.985)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .onDisappear {
            animate = false
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            showFullscreen = true
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            ArtifactFullscreenView(
                artifact: artifact,
                startInCodeMode: true,
                isLiveStream: true
            )
        }
    }
}

private struct ArtifactGenerationShaderLayer: View {
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

            ZStack {
                if #available(iOS 17.0, *), isActive {
                    TimelineView(.animation) { timeline in
                        let t = Float(timeline.date.timeIntervalSinceReferenceDate)
                        let w = Float(max(1.0, proxy.size.width))
                        let h = Float(max(1.0, proxy.size.height))

                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .distortionEffect(
                                ShaderLibrary.glassDistortion(
                                    .float2(w, h),
                                    .float(t)
                                ),
                                maxSampleOffset: CGSize(width: 10, height: 10)
                            )
                            .blur(radius: 10)
                            .opacity(0.34)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.24),
                                        Color.white.opacity(0.12),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * 0.5)
                            .blur(radius: 12)
                            .offset(x: CGFloat(sin(Double(t) * 0.8)) * proxy.size.width * 0.22)
                            .blendMode(.screen)
                    }
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.22)
                }
            }
            .clipShape(shape)
        }
    }
}

private struct ArtifactBlockView: View {
    let artifact: MessageView.Artifact
    let isPolishing: Bool
    @State private var showCode: Bool = false
    @State private var showFullscreen: Bool = false
    @State private var showFullscreenHint: Bool = false
    @State private var hideFullscreenHintTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(artifact.title?.isEmpty == false ? artifact.title! : "Artifact")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showCode.toggle()
                } label: {
                    Image(systemName: showCode ? "eye" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if showFullscreenHint {
                HStack {
                    Spacer()
                    Text("you can edit the code in fullscreen artifact")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Group {
                if showCode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(artifact.payload)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground))
                } else {
                    ArtifactView(html: artifact.payload)
                        .frame(minHeight: 180, maxHeight: 320)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .blur(radius: isPolishing ? 5 : 0)
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(UIColor.quaternaryLabel), lineWidth: 0.7)

                    if isPolishing {
                        ZStack {
                            Color.white.opacity(0.06)
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white.opacity(0.8))
                                Text("Improving your artifact...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                        }
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.opacity)
                    }
                }
            )
            .animation(.easeOut(duration: 0.2), value: isPolishing)
        }
        .onChange(of: showCode) { _, isCodeMode in
            if isCodeMode {
                showFullscreenHintTemporarily()
            } else {
                hideFullscreenHintTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) {
                    showFullscreenHint = false
                }
            }
        }
        .onDisappear {
            hideFullscreenHintTask?.cancel()
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            ArtifactFullscreenView(
                artifact: artifact,
                startInCodeMode: false,
                isLiveStream: false
            )
        }
    }

    private func showFullscreenHintTemporarily() {
        hideFullscreenHintTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            showFullscreenHint = true
        }
        hideFullscreenHintTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    showFullscreenHint = false
                }
            }
        }
    }
}

private struct ArtifactFullscreenView: View {
    let artifact: MessageView.Artifact
    let startInCodeMode: Bool
    let isLiveStream: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showCode: Bool = false
    @State private var editableCode: String = ""
    @State private var renderedCode: String = ""
    @State private var showEditHint: Bool = false
    @State private var hideHintTask: Task<Void, Never>?
    @State private var showCopiedHint: Bool = false
    @State private var hideCopiedHintTask: Task<Void, Never>?
    @State private var isFollowingLiveCode: Bool = true
    @State private var resumeLiveFollowTask: Task<Void, Never>?
    private let liveCodeBottomID = "LIVE_CODE_BOTTOM"

    var body: some View {
        Group {
            if showCode {
                if isLiveStream {
                    ScrollViewReader { proxy in
                        GeometryReader { geo in
                            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(editableCode)
                                        .font(.system(.body, design: .monospaced))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .textSelection(.enabled)
                                        .padding(10)
                                    Color.clear
                                        .frame(height: 1)
                                        .id(liveCodeBottomID)
                                }
                                .frame(
                                    minWidth: geo.size.width,
                                    minHeight: geo.size.height,
                                    alignment: .topLeading
                                )
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 2).onChanged { _ in
                                    isFollowingLiveCode = false
                                    resumeLiveFollowTask?.cancel()
                                }.onEnded { _ in
                                    scheduleLiveFollowResume()
                                }
                            )
                        }
                        .onAppear {
                            isFollowingLiveCode = true
                            scrollToLiveCodeBottom(proxy, animated: false)
                        }
                        .onChange(of: editableCode) { _, _ in
                            guard isFollowingLiveCode else { return }
                            scrollToLiveCodeBottom(proxy, animated: true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
                    .safeAreaPadding(.bottom, 8)
                } else {
                    TextEditor(text: $editableCode)
                        .font(.system(.body, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemBackground))
                        .safeAreaPadding(.bottom, 8)
                }
            } else {
                ArtifactView(html: renderedCode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            if editableCode.isEmpty && renderedCode.isEmpty {
                editableCode = artifact.payload
                renderedCode = artifact.payload
            }
            if startInCodeMode {
                showCode = true
            }
            if isLiveStream {
                isFollowingLiveCode = true
            }
        }
        .onChange(of: editableCode) { _, newValue in
            renderedCode = newValue
        }
        .onChange(of: artifact.payload) { _, newValue in
            if isLiveStream {
                editableCode = newValue
                renderedCode = newValue
            }
        }
        .onChange(of: showCode) { _, isCodeMode in
            if isCodeMode && !isLiveStream {
                showEditHintTemporarily()
            } else {
                hideHintTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) {
                    showEditHint = false
                }
            }
        }
        .onDisappear {
            hideHintTask?.cancel()
            hideCopiedHintTask?.cancel()
            resumeLiveFollowTask?.cancel()
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            showCode.toggle()
                        } label: {
                            Image(systemName: showCode ? "eye" : "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            editableCode = artifact.payload
                            renderedCode = artifact.payload
                            if isLiveStream {
                                isFollowingLiveCode = true
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .opacity(isLiveStream ? 0.45 : 1.0)
                        .disabled(isLiveStream)

                        Button {
                            UIPasteboard.general.string = editableCode
                            showCopiedHintTemporarily()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                if showEditHint {
                    HStack {
                        Spacer()
                        Text("you can edit the code")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if showCopiedHint {
                    HStack {
                        Spacer()
                        Text("copied")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
    }

    private func showEditHintTemporarily() {
        hideHintTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            showEditHint = true
        }
        hideHintTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    showEditHint = false
                }
            }
        }
    }

    private func showCopiedHintTemporarily() {
        hideCopiedHintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            showCopiedHint = true
        }
        hideCopiedHintTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.15)) {
                    showCopiedHint = false
                }
            }
        }
    }

    private func scrollToLiveCodeBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(liveCodeBottomID, anchor: .bottomLeading)
                }
            } else {
                proxy.scrollTo(liveCodeBottomID, anchor: .bottomLeading)
            }
        }
    }

    private func scheduleLiveFollowResume() {
        resumeLiveFollowTask?.cancel()
        resumeLiveFollowTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isFollowingLiveCode = true
            }
        }
    }
}

private struct SoftBarBlurBackground: View {
    enum Position {
        case top
        case bottom
    }

    let position: Position
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                BlurEffectView(style: .dark)
                    .colorMultiply(.black)
                    .opacity(0.92)
                BlurEffectView(style: .dark)
                    .colorMultiply(.black)
                    .opacity(0.5)
                Color.black.opacity(0.12)
            } else {
                BlurEffectView(style: .light)
                    .opacity(1.0)
                BlurEffectView(style: .light)
                    .opacity(0.55)
                Color.white.opacity(0.09)
            }
        }
        .mask(
            LinearGradient(
                stops: position == .top
                ? [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.56),
                    .init(color: .clear, location: 1.0)
                ]
                : [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white, location: 0.44),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct BlurEffectView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

private struct MathJaxMessageView: UIViewRepresentable {
    let content: String
    
    typealias UIViewType = ContentSizedWebView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ContentSizedWebView {
        let config = WKWebViewConfiguration()
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = webpagePrefs
        config.userContentController.add(context.coordinator, name: "onMathJaxReady")

        let webView = ContentSizedWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: ContentSizedWebView, context: Context) {
        let html = wrappedHTML(content)
        if context.coordinator.lastContent != html {
            context.coordinator.lastContent = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func wrappedHTML(_ body: String) -> String {
        // Escape backslashes for HTML
        let escapedBody = body
            .replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\\n", with: "\\\\n")

        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script>
            window.MathJax = {
              tex: {
                inlineMath: [['\\\\(', '\\\\)']],
                displayMath: [['\\\\[', '\\\\]']],
                processEscapes: true
              },
              svg: { fontCache: 'global' },
              startup: {
                typeset: true,
                ready: function() {
                  MathJax.startup.defaultReady();
                  MathJax.startup.promise.then(function() {
                    window.webkit.messageHandlers.onMathJaxReady.postMessage({});
                  });
                }
              }
            };
            </script>
            <script type="text/javascript" id="MathJax-script" async
              src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js">
            </script>
            <style>
              html, body {
                margin: 0;
                padding: 8px 0;
                background: transparent;
                color: #111;
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
                font-size: 15px;
                overflow-x: auto;
              }
              .mjx-container {
                overflow-x: auto;
                overflow-y: hidden;
              }
            </style>
          </head>
          <body>
            \(escapedBody)
          </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastContent: String = ""
        weak var webView: ContentSizedWebView?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "onMathJaxReady" else { return }
            refreshHeight()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refreshHeight()
        }

        private func refreshHeight() {
            guard let webView else { return }
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                let measured = (result as? CGFloat) ?? (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                let height = max(28, measured)
                guard abs(webView.reportedHeight - height) > 1 else { return }
                webView.reportedHeight = height
                webView.invalidateIntrinsicContentSize()
            }
        }
    }

    final class ContentSizedWebView: WKWebView {
        var reportedHeight: CGFloat = 28

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: reportedHeight)
        }
    }
}

#Preview {
    ChatView()
}
