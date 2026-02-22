import SwiftUI
import CoreData

struct ContentView: View {
    // We keep the context for future Core Data usage if needed
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        // Switch to the Chat Interface
        NavigationView {
            ChatView()
        }
        .navigationViewStyle(.stack) // Use stack style for better behavior on iPad/iPhone
    }
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
