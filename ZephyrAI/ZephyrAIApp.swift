//
//  ZephyrAIApp.swift
//  ZephyrAI
//
//  Created by ELLIIA on 27/1/2569 BE.
//

import SwiftUI

@main
struct ZephyrAIApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
