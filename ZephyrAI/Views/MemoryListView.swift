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

            MemoryEdgeBlurOverlay(position: .top)
                .frame(height: 99)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -20)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            MemoryEdgeBlurOverlay(position: .bottom)
                .frame(height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: 62)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
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
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(Color.clear, for: .navigationBar)
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
        ForEach(memoryService.visibleMemories()) { mem in
            memoryRow(mem)
        }
        .onDelete { offsets in
            let visible = memoryService.visibleMemories()
            let ids = offsets.compactMap { visible.indices.contains($0) ? visible[$0].id : nil }
            ids.forEach(memoryService.deleteMemory)
        }
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

struct ChatListView: View {
    @ObservedObject private var chatStore = ChatSessionStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var isGlassActive = false
    @State private var isPresentingRenameSheet = false
    @State private var editingChat: ChatSession?
    @State private var draftTitle: String = ""

    private let glassOpacityDark: Double = 0.32
    private let glassOpacityLight: Double = 0.24
    private let glassOverlayOpacityDark: Double = 0.08
    private let glassOverlayOpacityLight: Double = 0.04
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18

    var body: some View {
        ZStack {
            glassBackground
            chatListView

            MemoryEdgeBlurOverlay(position: .top)
                .frame(height: 99)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -20)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            MemoryEdgeBlurOverlay(position: .bottom)
                .frame(height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: 62)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .tint(colorScheme == .dark ? .white : .black)
        .accentColor(colorScheme == .dark ? .white : .black)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    ChatViewModel.shared.createNewChat()
                    dismiss()
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(colorScheme == .dark ? .white : .black)
            }
        }
        .sheet(isPresented: $isPresentingRenameSheet) {
            renameSheet
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(Color.clear, for: .navigationBar)
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

    private var chatListView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chats")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)

                    Text("Separate contexts with one shared memory.")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(chatStore.chats) { chat in
                chatRow(chat)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listStyle(.plain)
        .listRowBackground(Color.clear)
        .background(.ultraThinMaterial.opacity(0.35))
    }

    @ViewBuilder
    private func chatRow(_ chat: ChatSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if chat.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(chat.title)
                        .font(.body)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                        .lineLimit(1)

                    if chat.id == chatStore.currentChatID {
                        Text("Current")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(chat.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)

                    Text(chat.messages.isEmpty ? "Empty chat" : "\(chat.messages.count) messages")
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
            ChatViewModel.shared.switchToChat(chat.id)
            dismiss()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                ChatViewModel.shared.deleteChat(chat.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)

            Button {
                beginRename(chat)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.gray)

            Button {
                ChatViewModel.shared.togglePinnedChat(chat.id)
            } label: {
                Label(chat.isPinned ? "Unpin" : "Pin",
                      systemImage: chat.isPinned ? "pin.slash" : "pin")
            }
            .tint(.black)
        }
        .contextMenu {
            Button {
                ChatViewModel.shared.switchToChat(chat.id)
                dismiss()
            } label: {
                Label("Open", systemImage: "bubble.left.and.bubble.right")
            }

            Button {
                beginRename(chat)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                ChatViewModel.shared.togglePinnedChat(chat.id)
            } label: {
                Label(chat.isPinned ? "Unpin" : "Pin",
                      systemImage: chat.isPinned ? "pin.slash" : "pin")
            }
        }
    }

    private func beginRename(_ chat: ChatSession) {
        editingChat = chat
        draftTitle = chat.title
        isPresentingRenameSheet = true
    }

    private var renameSheet: some View {
        NavigationStack {
            VStack {
                TextField("Chat title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                Spacer()
            }
            .navigationTitle("Rename Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresentingRenameSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let chat = editingChat {
                            ChatViewModel.shared.renameChat(chat.id, title: draftTitle)
                        }
                        isPresentingRenameSheet = false
                    }
                }
            }
        }
    }
}

struct PersonaListView: View {
    @ObservedObject private var identityService = IdentityService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserIdentityService.nameKey) private var userName: String = ""
    @AppStorage(UserIdentityService.genderKey) private var userGender: String = ""
    @State private var masterPrompt: String = ""
    @State private var isGlassActive = false

    private let glassOpacityDark: Double = 0.32
    private let glassOpacityLight: Double = 0.24
    private let glassOverlayOpacityDark: Double = 0.08
    private let glassOverlayOpacityLight: Double = 0.04
    private let glassBlurRadius: CGFloat = 4
    private let glassMaxOffset: CGFloat = 18

    var body: some View {
        ZStack {
            glassBackground
            personaListView

            MemoryEdgeBlurOverlay(position: .top)
                .frame(height: 99)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -20)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            MemoryEdgeBlurOverlay(position: .bottom)
                .frame(height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: 62)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .tint(colorScheme == .dark ? .white : .black)
        .accentColor(colorScheme == .dark ? .white : .black)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    identityService.updateUserPrompt(masterPrompt)
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(Color.clear, for: .navigationBar)
        .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        .onAppear {
            masterPrompt = identityService.currentUserPrompt
            isGlassActive = true
        }
        .onDisappear {
            identityService.updateUserPrompt(masterPrompt)
            isGlassActive = false
        }
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

    private var personaListView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persona")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(colorScheme == .dark ? .white : .primary)

                    Text("Identity fields and the system personality prompt.")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("User Personality") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("User Name", text: $userName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color(UIColor.secondarySystemBackground).opacity(colorScheme == .dark ? 0.7 : 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1)
                        )

                    TextField("Gender", text: $userGender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color(UIColor.secondarySystemBackground).opacity(colorScheme == .dark ? 0.7 : 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1)
                        )
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section("AI Personality") {
                TextEditor(text: $masterPrompt)
                    .frame(minHeight: 220)
                    .padding(8)
                    .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listStyle(.plain)
        .listRowBackground(Color.clear)
        .background(.ultraThinMaterial.opacity(0.35))
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

private struct MemoryEdgeBlurOverlay: View {
    enum Position {
        case top
        case bottom
    }

    let position: Position
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MemoryBlurEffectView(style: colorScheme == .dark ? .dark : .light)
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

private struct MemoryBlurEffectView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
