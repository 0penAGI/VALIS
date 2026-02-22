import SwiftUI

struct MemoryListView: View {
    @ObservedObject private var memoryService = MemoryService.shared
    @State private var isPresentingEditor = false
    @State private var editingMemory: Memory?
    @State private var draftContent: String = ""
    @State private var selection = Set<UUID>()
    @State private var isShowingClearConfirm = false
    @Environment(\.editMode) private var editMode
    
    var body: some View {
        List(selection: $selection) {
            ForEach(memoryService.memories) { mem in
                HStack(alignment: .top, spacing: 10) {
                    if mem.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mem.content.isEmpty ? " " : mem.content)
                            .font(.body)
                        HStack(spacing: 8) {
                            Text(mem.timestamp, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(mem.emotion)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
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
                    Button {
                        memoryService.togglePinned(id: mem.id)
                    } label: {
                        Label(mem.isPinned ? "Unpin" : "Pin", systemImage: mem.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(mem.isPinned ? .gray : .orange)

                    Button(role: .destructive) {
                        memoryService.deleteMemory(id: mem.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        memoryService.togglePinned(id: mem.id)
                    } label: {
                        Label(mem.isPinned ? "Unpin" : "Pin", systemImage: mem.isPinned ? "pin.slash" : "pin")
                    }
                }
            }
            .onDelete(perform: memoryService.deleteMemories)
        }
        .navigationTitle("Memories")
        .tint(.black)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    isShowingClearConfirm = true
                } label: {
                    Text("Clear")
                }

                EditButton()

                Button {
                    editingMemory = nil
                    draftContent = ""
                    isPresentingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
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
                    }
                }
            }
        }
        .confirmationDialog("Clear all memories?", isPresented: $isShowingClearConfirm, titleVisibility: .visible) {
            Button("Clear All (keep identity & pinned)", role: .destructive) {
                memoryService.clearAllMemories(keepIdentity: true, keepPinned: true)
            }
            Button("Clear All (everything)", role: .destructive) {
                memoryService.clearAllMemories(keepIdentity: false, keepPinned: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove memories from the device.")
        }
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                VStack {
                    TextEditor(text: $draftContent)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                }
                .navigationTitle(editingMemory == nil ? "Add Memory" : "Edit Memory")
                .tint(.black)
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
}

#Preview {
    NavigationStack {
        MemoryListView()
    }
}
