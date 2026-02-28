//
//  ZephyrAIApp.swift
//  ZephyrAI
//
//  Created by ELLIIA on 27/1/2569 BE.
//

import SwiftUI
import AppIntents

@main
struct ZephyrAIApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        
    }
    
    @available(iOS 17.0, *)
    var appShortcuts: some AppShortcutsProvider {
        VALISAppShortcuts()
    }
}

@available(iOS 17.0, *)
struct AskVALISIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask VALIS"
    static var description = IntentDescription("Send a request to VALIS via Siri and open the app.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Message")
    var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "I need a message for VALIS.")
        }

        let defaults = UserDefaults.standard
        defaults.set(trimmed, forKey: "siri.pendingPrompt")
        defaults.set(Date().timeIntervalSince1970, forKey: "siri.pendingPromptTimestamp")
        NotificationCenter.default.post(name: .valisSiriPromptQueued, object: nil)

        return .result(dialog: "Sending this to VALIS.")
    }
}

@available(iOS 17.0, *)
struct VALISAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] = [
        AppShortcut(
            intent: AskVALISIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Спроси \(.applicationName)"
            ],
            shortTitle: "Ask VALIS",
            systemImageName: "brain.head.profile"
        )
    ]
}
