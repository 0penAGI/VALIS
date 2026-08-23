import SwiftUI
import CoreData

struct ContentView: View {
    // We keep the context for future Core Data usage if needed
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        NavigationStack {
            ChatView()
        }
        .statusBarHidden(true)
    }
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
