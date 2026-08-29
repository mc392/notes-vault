import SwiftUI

@main
struct NotesVaultApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    /// Locking on background is not optional for an app holding clinical records, but
    /// locking *instantly* means re-authenticating after every glance at a calendar. Five
    /// minutes is the compromise: long enough to check something in another app and come
    /// back, short enough that a phone left on a table is not left open.
    private static let relockAfter: TimeInterval = 5 * 60
    @State private var backgroundedAt: Date?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        if let since = backgroundedAt, Date().timeIntervalSince(since) > Self.relockAfter {
                            model.lock()
                        }
                        backgroundedAt = nil
                    case .background, .inactive:
                        if backgroundedAt == nil { backgroundedAt = Date() }
                    @unknown default:
                        break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Vault") {
                Button("Lock Vault") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh from Folder") { Task { await model.refreshIndex(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
    }
}
