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
    @AppStorage(LLMModelStorage.key) private var selectedModelRaw: String = LLMModelStorage.defaultValue.rawValue
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
        glassBaseLayer
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
        .onAppear { isGlassActive = true }
        .onDisappear { isGlassActive = false }
        .applyBreakthroughEffect()
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
 
