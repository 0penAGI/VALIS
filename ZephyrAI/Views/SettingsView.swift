import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var identityService = IdentityService.shared
    
    @State private var masterPrompt: String = ""
    
    var body: some View {
        NavigationStack {
            List {
                Section("Personality") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextEditor(text: $masterPrompt)
                            .frame(minHeight: 140)
                    }
                }
                
                Section("Memories") {
                    NavigationLink {
                        MemoryListView()
                    } label: {
                        Text("Memories")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        identityService.updateUserPrompt(masterPrompt)
                        dismiss()
                    }
                }
            }
            .onAppear {
                masterPrompt = identityService.currentUserPrompt
            }
        }
    }
}

#Preview {
    SettingsView()
}
