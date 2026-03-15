import SwiftUI
import ComposableArchitecture

@main
struct AskariAIApp: App {
    static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
            ._printChanges()
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: AskariAIApp.store)
                .task {
                    await AskariAIApp.store.send(.appDelegate(.didFinishLaunching)).finish()
                }
        }
    }
}
