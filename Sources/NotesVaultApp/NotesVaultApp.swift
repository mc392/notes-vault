import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct NotesVaultApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    await model.start()
                    // A vault that was already chosen goes straight to the lock screen, and
                    // the lock screen's job on a cold start is to ask — not to wait to be
                    // asked. This is the "every launch is a new check" half of the policy.
                    await model.unlockIfBiometricsOffered()
                }
                // The lock policy lives in AppModel; this is only the wiring from the
                // scene's phases to it. `.inactive` and `.background` are deliberately not
                // the same event: an app is inactive with a Face ID prompt in front of it,
                // and treating that as leaving would relock the app in the middle of the
                // check that was meant to keep it open.
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { await model.becameActive() }
                    case .inactive:
                        model.enterBackground(reallyAway: false)
                    case .background:
                        model.enterBackground(reallyAway: true)
                    @unknown default:
                        break
                    }
                }
                #if os(iOS)
                // The in-view shield covers the app itself; a sheet — the note editor, an
                // import — is presented above it and would still be in the snapshot iOS
                // takes for the app switcher. Its own window, above everything, is the only
                // thing that covers those too.
                .onChange(of: model.isShielded) { _, shielded in
                    if shielded { PrivacyShieldWindow.shared.show() } else { PrivacyShieldWindow.shared.hide() }
                }
                #endif
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

#if os(iOS)
/// The launch screen, in a window of its own above every sheet and alert.
///
/// Shown while the app is off screen, so what iOS photographs for the app switcher — and
/// what anyone glancing at a phone being handed back sees — is the same screen a stranger
/// would get by opening the app cold.
@MainActor
final class PrivacyShieldWindow {
    static let shared = PrivacyShieldWindow()

    private var window: UIWindow?

    func show() {
        guard window == nil, let scene = activeScene else { return }
        let window = UIWindow(windowScene: scene)
        // Above `.alert`, which is where system alerts and action sheets sit.
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: SplashView())
        // Not `makeKeyAndVisible`: this window shows something and accepts nothing, and
        // taking key status from the app would move the keyboard's focus out of a
        // half-typed note.
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    /// The scene the app is actually on screen in. Falls back to any window scene so that a
    /// shield is still raised while the app is on its way to the background, which is
    /// precisely when it is needed.
    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
#endif
