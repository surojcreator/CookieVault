import SwiftUI

@main
struct CookieVaultApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1150, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Cookie File…") {
                    store.chooseFiles(tab: .cookies)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Import Cookie Folder…") {
                    store.chooseFolder(tab: .cookies)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()

                Button("Import API Keys File…") {
                    store.chooseFiles(tab: .apiKeys)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Import API Keys Folder…") {
                    store.chooseFolder(tab: .apiKeys)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])
            }
        }
    }
}
