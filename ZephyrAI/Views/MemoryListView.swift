import SwiftUI

struct MemoryListView: View {
    @ObservedObject private var memoryService = MemoryService.shared
    @State private var isPresentingEditor = false
    @State private var editingMemory: Memory?
    @State private var draftContent: String = ""
    @State private var selection = Set<UUID>()
    @State private var isShowingClearConfirm = false
    @Environment(\.editMode) private var editMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isGlassActive = false

    // Glass tuning
    private let glassOpacityDark: Double = 0.32
    private let glassOpacityLight: Double = 0.24
    private let glassOverlayOpacityDark: Double = 0.08
    private let glassOverlayOpacityLight: Double = 0.04
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18

    var body: some View {
        content
            .background(Color.clear)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            glassBackground
            memoryListView
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .tint(colorScheme == .dark ? .white : .black)
        .accentColor(colorScheme == .dark ? .white : .black)
        .toolbar {
            toolbarContent
        }
        .confirmationDialog("Clear all memories?", isPresented: $isShowingClearConfirm, titleVisibility: .visible) {
            clearDialogButtons
        } message: {
            Text("This will remove memories from the device.")
        }
        .sheet(isPresented: $isPresentingEditor) {
            editorSheet
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(colorScheme == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear), for: .navigationBar)
        .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        .onAppear { isGlassActive = true }
        .onDisappear { isGlassActive = false }
    }

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

    private var memoryListView: some View {
        List(selection: $selection) {
            headerSection
            memoryRows
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listStyle(.plain)
        .listRowBackground(Color.clear)
        .background(Color.clear)
        .background(.ultraThinMaterial.opacity(0.35))
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory Vault")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)

                Text("Quiet archive of what VALIS remembers.")
                    .font(.caption)
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
            }
            .padding(.vertical, 4)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var memoryRows: some View {
        ForEach(memoryService.memories) { mem in
            memoryRow(mem)
        }
        .onDelete(perform: memoryService.deleteMemories)
    }

    @ViewBuilder
    private func memoryRow(_ mem: Memory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if mem.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(mem.content.isEmpty ? " " : mem.content)
                    .font(.body)
                    .foregroundColor(colorScheme == .dark ? .white : .primary)

                HStack(spacing: 8) {
                    Text(mem.timestamp, style: .date)
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)

                    Text(mem.emotion)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorScheme == .dark ? Color.white.opacity(0.8) : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if editMode?.wrappedValue.isEditing == true { return }
            editingMemory = mem
            draftContent = mem.content
            isPresentingEditor = true
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            pinButton(mem)
            deleteButton(mem)
        }
        .contextMenu {
            pinButton(mem)
        }
    }

    private func pinButton(_ mem: Memory) -> some View {
        Button {
            memoryService.togglePinned(id: mem.id)
        } label: {
            Label(mem.isPinned ? "Unpin" : "Pin",
                  systemImage: mem.isPinned ? "pin.slash" : "pin")
        }
        .tint(.black)
    }

    private func deleteButton(_ mem: Memory) -> some View {
        Button(role: .destructive) {
            memoryService.deleteMemory(id: mem.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(.red)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                }
                .foregroundColor(colorScheme == .dark ? .white : .black)
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isShowingClearConfirm = true
            } label: {
                Text("Clear")
            }
            .foregroundColor(colorScheme == .dark ? .white : .black)

            Button {
                if editMode?.wrappedValue.isEditing == true {
                    editMode?.wrappedValue = .inactive
                } else {
                    editMode?.wrappedValue = .active
                }
            } label: {
                Text(editMode?.wrappedValue.isEditing == true ? "Done" : "Edit")
            }
            .foregroundColor(colorScheme == .dark ? .white : .black)

            Button {
                editingMemory = nil
                draftContent = ""
                isPresentingEditor = true
            } label: {
                Image(systemName: "plus")
            }
            .foregroundColor(colorScheme == .dark ? .white : .black)
        }

        ToolbarItem(placement: .bottomBar) {
            if !selection.isEmpty {
                Button {
                    for id in selection {
                        memoryService.togglePinned(id: id)
                    }
                    selection.removeAll()
                } label: {
                    Text("Pin Selected")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var clearDialogButtons: some View {
        Button("Clear All (keep identity & pinned)", role: .destructive) {
            memoryService.clearAllMemories(keepIdentity: true, keepPinned: true)
        }

        Button("Clear All (everything)", role: .destructive) {
            memoryService.clearAllMemories(keepIdentity: false, keepPinned: false)
        }

        Button("Cancel", role: .cancel) {}
    }

    private var editorSheet: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $draftContent)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }
            .navigationTitle(editingMemory == nil ? "Add Memory" : "Edit Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresentingEditor = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let text = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)

                        if text.isEmpty {
                            isPresentingEditor = false
                            return
                        }

                        if let mem = editingMemory {
                            memoryService.updateMemory(id: mem.id, content: text)
                        } else {
                            memoryService.addMemory(text)
                        }

                        isPresentingEditor = false
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemoryListView()
    }
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
