import SwiftUI

struct SettingsView: View {
    // Glass tuning
    private let glassOpacityDark: Double = 0.32
    private let glassOpacityLight: Double = 0.44
    private let glassOverlayOpacityDark: Double = 0.5
    private let glassOverlayOpacityLight: Double = 0.4
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var identityService = IdentityService.shared
    
    @State private var masterPrompt: String = ""
    @State private var isEditingPrompt = false
    @State private var isGlassActive = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(LLMModelStorage.key) private var selectedModelRaw: String = LLMModelStorage.defaultValue.rawValue

    private var glassBackground: some View {
        let baseOpacity = colorScheme == .dark ? glassOpacityDark : glassOpacityLight
        let overlayOpacity = colorScheme == .dark ? glassOverlayOpacityDark : glassOverlayOpacityLight
        return ZStack {
            GlassDistortionLayer(
                baseOpacity: baseOpacity,
                blurRadius: glassBlurRadius,
                maxOffset: glassMaxOffset,
                isActive: isGlassActive
            )
            .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(overlayOpacity)
                .ignoresSafeArea()
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                glassBackground

                if colorScheme == .dark {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                }

                List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Personality")
                                .font(.headline)
                                .foregroundColor(colorScheme == .dark ? .white : .primary)
                            Spacer()
                            Text(isEditingPrompt ? "" : "")
                                .font(.caption)
                                .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                        }
                        TextEditor(text: $masterPrompt)
                            .frame(minHeight: 140)
                            .padding(8)
                            .background(Color(UIColor.secondarySystemBackground).opacity(colorScheme == .dark ? 0.7 : 1.0))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1)
                            )
                            .onChange(of: masterPrompt) { _, _ in
                                isEditingPrompt = true
                            }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)

                Section("Model") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Model Size", selection: $selectedModelRaw) {
                            ForEach(LLMModelChoice.allCases) { model in
                                Text("\(model.displayName) \(model.detailLabel)")
                                    .tag(model.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedModelRaw) { _, newValue in
                            guard let choice = LLMModelChoice(rawValue: newValue) else { return }
                            LLMModelStorage.save(choice)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)
                
                Section("Memory") {
                    NavigationLink {
                        MemoryListView()
                    } label: {
                        Text("Open Memories")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .background(.ultraThinMaterial.opacity(0.78))

                SettingsEdgeBlurOverlay(position: .top)
                    .frame(height: 99)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: -20)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)

                SettingsEdgeBlurOverlay(position: .bottom)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 62)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        identityService.updateUserPrompt(masterPrompt)
                        isEditingPrompt = false
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                }
            }
            .onAppear {
                masterPrompt = identityService.currentUserPrompt
                isEditingPrompt = false
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
                .opacity(colorScheme == .dark ? 0.9 : 0.98)
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(colorScheme == .dark ? 0.14 : 0.05)
        }
        .mask(
            LinearGradient(
                stops: position == .top
                ? [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.22),
                    .init(color: .clear, location: 0.58),
                    .init(color: .clear, location: 1.0)
                ]
                : [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .white, location: 0.58),
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
