import SwiftUI

struct SettingsView: View {
    // Glass tuning
    private let glassOpacityDark: Double = 0.92
    private let glassOpacityLight: Double = 0.94
    private let glassOverlayOpacityDark: Double = 0.8
    private let glassOverlayOpacityLight: Double = 0.8
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var identityService = IdentityService.shared
    
    @State private var masterPrompt: String = ""
    @State private var isEditingPrompt = false
    @State private var isGlassActive = false
    @Environment(\.colorScheme) private var colorScheme

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
                            .onChange(of: masterPrompt) {
                                isEditingPrompt = true
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
            .background(.ultraThinMaterial.opacity(0.3))
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
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(colorScheme == .dark ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color.clear), for: .navigationBar)
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
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
                        let w = Float(proxy.size.width)
                        let h = Float(proxy.size.height)
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
