import SwiftUI

struct SettingsView: View {
    // Glass tuning
    private let glassOpacityDark: Double = 0.12
    private let glassOpacityLight: Double = 0.12
    private let glassOverlayOpacityDark: Double = 0.3
    private let glassOverlayOpacityLight: Double = 0.3
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18
    @Environment(\.dismiss) private var dismiss
    @State private var isGlassActive = false
    @State private var showInstantModeInfo = false
    @State private var instantModeInfoTask: Task<Void, Never>?
    @AppStorage(LLMModelStorage.key) private var selectedModelRaw: String = LLMModelStorage.defaultValue.rawValue
    @AppStorage(LLMThinkingModeStorage.key) private var thinkingModeRaw: String = LLMThinkingModeStorage.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var glassBaseLayer: some View {
        GlassDistortionLayer(
            baseOpacity: colorScheme == .dark ? glassOpacityDark : glassOpacityLight,
            blurRadius: glassBlurRadius,
            maxOffset: glassMaxOffset,
            isActive: isGlassActive
        )
        .ignoresSafeArea()
    }

    private var glassOverlayLayer: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(colorScheme == .dark ? glassOverlayOpacityDark : glassOverlayOpacityLight)
            .ignoresSafeArea()
    }

    private var glassBackground: some View {
        ZStack {
            GlassPageBackground()
            glassBaseLayer   // твой шейдер glassDistortion
        }
    }

    private var contentLayer: some View {
        ZStack {
            glassBackground
            settingsList
            topBlur
            bottomBlur
        }
    }

    private var settingsList: some View {
        List {
            modelSection
            memoriesSection
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .background(Color.clear)
    }

    private var modelSection: some View {
        Section("Model") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Response Mode", selection: $thinkingModeRaw) {
                    ForEach(LLMThinkingMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Response Mode")
                .onChange(of: thinkingModeRaw) { _, newValue in
                    instantModeInfoTask?.cancel()
                    guard newValue == LLMThinkingMode.instant.rawValue else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showInstantModeInfo = false
                        }
                        return
                    }

                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        showInstantModeInfo = true
                    }
                    instantModeInfoTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            showInstantModeInfo = false
                        }
                    }
                }

                if showInstantModeInfo {
                    instantModeInfoBubble
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Picker("Model Size", selection: $selectedModelRaw) {
                    ForEach(LLMModelChoice.allCases) { model in
                        Text("\(model.displayName) \(model.detailLabel)")
                            .tag(model.rawValue)
                    }
                }
                .pickerStyle(.palette)
                .labelsHidden()
                .background(Color.clear)
                .compositingGroup()
                .onChange(of: selectedModelRaw) { _, _ in
                    LLMModelStorage.notifyChange()
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
    }

    private var memoriesSection: some View {
        Section("Memories") {
            newChatButton
            chatsLink
            personaLink
            memoriesLink
        }
        .listRowBackground(
            (colorScheme == .dark ? Color.white : Color.black)
                .opacity(0.05)
        )
    }

    private var newChatButton: some View {
        Button {
            ChatViewModel.shared.createNewChat()
            dismiss()
        } label: {
            HStack(spacing: 13) {
                Text("New Chat")
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .foregroundColor(colorScheme == .dark ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var chatsLink: some View {
        NavigationLink { ChatListView() } label: {
            rowLabel("Chats")
        }
        .buttonStyle(.plain)
    }

    private var personaLink: some View {
        NavigationLink { PersonaListView() } label: {
            rowLabel("Persona")
        }
        .buttonStyle(.plain)
    }

    private var memoriesLink: some View {
        NavigationLink { MemoryListView() } label: {
            rowLabel("Memories")
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .foregroundColor(colorScheme == .dark ? .white : .primary)
    }

    private var topBlur: some View {
        SettingsEdgeBlurOverlay(position: .top)
            .frame(height: 99)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -20)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    private var bottomBlur: some View {
        SettingsEdgeBlurOverlay(position: .bottom)
            .frame(height: 130)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: 62)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
    }

    // Back button for navigation bar
    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            backButtonLabel
        }
        .buttonStyle(.plain)
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
    }

    private var backButtonLabel: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .padding(10)
            .background(Color.clear, in: Circle())
    }

    var body: some View {
        NavigationStack {
            contentLayer
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    backButton
                }
            }
            .tint(colorScheme == .dark ? .white : .black)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(Color.clear, for: .navigationBar)
        }
        .presentationBackground(.clear)
        .containerBackground(.clear, for: .navigation)
        .background(ClearPresentationBackground())
        .onAppear { isGlassActive = true }
        .onDisappear {
            isGlassActive = false
            instantModeInfoTask?.cancel()
        }
        .applyBreakthroughEffect()
    }

    private var instantModeInfoBubble: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? .white : .primary)

            Text("Instant replies skip long-term memory for faster responses.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? .white.opacity(0.92) : .primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
            } else {
                fallbackInstantInfoGlass(shape: shape)
            }
            #else
            fallbackInstantInfoGlass(shape: shape)
            #endif
        }
    }

    private func fallbackInstantInfoGlass(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.32), lineWidth: 1)
            )
    }
}

#if os(visionOS)
private extension View {
    @ViewBuilder
    func applyBreakthroughEffect() -> some View {
        if #available(visionOS 26.0, *) {
            self.presentationBreakthroughEffect(.subtle)
        } else {
            self
        }
    }
}
#else
private extension View {
    @ViewBuilder
    func applyBreakthroughEffect() -> some View {
        self
    }
}
#endif

#Preview {
    SettingsView()
}

// MARK: - Full page glass background

private struct GlassPageBackground: View {
    // Тюнинг: меняй эти значения
    private let blurStrength: Double = 0.9       // сила блюра под стеклом (0...1)
    private let tintOpacityDark: Double = 0.11    // затемнение в тёмной теме
    private let tintOpacityLight: Double = 0.11   // засветление в светлой теме

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // 1. блюр под стеклом
            Rectangle()
                .fill(.thinMaterial)
                .opacity(blurStrength)

            // 2. тёмная тема: чуть темнее, светлая: чуть светлее
            Rectangle()
                .fill(isDark ? Color.black : Color.white)
                .opacity(isDark ? tintOpacityDark : tintOpacityLight)

            // 3. само стекло
            glassLayer
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var glassLayer: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.clear, in: .rect)
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
    }
}

// MARK: - Background distortion

private struct GlassDistortionLayer: View {
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
                            .distortionEffect(
                                ShaderLibrary.glassDistortion(
                                    .float2(w, h),
                                    .float(t)
                                ),
                                maxSampleOffset: CGSize(width: maxOffset, height: maxOffset)
                            )
                            .blur(radius: blurRadius * 0.6)
                            .opacity(baseOpacity)
                    }
                } else {
                    Rectangle()
                        .blur(radius: blurRadius * 0.6)
                        .opacity(baseOpacity)
                }
            }
        } else {
            Rectangle()
                .opacity(baseOpacity)
        }
    }
}

private struct SettingsEdgeBlurOverlay: View {
    enum Position {
        case top
        case bottom
    }

    let position: Position
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SettingsBlurEffectView(style: colorScheme == .dark ? .dark : .light)
                .opacity(colorScheme == .dark ? 0.55 : 0.65)
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(colorScheme == .dark ? 0.08 : 0.03)
        }
        .mask(
            LinearGradient(
                stops: position == .top
                ? [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.12),
                    .init(color: .white, location: 0.25),
                    .init(color: .clear, location: 0.55),
                    .init(color: .clear, location: 1.0)
                ]
                : [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .white, location: 0.75),
                    .init(color: .white, location: 0.88),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct SettingsBlurEffectView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - Clear page background (sheet / fullScreenCover / hosting container)

/// Снимает непрозрачный системный фон у контейнера, в котором показана страница,
/// чтобы под стеклом был виден экран позади (чат), а не сплошная заливка.
private struct ClearPresentationBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        DispatchQueue.main.async { clear(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { clear(from: uiView) }
    }

    private func clear(from view: UIView) {
        var current: UIView? = view.superview
        var depth = 0
        while let v = current, depth < 6 {
            v.backgroundColor = .clear
            current = v.superview
            depth += 1
        }
    }
}
