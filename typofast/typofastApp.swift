//
//  typofastApp.swift
//  typofast
//
//  Created by Baptiste Lefort on 07/01/2026.
//

import SwiftUI

@main
struct typofastApp: App {
    @StateObject private var appState: AppState
    @StateObject private var globalController: GlobalSuggestionController

    init() {
        let state = AppState()
        let controller = GlobalSuggestionController(appState: state)
        _appState = StateObject(wrappedValue: state)
        _globalController = StateObject(wrappedValue: controller)

        Task { @MainActor in
            controller.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Typofast", systemImage: "text.cursor") {
            ContentView(appState: appState, globalController: globalController)
        }
        .menuBarExtraStyle(.window)
    }
}
